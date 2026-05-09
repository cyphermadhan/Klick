# Klick v2 — Upgrade Roadmap

Post-1.0 plan. Klick 1.0 ships PTT over local WiFi (Bonjour + UDP + Opus + libsodium). This document scopes three independent upgrades that layer on top of it without breaking the existing TestFlight build.

Phases ship in order, but each is self-contained and can be released on its own.

| Phase | Feature | Solves | Hardware required | Ships |
|---|---|---|---|---|
| 1 | **Multipeer transport** | "I'm at a concert with no WiFi" | None (iOS-only) | Standalone |
| 2 | **Morse mode** | Fun, minimal, works at the edge of any link | None | Standalone — rides any transport |
| 3 | **LoRa text bridge** | "I'm on a hill with no cell" | External Meshtastic-compatible radio | Standalone |

---

## Current status — 2026-05-09

### Phase 1 — shipped to `main` (`da1f0ae`), pending on-device verification

All 11 implementation tasks ticked. Build green on iPhone 16 sim, 33 tests pass in phase-1-only state.

**Merged:** `AudioTransport` protocol + `UDPTransport` conformance (absorbed Bonjour), new `MPCTransport`, `PeerDirectory` merges peers from both transports, `RangeMode` user setting (defaults to `.both`), `WIFI`/`NEAR` pills in the peer list, KlickKlick rename (ITMS-90129 resolved), `NSBluetoothAlwaysUsageDescription` + `_klick-ptt-v1._tcp./._udp.` Bonjour types.

**Deviations from the original Phase 1 plan:**
- Default `RangeMode = .both`, not `.wifi`. Upgrading users get concert-range behavior without discovering a setting. Revisit after TestFlight field data.
- Same-name peer on two transports shows as two rows, not collapsed to a single `BOTH` tag. Collapse deferred to a polish pass.
- `BonjourBrowser` deleted rather than renamed — its ~50 lines of `NWBrowser` setup moved inside `UDPTransport`, one file per transport.

