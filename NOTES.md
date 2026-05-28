# Klick — Implementation Notes

Working notes. Updated ad-hoc. Source of truth for "what's done", "what's
broken", and "what we're holding off on until hardware arrives."

Last updated: 2026-05-28
Current version: `0.5.0` / build `6`
Test count: 104 unit tests, green on iPhone 16 simulator.

---

## Implemented

### Foundation (1.0, pre-Phase-1)
- PTT over UDP + Bonjour discovery on local WiFi.
- Opus voice codec @ 48 kHz mono, 16 kbps.
- libsodium XSalsa20 + Poly1305 encryption, 32-byte shared key exchanged via QR, stored in Keychain.
- Terminal-styled SwiftUI surface (see `Sources/UI/DesignTokens.swift`).

### Phase 1 — MultipeerConnectivity transport
**Commit:** `da1f0ae`
- `AudioTransport` protocol unifies UDP + MPC behind one surface.
- `UDPTransport` absorbed the old `BonjourBrowser` (one file per transport).
- `MPCTransport` — MCNearbyServiceAdvertiser + MCSession, works with no infra.
- `PeerDirectory` merges peers from both transports; `WIFI` / `NEAR` pills on rows.
- `RangeMode` user setting (`.wifi` / `.nearby` / `.both` / later `.mesh`).
- App renamed Walkie → **KlickKlick** (resolved TestFlight ITMS-90129).
- `NSBluetoothAlwaysUsageDescription` + `_klick-ptt-v1._tcp./._udp.` Bonjour types.

### Phase 2 — Morse subsystem
**Commits:** `468e32c`, `ac0300c`, `26ab81f` (initial), later simplified in `1da403a`
- `MorseCode` — ITU alphabet (A–Z, 0–9, 18 punct marks), encode/decode.
- `MorseTone` — AVAudioEngine sine at 600 Hz (CW sidetone) with 5 ms raised-cosine ramps.
- `FlashlightBeacon` — AVCaptureDevice.torchMode pulses, 15 Hz switch cap.
- Wire packet type `0x04 morseText`, routed through PTTSession.
- Originally had a tree-keying UI (later removed — see Morse Simplification).

### Phase 3a — Chat + regulatory model
**Commit:** `1db4ef3`
- Keyboard-typed Chat screen, works over existing WiFi/Nearby transports.
- `Region` enum (`us` / `eu` / `in_` / `au` / `other`) with band / max-power / duty-cycle rules; locale-defaulted.
- `DutyCycleLedger` — rolling 1-hour airtime tracker for EU 1% ETSI cap, JSON-persisted.
- Packet types `0x06 chatText`, `0x07 ack`.
- `TextEntry` with `kind` (chat/morse) and optional `sequence` for delivery tracking.
- Settings gained a REGION picker.

### Phase 3b.1 — Radio state model + UI skeleton
**Commit:** `1604298`
- `RangeMode.mesh` case.
- `RadioInfo` + `RadioState` — three-phase observable (.disconnected/.pairing/.connected), remembers last paired device across launches.
- `Region.compareToHardware(preset:)` → `RegionMismatch` (`.ok` / `.hardwareUnset` / `.mismatch`).
- `RadioView` — status pill, device metadata, region panel with blocking mismatch banner, EU-only duty-cycle row.

### Phase 3b.2a — LoRa architecture
**Commit:** `cac99a0`
- `MeshtasticLink` protocol + `FakeMeshtasticLink` for tests.
- `MeshtasticCodec` protocol + `StubMeshtasticCodec` (later replaced).
- `LoRaBridge` — `AudioTransport` conformer, text-only, refuses audio, duty-cycle gating.
- `MessageDeliveryTracker` — per-seq state machine (`.sending` → `.delivered`/`.failed`/`.timedOut`), 15 s default timeout.
- `PeerTransport.mesh` + "MESH" pill.
- `AudioTransport.sendText` returns wire sequence for delivery tracking.
- PTTSession: mesh pre-checks (radio connected + region matches + duty-cycle budget), `.ack` packet routing via tracker, LoRaBridge started when `RangeMode.includesMesh`.
- `ChatView` renders `…`/`✓`/`✗`/`⏲` delivery glyphs on outgoing mesh rows.

