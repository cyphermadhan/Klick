# Walkie

Encrypted push-to-talk over local WiFi for iOS. Two iPhones on the same network discover each other via Bonjour and talk with Opus + XSalsa20/Poly1305. No servers, no accounts.

See [plan.md](plan.md) for the design rationale.

## Build & run

```bash
brew install xcodegen      # one-time
xcodegen generate          # writes WalkieTalkie.xcodeproj
open WalkieTalkie.xcodeproj
```

Pick your device (real hardware — the simulator can't capture mic audio) and hit ▶.

Run tests from the CLI:

```bash
xcodebuild -project WalkieTalkie.xcodeproj \
  -scheme WalkieTalkie \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test
```

## Trying it out

1. Install on two iPhones on the same WiFi.
2. On both, tap **Start**. Accept the mic + local network prompts.
3. On device A: **Pair → Show code**. It displays a QR.
4. On device B: **Pair → Scan code**. Point the camera at A's screen.
5. Both devices should now see each other in the Peers list. Tap a peer to select it.
6. Hold the big mic button to transmit.

## Project layout

```
Sources/
├── App/          — WalkieTalkieApp entry + PTTSession coordinator
├── Audio/        — AVAudioEngine capture/playback, Opus codec via AVAudioConverter
├── Crypto/       — libsodium secretbox wrapper + Keychain key storage
├── Discovery/    — Bonjour browser + device-name persistence
├── Pairing/      — QR code display + camera scanner
├── Transport/    — UDP send/receive + binary packet framing
└── UI/           — SwiftUI views
Tests/WalkieTalkieTests/   — 23 unit + integration tests
```

## What's tested

| Area | Tests |
|---|---|
| Opus encode/decode roundtrip | 3 |
| Packet wire-format roundtrip + error cases | 6 |
| CryptoService seal/open, tampering, wrong key | 6 |
| PairingService QR payload + base64url | 6 |
| UDP localhost delivery | 1 |
| Scaffold | 1 |

Audio IO and Bonjour discovery need real hardware to verify and are exercised through the app rather than unit tests.

## Status

All seven milestones from `plan.md` are complete:

- [x] M1 — Audio pipeline
- [x] M2 — UDP transport
- [x] M3 — Crypto layer
- [x] M4 — Pairing
- [x] M5 — Discovery
- [x] M6 — Full PTT flow
- [x] M7 — Polish (PTT click sounds, settings, unpair)