**Still open for Phase 1:**
- [ ] Two-device smoke test (MPC doesn't work in simulator — needs real iPhones, airplane mode + Bluetooth on). See the pre-merge testing checklist in the prior commit description.
- [ ] Version bump to `MARKETING_VERSION 0.2.0`, `CURRENT_PROJECT_VERSION 3`

### Phase 2 — shipped to `main` (`468e32c`, polish in `ac0300c`)

All 11 deliverables complete. 55 tests pass on iPhone 16 sim, build verified on iPhone SE (3rd gen) sim.

**Merged:**
- `MorseCode` — ITU alphabet (A–Z, 0–9, 18 punctuation marks), `encode → [MorseFrame]`, `decode → Character?`
- `MorseTree` — traversal state machine, published currentPath/buffer/isOffTree, shape matches keychain reference (square = dah, circle = dit)
- `MorseTone` — standalone `AVAudioEngine`, 600 Hz sine sidetone with 5 ms raised-cosine ramps, WPM clamped [5, 40]
- `FlashlightBeacon` — `AVCaptureDevice.torchMode` pulses, 15 Hz switch cap, simulator-safe no-op
- `MorseTreeView` — SwiftUI `Canvas` full alphabet: depth 1–4 letters (18 pt, 9 pt label), depth 5 digits (14 pt, 7 pt label), depth 6 punctuation (10 pt marker-only). Active-path terminal sizes per depth.
- `MorseView` — TX/RX frames, tree, KEY or TAP input. VoiceOver labels + `updatesFrequently` trait on the buffers. TAP mode threshold is WPM-derived (1.5 dit-units) and the key face shows `DIT`/`DAH` live while held.
- Packet type `0x04 morseText`, `AudioTransport.sendText` (UDP best-effort, MPC reliable)
- `PTTSession.sendMorse` + `.morseText` routing, bounded `morseHistory` scrollback, transient `incomingMorse` publisher
- `ContentView` — magenta `MORSE` pill between PAIR and SYS
- `MorseTests` (22) + morseText roundtrip test

**Still open for Phase 2:**
- [ ] Real-device VoiceOver walkthrough — the structural labels are in, but a live-with-screen-reader pass on a phone would catch any awkward phrasing
- [ ] Peer-row collapse for same-name peers on multiple transports (inherited from Phase 1 polish)

### How to pick this up next session

```bash
cd /Users/mraj/Documents/GitHub/Klick
xcodegen generate
xcodebuild -project KlickKlick.xcodeproj -scheme KlickKlick \
  -destination 'platform=iOS Simulator,id=6110AA28-5BAA-4938-A9B9-112261D009CC' \
  test
```

Next major piece is **Phase 3 — LoRa text bridge**. See §Phase 3 below. Estimated 5–8 days + hardware (Meshtastic-compatible radio) for end-to-end verification.

---

## Context: what Klick is today

```
Mic → AVAudioEngine → Opus → libsodium (XSalsa20+Poly1305) → UDP → peer
                                                             ↘ Bonjour discovery
```

- One-to-one PTT, 48 kHz mono Opus at 16 kbps, ~200 B per 20 ms packet
- Shared 32-byte key exchanged via QR, stored in Keychain
- Both `NWListener` and `NWBrowser` already set `includePeerToPeer = true` (UDPTransport.swift:44, BonjourService.swift:35), so AWDL is technically in play — but unreliable without a backing WiFi network

Everything below preserves that core pipeline.

---

## Phase 1 — Multipeer Connectivity transport

### Goal

A second transport path that works with **no infrastructure** (no router, no hotspot, no cell). Concert scenario: two phones within ~30 m of each other, both in airplane mode if they want to be, still talking.

### Why MultipeerConnectivity (MPC) over raw AWDL

Klick already has `includePeerToPeer = true` on its `NWListener`/`NWBrowser`, so in theory it uses AWDL when no WiFi is present. In practice, Bonjour-over-AWDL discovery is fragile — it depends on both devices independently deciding to bring up AWDL, and there's no good way to kickstart it from user code.

`MultipeerConnectivity` is Apple's supported API for exactly this. It stitches together:

- Bluetooth LE (for discovery and short-range fallback)
- Peer-to-peer WiFi (AWDL) when devices are close and not on infra
- Infrastructure WiFi when both peers are on the same LAN

…and exposes a single session abstraction. The framework does the failover internally. We keep our Opus + crypto layer and swap what sits underneath.

### Architecture

New module `Sources/Transport/MPCTransport.swift`. Implements the **same interface** as `UDPTransport` so `PTTSession` can hold either, or both.

```swift
protocol AudioTransport: AnyObject {
    func start(advertisingAs: String) throws
    func stop()
    func sendAudio(opusPayload: Data, nonce: Data, to: PeerHandle)
    var onReceive: ((Packet, PeerHandle) -> Void)? { get set }
}
```

`PeerHandle` becomes a transport-agnostic peer identity (name + transport tag + opaque endpoint). Peer lists from both transports merge in `PTTSession`.

MPC details:

- `MCNearbyServiceAdvertiser` + `MCNearbyServiceBrowser` with service type `klick-v1` (MPC service types are ≤15 chars, lowercase, no underscores — can't reuse `_walkie._udp.`)
- `MCSession` with `encryptionPreference = .none` — **we keep our own libsodium layer**, because MPC's encryption is opaque and we want nonce-level control for future sequence-based loss inference
- Send over `.unreliable` mode to match UDP semantics (voice)
- Reuse the existing `Packet` wire format verbatim — MPC just carries the same bytes

### UX changes

Minimal. Add a **range mode** selector in Settings:

```
RANGE MODE
  ○ WIFI only        — infra network (current 1.0 behavior)
  ● NEARBY only      — no infra, MPC over Bluetooth + AWDL
  ○ BOTH             — advertise on both, peer list shows transport per row
```

Peer list rows gain a tiny trailing tag: `WIFI`, `NEAR`, or `BOTH` when a peer is discovered on multiple paths. No other UI changes on the main screen.

### Compatibility

MPC peers running v2 can only talk to other v2 peers. Existing v1 peers will still see each other over WiFi/Bonjour. We don't need a bridge — users upgrade both phones or they don't, same as today.

### Risks

- **Local Network + Bluetooth permission prompts** — MPC triggers both on first use. Handle gracefully; explain before prompting.
- **Power draw** — continuous BLE advertising + AWDL is real. Default range mode stays `WIFI only` unless user opts in. Background use is not supported anyway (existing constraint, unchanged).
- **MPC throughput in crowded RF** — AWDL degrades in dense wifi environments (concert with 20k phones). Opus at 16 kbps is ~2 KB/s — well within MPC's envelope, but latency may spike. Acceptable for voice.
- **No third-party bridge** — Klick peers only. No surprise.

### Deliverables

- [x] `AudioTransport` protocol + refactor existing `UDPTransport` to conform
- [x] `MPCTransport` implementation
- [x] Merged peer list in `PeerDirectory` (replaces `BonjourBrowser`; old class deleted, browsing absorbed into `UDPTransport`)
- [x] Range mode setting persisted in `UserDefaults` (`RangeMode.swift`)
- [x] Transport tag on peer rows (`WIFI` / `NEAR` pill)
- [ ] ~~Integration test: two simulators, MPC-only, Opus frames roundtrip~~ — not feasible; MPC has no AWDL/Bluetooth in the simulator. Covered by device smoke test instead.
- [ ] Manual test: two phones in airplane mode + Bluetooth on (pending)

### Estimated scope

Medium. ~500–700 new LoC, ~200 lines changed in `PTTSession`. No codec or crypto changes. 1–2 days of focused work + device testing.

---

## Phase 2 — Morse mode

### Goal

A separate screen accessible from the header (a third pill next to `PAIR` / `SYS`), where a user can send and receive Morse code over the same encrypted transport. No bandwidth constraints — Morse fits trivially in anything — so it works identically over WiFi, MPC, or (Phase 3) LoRa.

### Why Morse

- Ultra-low bandwidth (~5–20 bps encoded, a few bytes per character on the wire)
- Robust at the edge of any link — each character independent
- Fits Klick's terminal/hardware aesthetic
- Charming. Nobody else ships this.

### Input model: the Morse tree as the keyboard

The photo reference the user sent (a Morse-tree keychain) is the interaction model:

```
                     •─ antenna ─•
                   ╱              ╲
                 (−) dash        (•) dot
                 ╱    ╲          ╱    ╲
              [ T ]  [ M ] ... ( E )  ( I ) ...
```

The on-screen tree IS the input surface. No QWERTY keyboard. As the user keys in dits and dahs, the current node on the tree lights up green — exactly like the keychain. On gap, the letter commits (flashes orange like the keychain's "A" state) and is appended to the outgoing message buffer.

Node-shape convention (matching the reference):
- Dash step (left branch) → **square** node
- Dot step (right branch) → **circle** node
- Root is a small antenna glyph

### Input styles

Two, toggleable inside the Morse screen:

**KEY mode (default)** — two big buttons at the bottom: `·` and `−`. Each press walks one step down the tree; the active node highlights. A configurable gap (default 600 ms of no input) commits the letter and resets to root. Double gap commits a word space.

**TAP mode** — single button in the center, acts as a real telegraph key:
- Hold < 150 ms → dit
- Hold ≥ 150 ms → dah
- Gap > 3× current unit → letter commit
- Gap > 7× current unit → word space

Tap mode is optional because it's harder for beginners. Key mode is the default.

Both modes stream characters into an editable text buffer above the tree, which is sent on tap of the `TX` button.

### Receiving

Incoming Morse messages play:
- **Audio beeps** through the existing speaker path (the `WalkieSoundSynth` already has an oscillator — extend it to emit Morse at a chosen WPM)
- **Visual trace** on the tree: the same node-highlighting animation that the sender sees
- **Flashlight pulses** (optional, togglable) via `AVCaptureDevice.torchMode` — for silent reception in a concert, or to signal across a room without audio
- **Decoded text** appears in a scrolling buffer above the tree

Receiving doesn't require the recipient to know Morse — the tree animates and the decoded text shows anyway. Good onboarding.

### Screen layout

```
┌─────────────────────────────────────────┐
│ ◂ BACK        MORSE        WPM 12  ⚙   │  header
├─────────────────────────────────────────┤
│                                         │
│ TX: HELLO OM_                           │  outgoing buffer (editable)
│ RX: 73 DE N7ZZ                          │  incoming buffer (scrollback)
│                                         │
├─────────────────────────────────────────┤
│                                         │
│            [ Morse tree ]               │  75% of height
│       active node = green glow          │
│       just-committed letter = orange    │
│                                         │
├─────────────────────────────────────────┤
│   [ · ]        [ − ]        [ TX ]      │  input row (KEY mode)
│                                         │
│   mode: ○ KEY  ● TAP    ▢ FLASH         │  small toggles
└─────────────────────────────────────────┘
```

Not on the primary screen — reached via a `MORSE` pill in the top header. Per user direction, voice-PTT remains the front door.

### Wire format

New packet type `0x04 morse_text`. Payload is a plain UTF-8 string (sender-committed text), still encrypted with libsodium secretbox. Payload rarely exceeds a few hundred bytes.

```
[ version:1 ][ type=0x04:1 ][ seq:4 ][ ts:8 ][ nonce:24 ][ len:2 ][ utf8 payload ]
```

Why send decoded text, not raw dit/dah timings? Three reasons:
1. **Transport-agnostic** — LoRa doesn't care about timings; beeps are reconstructed on receipt using the listener's WPM preference
2. **No lost-character drift** — one dropped packet doesn't desync the whole stream
3. **Simpler** — senders with different keying speeds still produce the same message

Optional future packet type `0x05 morse_events` for live per-dit streaming (feels more authentic, costs more). Out of scope for v2.

### Risks

- **Tree rendering on small screens** — 26 letters in a binary tree is deep (max 4 levels for letters, 6 for digits/punctuation). Need to test on iPhone SE. Likely scroll horizontally or collapse rare branches.
- **Accessibility** — VoiceOver needs to announce the committed letter, not the tree traversal. Plan for `.accessibilityValue` on the buffer and `.accessibilityHidden` on the animating tree.
- **Flashlight permission** — torch doesn't need a permission prompt but is rate-limited by iOS thermal. Cap flash rate at 15 pulses/sec.
- **WPM mismatch** — sender at 20 WPM, receiver set to 5 WPM playback: fine (playback uses receiver's WPM, not sender's). Only an issue if we ever ship raw-events mode.

### Deliverables

- [x] `Sources/Morse/MorseCode.swift` — encode/decode, ITU international set (letters + digits + common punctuation). Extended chars (Ä/Ö/Ü/CH) and Q-codes deferred — no wire-format impact.
- [x] `Sources/Morse/MorseTree.swift` — traversal state machine shared between input and visualization
- [x] `Sources/Morse/MorseTone.swift` — standalone `AVAudioEngine`, 600 Hz sidetone with 5 ms raised-cosine ramps, WPM clamped [5, 40]
- [x] `Sources/Morse/FlashlightBeacon.swift` — `AVCaptureDevice.torchMode` pulses, 15 Hz switch cap, simulator-safe
- [x] `Sources/UI/MorseView.swift` — TX/RX frames, tree, KEY / TAP input, WPM stepper, FLASH toggle, VoiceOver support; TAP threshold WPM-derived, key face flips DIT→DAH live
- [x] `Sources/UI/MorseTreeView.swift` — SwiftUI `Canvas`, full alphabet to depth 6 (letters labelled, digits small-label, punctuation marker-only), live active-path overlay
- [x] Packet type `0x04 morseText`, wire tests (`PacketProtocolTests.testMorseTextRoundtrip`)
- [x] `PTTSession` routing: `sendMorse` for TX, `.morseText` decrypt + `morseHistory` append + `incomingMorse` publisher for beep/flash replay
- [x] Unit tests: encode/decode roundtrip for all defined ITU characters; tree state-machine invariants (`MorseTests.swift`, 22 tests)

### Estimated scope

Medium. ~1200 new LoC, mostly in the `Morse/` + `UI/` folders. Self-contained — no touching crypto, transport, or audio capture. 2–3 days.

---

## Phase 3 — LoRa text bridge

### Goal

A fourth transport path that uses an **external LoRa radio** paired over Bluetooth, carrying text (and Morse, which is text) to peers hundreds of meters to kilometers away with no cell, WiFi, or line-of-sight to a tower.

**Out of scope for this phase: voice.** LoRa's 1–10 kbps practical throughput and regional duty-cycle limits make voice-over-LoRa a different product. See rationale at the bottom of this document.

### Hardware assumptions

Target Meshtastic-compatible devices — they're the closest thing to a de facto standard for consumer LoRa, and their firmware already implements:
- BLE GATT interface with documented services/characteristics
- Mesh routing (we get multi-hop for free)
- Channel config, region, and duty-cycle management
- Protobuf message framing

Specifically: RAK WisBlock (~$40), Heltec LoRa32 (~$25), LilyGO T-Beam (~$45). Flashed with stock Meshtastic firmware 2.x. The user plugs in a battery, pairs it via Klick's new pairing screen, and it acts as their long-range radio.

We do not ship hardware. We integrate with what users already have or can buy cheaply.

**⚠ Region-specific SKUs are not interchangeable.** LoRa hardware is sold per-band — a 915 MHz US radio is a *different radio* than an 865 MHz India radio or an 868 MHz EU radio. Buying the wrong band for your country is common, silent (the device still powers on), and illegal. Klick must detect this on pair and warn the user clearly. See the Risks section.

### Architecture

New module `Sources/Transport/LoRaBridge.swift`. Implements the `AudioTransport` protocol added in Phase 1, but for `.text`-type packets only — trying to send audio over it returns a "not supported on this transport" error.

```
┌─────────────────┐        BLE         ┌────────────────┐      LoRa     ┌────────────────┐
│  Klick iOS app  │ ◂──────GATT──────▸ │  Meshtastic    │ ◂──────RF────▸│  Meshtastic    │
│                 │   protobuf frames  │  radio (local) │               │  radio (peer)  │
└─────────────────┘                    └────────────────┘               └────────────────┘
                                                                                 │
                                                                                 │ BLE
                                                                                 ▼
                                                                        ┌────────────────┐
                                                                        │  Klick iOS app │
                                                                        └────────────────┘
```

Key flows:
1. **Accessory pairing** — new screen in Klick: "PAIR RADIO". BLE discovery filtered to Meshtastic service UUID (`6ba1b218-15a8-461f-9fa8-5dcae273eafd`). User picks their device, Klick stores its identifier.
2. **Outbound** — Klick builds a Meshtastic `MeshPacket` protobuf containing a `Data.Portnum.TEXT_MESSAGE_APP` payload (same channel config as peer), wraps it in Meshtastic's `ToRadio` envelope, writes to the ToRadio BLE characteristic.
3. **Inbound** — subscribe to the FromRadio characteristic. Decode `MeshPacket`s. Filter for our text app port. Push into the same incoming queue as MPC/UDP.

### Encryption: belt and suspenders

Meshtastic encrypts with AES-CTR using a 128-bit pre-shared channel key. We **keep our libsodium layer on top** — the wire payload inside the Meshtastic text message is our own `Packet` (version, type, seq, nonce, ciphertext). Reasons:

- Meshtastic's channel key is shared with anyone else who has it — doesn't give us per-pair E2EE
- Our own crypto means a Meshtastic mesh with other users on the same channel can't read Klick messages
- Nonce + seq on our side give us replay detection that Meshtastic doesn't

Cost: +40 bytes of overhead per message (our header). Tolerable for text; fatal for voice (another reason voice is out of scope).

### New packet types

- `0x04 morse_text` — already added in Phase 2
- `0x06 chat_text` — plain chat (not Morse), for users who don't want to tap out dits. Same payload as morse_text but a different type so the receiving UI can route it to a different view.

### UX

New screen `RadioView` (reached from `SYS` → `Radio`). The duty-cycle row only renders when the user's selected region actually has a duty-cycle rule — hidden in India and US, shown in EU.

```
┌─────────────────────────────────────────┐      ┌─────────────────────────────────────────┐
│ ◂ BACK           RADIO                  │      │ ◂ BACK           RADIO                  │
├─────────────────────────────────────────┤      ├─────────────────────────────────────────┤
│ STATUS  ● CONNECTED · RSSI -88 dBm      │      │ STATUS  ● CONNECTED · RSSI -94 dBm      │
│         MESHTASTIC HELTEC-V3            │      │         MESHTASTIC RAK4631              │
│         BATT 73% · CHAN PRIMARY         │      │         BATT 68% · CHAN PRIMARY         │
│                                         │      │                                         │
│ REGION       IN (865 MHz) [auto]  ▸    │      │ REGION       EU (868 MHz) [auto]  ▸    │
│ PRESET       LONG_FAST (1.07 kbps)      │      │ PRESET       LONG_FAST (1.07 kbps)      │
│ MAX POWER    30 dBm (1 W ERP)           │      │ MAX POWER    14 dBm (25 mW ERP)         │
│                                         │      │ DUTY CYCLE   12% used this hour         │
│ [ DISCONNECT ]       [ PAIR NEW... ]    │      │ [ DISCONNECT ]       [ PAIR NEW... ]    │
└─────────────────────────────────────────┘      └─────────────────────────────────────────┘
             India / US — no DC cap                           EU — DC ledger visible
```

The `REGION` row is tappable and opens a picker. It defaults to the device's locale (`Locale.current.region`) but the user can override — someone travelling or flashing a radio for a specific band needs that escape hatch. When the user's *locale* region disagrees with the *hardware* region read from Meshtastic, show a warning banner (see Risks).

In the main Settings `RANGE MODE` picker, a new option appears when a radio is paired: `● MESH (LoRa)`.

Peer list gains a `MESH` tag for peers reached over LoRa. Sending a voice PTT to a `MESH` peer is blocked at the UI layer with a tooltip: "LoRa link can't carry voice — switch to MORSE or CHAT."

### Regulatory reality

| Region | Band | Max power | Duty cycle | Notes |
|---|---|---|---|---|
| **US** (FCC Part 15) | 902–928 MHz (915 MHz ISM) | 30 dBm (1 W) | None | Cheapest hardware, widely available |
| **EU** (ETSI EN 300 220) | 863–870 MHz (typ. 868 MHz) | 14 dBm (25 mW) | **1%** on most sub-bands — ~36 s TX/hour | Duty-cycle ledger required in UI |
| **IN** (WPC SRD, India) | 865–867 MHz | **30 dBm (1 W ERP)** | **None** | License-exempt. 915 MHz is NOT legal in India. |
| Other | per Meshtastic region preset | per region | per region | Defer to Meshtastic firmware; Klick displays but doesn't override |

**Key design implications:**

- The duty-cycle ledger (tracking "% used this hour") is **EU-only**. In India and the US there is no such limit; showing that row would be misleading.
- India is the *most permissive* region we care about for Phase 3: no duty cycle, full 1 W, so range is longer there than anywhere else.
- Radios are sold per-band. A US 915 MHz board cannot legally operate in India or EU, and an India 865 MHz board cannot legally operate in the US. Meshtastic's `IN_865`, `US`, `EU_868`, etc. region presets must match the physical hardware, not just the user's preference.
- `Region` in Klick is a user setting, defaulted from `Locale.current.region` but user-overridable. When the app detects a mismatch between user-selected region and the hardware region reported by Meshtastic, it shows a non-dismissable warning banner before allowing TX.

### Risks

- **Wrong-region hardware** — user in India buys a cheap US 915 MHz radio off AliExpress, pairs it, and is now transmitting illegally on a protected Indian band. On pair, Klick reads the region reported by Meshtastic firmware and compares it to the user-selected region (defaulted from locale). On mismatch, show a blocking warning: "This radio is configured for US 915 MHz. Transmitting on this band in India is not legal. Disconnect or flash the radio to IN_865 before continuing." TX is disabled until resolved.
- **Accessory pairing UX is new territory** — BLE accessory flows are fiddly. Plan time for error recovery: "radio out of range", "radio powered off", "battery low", "bonding lost".
- **Meshtastic protocol changes** — they're on 2.x now, have broken compatibility in the past. Pin a minimum firmware version and detect on connect.
- **Latency** — LoRa packet airtime at SF10 is 1–2 seconds. Users need to feel this. Morse characters received one-by-one over 1s each feels OK; a 100-char message over 2 minutes does not. UI shows a progress state.
- **No delivery confirmation by default** — we add app-level ACKs (new packet type `0x07 ack`, echo the seq back) so users see "DELIVERED" / "SENDING" / "LOST".
- **Battery** — the radio is separate; its battery matters. We read it over BLE and warn at <20%.
- **Regulation** — we're not a certified radio vendor. Users are operating their own hardware; our app is a controller. Document this in TESTFLIGHT.md.

### Deliverables

- [ ] `Sources/Radio/MeshtasticBLE.swift` — GATT client, connection lifecycle
- [ ] `Sources/Radio/MeshtasticProtocol.swift` — protobuf encode/decode (pull Meshtastic's `.proto` definitions, generate via swift-protobuf)
- [ ] `Sources/Transport/LoRaBridge.swift` — `AudioTransport` conformance for text only
- [ ] `Sources/UI/RadioView.swift` — pairing, status, disconnect
- [ ] `Sources/UI/ChatView.swift` — plain text chat screen (non-Morse), addressed via `chat_text` packet
- [ ] Packet types `0x06 chat_text`, `0x07 ack`
- [ ] **Region model** — `enum Region { case us, eu, `in`, au, ... }` with per-region band, max power, and duty-cycle rule. Defaults from `Locale.current.region`, overridable in Settings.
- [ ] **Region-mismatch guard** — on pair, compare user-selected region to hardware-reported Meshtastic region; block TX with a clear warning when they disagree.
- [ ] **Duty-cycle ledger (EU only)** — per-sub-band ledger of airtime used in the rolling 1-hour window. Gated behind `region == .eu`. Persists across app launches. Hidden from UI in all other regions.
- [ ] Integration test against a real radio; unit test the protobuf codec
- [ ] Unit tests: region defaults by locale (US / IN / DE → correct region); duty-cycle ledger arithmetic (EU-only, no-op elsewhere)
- [ ] TESTFLIGHT.md section on radio requirements and supported hardware, with a region-by-region SKU guide (IN865 for India, US915 for US, EU868 for EU)

### Estimated scope

Large. ~2000+ new LoC. The protobuf layer alone is a few hundred. BLE lifecycle is notoriously finicky. 5–8 days + hardware iteration.

---

## Cross-cutting concerns

### Transport abstraction

Phase 1 introduces the `AudioTransport` protocol. Phases 2 and 3 both depend on it. By the end of Phase 3, `PTTSession` looks like:

```swift
final class PTTSession {
    private let transports: [AudioTransport]    // UDP, MPC, LoRa (as paired)
    private let directory = PeerDirectory()     // merged peers from all transports

    func send(_ packet: Packet, to peer: PeerHandle) {
        guard let tx = transports.first(where: { $0.handles(peer) }) else { return }
        guard tx.supports(packet.type) else { ... }
        tx.send(packet, to: peer)
    }
}
```

Transports self-declare which packet types they support. Voice (`0x01 audio`) is declined by LoRa. Text (`0x04`, `0x06`) is supported everywhere.

### Settings surface

After Phase 3, Settings gains:

```
RANGE MODE         (WIFI / NEARBY / MESH / BOTH)
MORSE              WPM, KEY vs TAP, flashlight on by default
RADIO              (opens RadioView)
UNPAIR ALL         (keychain wipe, unchanged from 1.0)
```

### Testing strategy

| Phase | New tests |
|---|---|
| 1 | MPC roundtrip between two simulators; transport-agnostic packet roundtrip |
| 2 | Morse encode/decode for all chars; timing state machine; tree traversal invariants; tone generator waveform sanity |
| 3 | Protobuf roundtrip against captured Meshtastic frames; duty-cycle ledger arithmetic; ACK sequence matching |

Audio capture, Bonjour, MPC, and BLE all need real hardware — unit tests cover the decoding/state-machine layers, manual tests cover the radio layers. Same approach as 1.0.

### Non-goals (still)

- **Voice over LoRa** — physics. See rationale above.
- **Group channels** — still unicast. Phase 4 material, when and if it comes up.
- **Persistent multi-peer pairing** — we still have one shared key per install. Bigger keychain surgery that none of these phases need.
- **Background operation** — PTT stays foreground-only. iOS PushToTalk framework could change this someday; not planned here.
- **Apple Watch** — out.

---

## Shipping order & branch strategy

Each phase is a feature branch off `main`, merged when it's independently shippable.

1. **`phase-1-mpc`** → merge → TestFlight build `0.2.0`. Ship and observe.
2. **`phase-2-morse`** → merge → TestFlight `0.3.0`. Independently usable: works on WiFi and MPC peers from day one.
3. **`phase-3-lora`** → merge → TestFlight `0.4.0`. Morse auto-works over it because it's just text.

If Phase 1 is painful enough in the field to warrant rework, Phase 2 can ship on top of the current 1.0 transport first — Morse doesn't depend on MPC existing.

---

## Why voice-over-LoRa is off the table (appendix)

For reference, in case the question comes up again.

| Constraint | Number |
|---|---|
| LoRa practical throughput | 1–10 kbps |
| Opus voice minimum | ~6 kbps, intelligibility drops fast below 12 |
| Codec2 at 3.2 kbps | Fits, sounds like HF-radio ham voice |
| Codec2 at 700 bps | Fits comfortably, sounds robotic but understandable |
| EU 868 MHz duty cycle | 1% = 36 s / hour on most sub-bands |
| LoRa packet airtime at SF10 | 1–2 s per packet |
| Half-duplex | One talker at a time on a channel |

Combined: a LoRa-voice Klick in Europe could legally transmit ~36 seconds of speech per hour, with 1–2 second latency, at HF-radio quality, one talker at a time, 2-device max (mesh saturates instantly). That's not a walkie-talkie — that's a party trick. FRS/GMRS/DMR exist for a reason.

If you ever want real long-range voice, it's a different product built around a different radio accessory. Morse + text over LoRa is the correct scope for Klick v2.