### Phase 3b.2b — Real Meshtastic integration
**Commit:** `db06d33`
- `ProtobufWire` — hand-rolled varint / fixed32 / length-delimited primitives.
- `MeshtasticProtoCodec` — real wire-compatible codec. Encodes `ToRadio { packet: MeshPacket { decoded: Data { portnum: PRIVATE_APP(256), payload: klickBytes } } }`. Field numbers verified against `meshtastic/protobufs` master.
- `CoreBluetoothMeshtasticLink` — CBCentralManager BLE client, service UUID `6ba1b218-…-5dcae273eafd`, discovers ToRadio/FromRadio/FromNum characteristics.
- `RadioView.PairSheet` — scanning UI with live RSSI-sorted device list.
- Info.plist Bluetooth usage string updated for LoRa radio.

### Version bump
**Commit:** `d873919`
- MARKETING_VERSION `0.1.0` → `0.4.0`, CURRENT_PROJECT_VERSION `1` → `3`.

### Morse simplification (keyboard + decoder)
**Commit:** `1da403a`
- Deleted `MorseTree` / `MorseTreeView` — tree keying removed.
- `ChatView` unified: one TextField + "SEND AS MORSE" switch next to send button.
- Preset chips: SOS / MAYDAY / HELP / OK / YES / NO / HI / BYE / ON MY WAY / WAIT / READY / DONE.
- New `MorseDemodulator` — shared state machine, adaptive dit-unit (seeded 300 ms).
- New `FlashlightDecoder` — AVCaptureSession, brightness threshold detection.
- New `AudioToneDecoder` — AVAudioEngine mic tap + Goertzel filter at 600 Hz.
- `ListenView` — CAMERA/AUDIO mode picker, level meter + decoded text.

### Main-screen reshuffle
**Commit:** `e611c7d` + `33b7c86`
- Clickable status tiles: LINK toggles start/stop, PAIR opens pair sheet, PEER opens peer-list sheet.
- Peer list moved behind the PEER tile (no longer fills the main screen).
- PTT pinned at the extreme bottom; TELEMETRY above it.
- LISTEN moved from ChatView header to main-screen nav.
- 4 nav pills: TALK / CHAT / LISTEN / SETTINGS, icon+text.
- SYS pill renamed to SETTINGS.

### Latest polish round (camera reticle + palette + speed dropdown + renames)
**Commit:** `44214e6`
- **Camera listen redesigned**: live camera preview + draggable reticle (corner ticks + crosshair) replaces the level bar. User aims reticle at the sender's flashlight; decoder samples only pixels under the reticle.
  - `CameraPreviewView` = `UIViewRepresentable` wrapping `AVCaptureVideoPreviewLayer` (gravity `.resizeAspect` so reticle ↔ sample-rect mapping is 1:1).
  - `FlashlightDecoder.sampleRect` is user-driven, thread-safe via internal lock.
  - Sensitivity tightened: on-threshold `+0.30`, off `+0.15` above baseline; 2-frame debounce.
- **Nav palette**: new tokens `navTalk` (amber), `navChat` (pink), `navListen` (purple), `navSettings` (grey). Semantic action colors (green/red/blue/amber) stay reserved for state.
- **Active-state contrast** on nav pills: tinted fill + thick border, no more inverted black-on-green.
- **Nav pills fill row** with `.minimumScaleFactor(0.7)` so SETTINGS fits iPhone SE.
- **Brand**: WALKIE → KLICK on the main screen; Settings header "SYS · WALKIE SETTINGS" → "KLICK · SYS SETTINGS".
- **Region picker** uses our mono font (custom `Menu` in place of `.pickerStyle(.menu)`, which ignores `.font()` on current iOS).
- **Morse speed UX**: `MorseSpeed` enum (Slow=8, Medium=12, Fast=20 WPM); `−/+` rocker replaced with a dropdown. Storage key migrated `morse.wpm` → `morse.speed`; rest of stack unchanged.
- **ListenView**: SWITCH button removed from decoder panes (BACK already returns to caller).
- `CH 01` / `OPUS 48K` / `XS20·P1305` kept as aesthetic badges (terminal look).

