# Encrypted Walkie Talkie — iOS App Plan

## Overview

A push-to-talk (PTT) iOS app for encrypted voice communication over local WiFi. Two iPhones on the same network can discover each other and talk securely. No servers, no accounts, no cloud.

**Phase 1 scope: WiFi only.** LoRa, internet relay, and other transports are out of scope for now.

---

## Tech Stack

| Layer | Choice | Reason |
|---|---|---|
| Language | Swift 6 | Modern concurrency, strict sendability |
| UI | SwiftUI | Clean PTT button UI |
| Audio capture/playback | AVAudioEngine | Fine-grained PCM access |
| Audio codec | Opus via libopus | Industry standard for voice, great at low bitrate |
| Transport | Network.framework (UDP) | Explicit control, low latency |
| Discovery | Bonjour (NetServiceBrowser) | Zero-config local network discovery |
| Encryption | libsodium (Swift package) | crypto_secretbox, simple and proven |
| Key exchange | QR code pairing | Simple UX, no server needed |

---

## App Architecture

```
WalkieTalkieApp
├── Discovery/
│   ├── BonjourService.swift         — advertise & browse for peers
│   └── PeerInfo.swift               — peer model (name, IP, port)
├── Transport/
│   ├── UDPTransport.swift           — send/receive UDP packets
│   └── PacketProtocol.swift         — packet framing (header + payload)
├── Crypto/
│   ├── CryptoService.swift          — encrypt/decrypt via libsodium
│   └── KeyStore.swift               — store shared key in Keychain
├── Audio/
│   ├── AudioCapture.swift           — AVAudioEngine mic capture
│   ├── AudioPlayback.swift          — AVAudioEngine speaker playback
│   ├── OpusEncoder.swift            — PCM → Opus
│   └── OpusDecoder.swift            — Opus → PCM
├── Pairing/
│   ├── PairingView.swift            — QR code display + scanner
│   └── PairingService.swift         — key generation + QR encode/decode
└── UI/
    ├── ContentView.swift            — main screen
    ├── PTTButton.swift              — hold-to-talk button
    └── PeerListView.swift           — discovered peers list
```

---

## Data Flow

### Sending (button held down)

```
Mic → AVAudioEngine (PCM, 48kHz mono)
    → OpusEncoder (20ms frames → ~160 bytes)
    → CryptoService.encrypt (libsodium secretbox)
    → UDPTransport.send (to peer IP:port)
```

### Receiving

```
UDPTransport.receive
    → CryptoService.decrypt
    → OpusDecoder (Opus → PCM)
    → AVAudioEngine playback (speaker)
```

---

## Packet Format

Simple binary framing, no JSON overhead:

```
[ version: 1 byte ]
[ packet_type: 1 byte ]   — 0x01 = audio, 0x02 = ping, 0x03 = pong
[ sequence: 4 bytes ]     — monotonic counter for jitter detection
[ timestamp: 8 bytes ]    — sender clock (ms)
[ nonce: 24 bytes ]       — libsodium nonce (per packet, random)
[ payload_len: 2 bytes ]
[ payload: N bytes ]      — encrypted Opus frame
```

Total overhead per packet: ~40 bytes. Opus frame: ~160 bytes. Total: ~200 bytes per 20ms.

---

## Pairing Flow

1. Device A generates a random 32-byte symmetric key
2. Device A displays key as QR code (base64 encoded)
3. Device B scans QR code with camera
4. Both devices store key in Keychain under a paired device ID
5. From now on, all audio packets are encrypted with this shared key

**No server involved.** Out-of-band trust established visually.

---

## Discovery Flow

1. App launches → registers Bonjour service type `_walkie._udp.` on random port
2. `NetServiceBrowser` scans for same service type on local network
3. Discovered peers appear in peer list with device name
4. User taps peer → app resolves IP + port via `NetService.resolve`
5. PTT button becomes active