### Phase 4 — Channels + Multi-Peer PTT
- **Channel model**: `Channel` struct (id, name, members, createdAt) persisted as JSON in Documents dir.
- **ChannelStore**: `@MainActor ObservableObject` — CRUD, active channel tracking, auto-migration from legacy key → CH1.
- **Per-channel encryption**: Each channel gets its own 32-byte key stored in Keychain under `account: "channel:<id>"`. Legacy pairwise key (`account: "default"`) kept for invite encryption.
- **Multi-peer fan-out**: `selectedPeers: Set<PeerInfo>` replaces single `selectedPeer`. Audio and text encrypted once per frame, sent to each selected peer via their transport.
- **Trial decryption**: Incoming packets try active channel key first, then iterate other channel keys (MAC check fails fast on wrong key).
- **Channel switching**: Per-channel text history preserved in memory (`textHistoryByChannel` dictionary). Channel switch swaps visible history + loads new key.
- **Channel UI**: Tappable menu in brand strip (replaces static "CH 01"), `ChannelCreateView` sheet, `ChannelMembersView` with online/offline status + invite/remove.
- **Multi-select peer list**: `PeerListView` now uses `Set<PeerInfo>` binding with ■/□ toggle indicators, ALL/NONE buttons, DONE to confirm.
- **Members card on main screen**: Shows channel members with LIVE/OFF status, tappable to open members sheet. Telemetry strip condensed to single row.
- **Wire protocol additions**: `channelInvite (0x08)`, `channelInviteResponse (0x09)`.
- **Invite flow (QR)**: v2 payload `klick:ch:<channelId>:<channelKey>:<channelName>` (base64url). `PairingService` parses both v1 (legacy) and v2 (channel).
- **Invite flow (over-the-wire)**: `ChannelInviteCodec` encodes/decodes invite payloads. Encrypted with legacy pairwise key. `InviteReceivedView` for accept/decline.
- **PeerDirectory helpers**: `isOnline(_:)`, `resolve(_:)` for member status; `.mesh` added to rebuild order.
- Default channel names: CH1, CH2, etc. (sequential, user-renamable, ≤32 chars).

### Phase 5 — Discoverability, Camera Control, CallKit, Phone Mesh

#### 5a — Discoverability toggle
- `DiscoverabilityStore` (UserDefaults, key `klick.discoverable`, default ON).
- `AudioTransport` protocol gained `setAdvertising(_ enabled: Bool)`.
- `UDPTransport`: sets `listener.service = nil` to stop Bonjour ads while keeping listener alive for receiving.
- `MPCTransport`: calls `stopAdvertisingPeer()` / `startAdvertisingPeer()`.
- `LoRaBridge`: no-op (radio firmware controls visibility).
- `PTTSession.setDiscoverable(_:)` toggles all active transports.
- Settings UI: DISCOVERY section with ON/OFF tap-to-toggle row.

#### 5b — Camera Control PTT (iPhone 16)
- `CameraControlPTT` class wraps `AVCaptureEventInteraction` (iOS 17.2+).
- Captures full-press begin → `onBegin` (start transmit), end/cancel → `onEnd` (stop transmit).
- Guarded with `#if !targetEnvironment(simulator)` for clean sim builds.
- `CameraControlPTT.isAvailable` static check for feature detection.
- Wired in `PTTSession.init()` to `beginTransmit()`/`endTransmit()` + click sounds.

#### 5c — CallKit incoming alert
- `CallManager` — full `CXProviderDelegate` implementation.
- `reportIncomingCall(from:)` presents peer voice as a system call (rings, lock screen, bypasses DND).
- `endCall()` dismisses when transmission stops.
- `PTTSession` triggers ring when audio arrives while `UIApplication.shared.applicationState != .active`.
- `project.yml`: added `UIBackgroundModes: [audio, voip]` for background audio session + VoIP push capability.

#### 5d — Phone mesh relay (multi-hop)
- `MeshRelay` — flood-based relay engine with TTL (max 3 hops) and dedup cache (500 entries, FIFO).
- `MeshRelayStore` (UserDefaults, key `klick.meshRelay`, default ON).
- Wire format: packet type `relay (0x0A)`, payload = `[TTL:1][nameLen:1][origin:N][innerPacket:rest]`.
- On receive: unwrap envelope → process inner packet locally (trial decrypt) → if `shouldForward` (TTL>0, not seen, not self) → decrement TTL, re-wrap, forward to all other peers.
- Settings UI: MESH RELAY toggle row in DISCOVERY section.

---

## Known bugs / unfixed

### ✅ Audio listen crash — **fixed in build 5**
TestFlight 0.4.0/4 produced a symbolicated crash log (Thread 2, EXC_BREAKPOINT inside `_dispatch_assert_queue_fail`). Stack:

```
0  libdispatch  _dispatch_assert_queue_fail
3  libswift_Concurrency  _swift_task_checkIsolatedSwift
4  libswift_Concurrency  swift_task_isCurrentExecutorWithFlagsImpl
5  KlickKlick  closure #1 in AudioToneDecoder.start()
6  KlickKlick  thunk for @escaping (AVAudioPCMBuffer, AVAudioTime) -> ()
7  AVFAudio  AVAudioNodeTap::TapMessage::RealtimeMessenger_Perform
```