---

## Audio Settings

```swift
// AVAudioSession config
category: .playAndRecord
mode: .voiceChat
options: [.defaultToSpeaker, .allowBluetooth]

// Capture format
sampleRate: 48000
channels: 1 (mono)
frameSize: 960 samples = 20ms at 48kHz

// Opus settings
bitrate: 16000 bps  — good quality for voice, low bandwidth
application: OPUS_APPLICATION_VOIP
```

---

## iOS Permissions Required

Add to `Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Used for push-to-talk voice communication</string>

<key>NSLocalNetworkUsageDescription</key>
<string>Used to discover and communicate with nearby devices</string>

<key>NSBonjourServices</key>
<array>
  <string>_walkie._udp.</string>
</array>

<key>NSCameraUsageDescription</key>
<string>Used to scan pairing QR codes</string>
```

No background modes needed for Phase 1. PTT only works while app is in foreground.

---

## Dependencies (Swift Packages)

```
// Package.swift or via Xcode SPM
dependencies: [
    .package(url: "https://github.com/jedisct1/swift-sodium", from: "0.9.1"),
    // Opus: use a Swift wrapper around libopus
    // Option A: https://github.com/alta/swift-opus (if maintained)
    // Option B: wrap libopus C library directly via bridging header
]
```

### Opus integration note
Opus doesn't have an official Swift package. Options in order of preference:
1. Use `AVAudioConverter` with `kAudioFormatOpus` on iOS 15+ — Apple's built-in Opus support, no external dependency
2. If more control needed, add libopus as a xcframework

**Recommended: Use `AVAudioConverter` with `kAudioFormatOpus` first.** Avoids the C library complexity entirely.

---

## Milestones

### M1 — Audio pipeline (no network)
- [ ] AVAudioEngine capture → Opus encode → Opus decode → playback
- [ ] Confirm latency and quality is acceptable

### M2 — Local UDP transport
- [ ] Network.framework UDP send/receive
- [ ] Two simulators or two devices on same WiFi exchanging raw packets

### M3 — Crypto layer
- [ ] libsodium integration via swift-sodium
- [ ] Encrypt/decrypt pipeline on the UDP path

### M4 — Pairing
- [ ] Key generation
- [ ] QR code display (SwiftUI)
- [ ] QR code scanner (AVCaptureSession or VisionKit)
- [ ] Keychain storage

### M5 — Discovery
- [ ] Bonjour advertisement + browsing
- [ ] Peer list UI
- [ ] Connect to peer by tap

### M6 — Full PTT flow
- [ ] PTT button (hold to talk)
- [ ] Audio + crypto + transport wired together end to end
- [ ] Two real devices talking

### M7 — Polish
- [ ] Audio feedback (click sound on PTT press/release)
- [ ] Connection status indicator
- [ ] Handle peer disconnect gracefully
- [ ] Basic settings (device name)

---

## Known Risks & Notes

- **Local Network permission prompt** — iOS 14+ requires user to grant local network access. First launch will show a system prompt. App should explain why before triggering it.
- **UDP packet loss** — no retry mechanism needed for voice (late packets are useless). Opus handles occasional loss gracefully.
- **Jitter buffer** — for M6+, a simple ring buffer (3-5 frame depth) on the playback side will smooth over network jitter.
- **One-to-one only** — Phase 1 is unicast (one peer at a time). Group PTT (multicast) is a future concern.
- **Simulator limitation** — audio capture doesn't work in iOS Simulator. Use real devices from M1 onwards.

---

## Future Phases (out of scope for now)

- **LoRa transport** — BLE bridge to Meshtastic-compatible hardware, Codec2 instead of Opus
- **Internet relay fallback** — self-hosted relay server (Node.js), still E2EE
- **Group channels** — multicast or relay-based group PTT
- **Persistent pairing list** — manage multiple paired devices
- **Apple Watch** — PTT from wrist