**Root cause:** the install-tap closure captured `self` (a `@MainActor` class). Even though `processBuffer` was `nonisolated`, Swift's runtime still inserts an executor check on the path *through* `self?.` — and the check calls `dispatch_assert_queue` on what it expects to be a known dispatch queue, but AVFAudio's `RealtimeMessageServiceQueue` is a private caulk-based realtime context. Assertion fails → crash.

**Fix (build 5):** moved `pendingSamples` + lock into a separate `Sendable` reference type (`SampleQueue` at the bottom of `AudioToneDecoder.swift`). The install-tap closure now captures only that queue, never `self`. No actor-isolated state on the audio thread → no executor check fires.

---

## Pending — needs real hardware

### Phase 1 — two-device device smoke test
- Two physical iPhones, airplane mode + Bluetooth on, verify MPC discovers and carries audio.
- Verify BOTH mode shows WIFI and NEAR rows for the same peer, selection routes correctly.
- Verify mic permission + Bluetooth permission prompts wording is sensible.

### Phase 2 — real-device VoiceOver walkthrough
- Accessibility labels on `ChatView` look right in code; need a live screen-reader pass.

### Phase 3b.2b — real Meshtastic radio verification
Anything BLE-adjacent can't be validated in the simulator. When a RAK WisBlock / Heltec LoRa32 / LilyGO T-Beam arrives:
- Scan discovers the device, RSSI feed looks reasonable.
- Connect → service discovery → subscribe flow completes.
- `writeValue(.withoutResponse)` frames are accepted by the firmware.
- FromRadio drain loop empties the queue on each FromNum notify.
- PRIVATE_APP-routed Klick payload round-trips between two Klick instances on the same Meshtastic channel.
- Region-mismatch guard activates when user region ≠ firmware region.
- Duty-cycle ledger is accurate against Meshtastic's reported airtime.

### Phase 4/5 — needs real hardware
- **Multi-device channel test**: Create CH2, invite peer via QR and over-the-wire, verify both sides see the channel + can decrypt.
- **Camera Control PTT**: Verify on physical iPhone 16 — press/release maps to TX start/stop.
- **CallKit ring**: Background app on device A, transmit from device B → device A rings and shows lock screen UI.
- **Phone mesh relay**: Three devices A↔B↔C (B relays), A sends text → C receives via B. Verify TTL decrement and dedup.
- **Discoverability**: Toggle OFF on device A, verify device B no longer sees A in peer list, but A can still browse and send.

### Nice-to-have polish
- Collapse same-name peers that appear on multiple transports into a single row with `BOTH` tag (currently shows two separate rows).
- Wire Meshtastic's reported airtime back into `DutyCycleLedger` in place of the hardcoded 1500 ms estimate.
- Channel key rotation when a member is removed (currently removed members still hold the old key).
- Persist chat history to disk (currently in-memory only, lost on app restart).
- Live Activity on lock screen showing active channel + TX/RX state.

---

## Architecture references

- `plan-v2.md` — the long-form plan doc for Phases 1/2/3. Kept up to date as phases landed.
- `Signing.xcconfig.example` — copy to `Signing.xcconfig` on a fresh clone, set `DEVELOPMENT_TEAM` for device builds.
- `project.yml` — xcodegen source; run `xcodegen generate` after adding new source files.
- Test target: `KlickKlickTests/`. Run via `xcodebuild … test` on an iPhone simulator.

### Source layout (updated)

```
Sources/
├── App/            — KlickKlickApp, PTTSession, CameraControlPTT, CallManager
├── Audio/          — AVAudioEngine capture/playback, Opus codec, ring buffer
├── Channel/        — Channel model, ChannelStore, ChannelInvite codec
├── Crypto/         — libsodium secretbox wrapper + Keychain key storage
├── Discovery/      — Bonjour, peer directory, range modes, discoverability
├── Morse/          — Tone/flashlight encode+decode, Goertzel filter, demodulator
├── Pairing/        — QR pairing (v1 legacy + v2 channel invite)
├── Radio/          — Meshtastic BLE link, protobuf codec, duty cycle, region
├── Transport/      — UDP, MPC, LoRa bridge, MeshRelay, packet protocol
└── UI/             — SwiftUI views, design tokens, channel/member/invite sheets
```
