import SwiftUI

/// LoRa radio status + pairing screen. Reached from Settings.
///
/// Phase 3b.1 ships the UI skeleton and reads from `RadioState` — but the
/// BLE client that flips that state from `.disconnected` to `.connected`
/// is Phase 3b.2 work (needs a Meshtastic radio in hand to verify). For
/// now, PAIR NEW is wired to a stub that shows a "not yet available"
/// sheet; every other part of the screen is real.
///
/// Sections:
///   1. STATUS — connected/disconnected pill, device name, battery, RSSI
///   2. REGION — user's Region setting, hardware region (when connected),
///      mismatch warning banner if the two disagree
///   3. BAND / POWER / DUTY CYCLE (EU only) — informational readout of the
///      regulatory envelope the radio will operate under
///   4. Actions — PAIR NEW / DISCONNECT / FORGET RADIO
struct RadioView: View {
    @ObservedObject var state: RadioState
    /// Mesh link the pair sheet drives. Optional so previews / unit
    /// tests can omit it.
    var link: CoreBluetoothMeshtasticLink?
    @Environment(\.dismiss) private var dismiss

    @State private var region: Region = RegionStore.current
    @State private var showingPairSheet = false

    var body: some View {
        ZStack {
            DT.bg.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    header

                    statusFrame

                    regionFrame

                    regulatoryFrame

                    actionFrame

                    Text("BLE PAIRING FLOW SHIPS IN A LATER BUILD. TODAY THIS SCREEN IS DISPLAY-ONLY.")
                        .walkieCaption()
                        .foregroundStyle(DT.textFaint)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
        .preferredColorScheme(.dark)
        .toolbar(.hidden)
        .sheet(isPresented: $showingPairSheet) {
            if let link {
                PairSheet(link: link, onPick: { entry in
                    state.beginPairing()
                    link.connect(to: entry.id)
                    showingPairSheet = false
                })
            } else {
                Text("Pairing requires a live BLE link. Present RadioView with a CoreBluetoothMeshtasticLink in production.")
                    .walkieCaption()
                    .padding()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Text("◂ BACK")
                    .walkieLabel(11)
                    .foregroundStyle(DT.info)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .overlay(Rectangle().strokeBorder(DT.info.opacity(0.6), lineWidth: 1))
            }
            .buttonStyle(.plain)

            Spacer()

            Text("RADIO")
                .walkieLabel(13, weight: .heavy, tracking: 3)
                .foregroundStyle(DT.text)

            Spacer()

            // Symmetric placeholder so the title stays centered.
            Text("")
                .frame(width: 60)
        }
    }

    // MARK: - Status

    private var statusFrame: some View {
        TerminalFrame("STATUS") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    statusDot
                    Text(statusText)
                        .walkieLabel(12, weight: .bold)
                        .foregroundStyle(statusColor)
                    Spacer()
                }
                if let info = state.displayInfo {
                    DotLeader(label: "MODEL",    value: info.model.uppercased())
                    DotLeader(label: "FIRMWARE", value: info.firmwareVersion)
                    if let bat = info.batteryPercent {
                        DotLeader(label: "BATTERY",
                                  value: "\(bat)%",
                                  valueColor: bat < 20 ? DT.warn : DT.text)
                    }
                    if let rssi = info.rssi {
                        DotLeader(label: "RSSI", value: "\(rssi) DBM")
                    }
                } else {
                    Text("NO RADIO HAS EVER BEEN PAIRED WITH THIS INSTALL.")
                        .walkieCaption()
                        .foregroundStyle(DT.textFaint)
                }
            }
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
    }

    private var statusColor: Color {
        switch state.phase {
        case .connected:    return DT.ok
        case .pairing:      return DT.warn
        case .disconnected: return state.rememberedDeviceId != nil ? DT.warn : DT.textFaint
        }
    }

    private var statusText: String {
        switch state.phase {
        case .connected(let info): return "CONNECTED · \(info.deviceName.uppercased())"
        case .pairing:             return "PAIRING…"
        case .disconnected:
            return state.rememberedDeviceId == nil
                ? "NO RADIO PAIRED"
                : "DISCONNECTED · LAST SEEN \(state.rememberedInfo?.deviceName.uppercased() ?? "—")"
        }
    }

    // MARK: - Region + mismatch

    private var regionFrame: some View {
        TerminalFrame("REGION") {
            VStack(alignment: .leading, spacing: 10) {
                DotLeader(label: "USER", value: region.displayName)
                if let info = state.displayInfo {
                    DotLeader(label: "HARDWARE",
                              value: info.regionPreset.isEmpty ? "UNSET" : info.regionPreset.uppercased(),
                              valueColor: hardwareRegionColor(info.regionPreset))
                }
                if case .mismatch(let user, let hw) = mismatch {
                    mismatchBanner(user: user, hardware: hw)
                } else if case .hardwareUnset = mismatch, state.isConnected {
                    hardwareUnsetBanner
                }
            }
        }
    }

    private var mismatch: RegionMismatch {
        guard let info = state.displayInfo else { return .ok }
        return region.compareToHardware(preset: info.regionPreset)
    }

    private func hardwareRegionColor(_ preset: String) -> Color {
        switch mismatch {
        case .ok:            return DT.ok
        case .mismatch:      return DT.tx
        case .hardwareUnset: return DT.warn
        }
    }

    private func mismatchBanner(user: Region, hardware: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("REGION MISMATCH")
                    .walkieLabel(11, weight: .heavy)
            }
            .foregroundStyle(DT.tx)
            Text("RADIO IS FLASHED FOR \(hardware). TX IS BLOCKED IN \(user.displayName) UNTIL YOU RE-FLASH THE RADIO OR CHANGE YOUR REGION IN SETTINGS.")
                .walkieCaption()
                .foregroundStyle(DT.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(DT.tx.opacity(0.10))
        .overlay(Rectangle().strokeBorder(DT.tx, lineWidth: 1))
    }

    private var hardwareUnsetBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                Text("HARDWARE REGION UNSET")
                    .walkieLabel(11, weight: .heavy)
            }
            .foregroundStyle(DT.warn)
            Text("THE RADIO HAS NO REGION PRESET. FLASH \(region.meshtasticPreset) IN THE MESHTASTIC APP BEFORE TRANSMITTING.")
                .walkieCaption()
                .foregroundStyle(DT.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(DT.warn.opacity(0.10))
        .overlay(Rectangle().strokeBorder(DT.warn, lineWidth: 1))
    }

    // MARK: - Regulatory

    private var regulatoryFrame: some View {
        TerminalFrame("REGULATORY") {
            VStack(alignment: .leading, spacing: 8) {
                DotLeader(label: "BAND",      value: region.displayName)
                DotLeader(label: "MAX POWER", value: "\(region.maxPowerDbm) DBM")
                if let dc = region.dutyCycle {
                    // Duty-cycle row only renders in regions that have one;
                    // showing "DUTY CYCLE: NONE" in US/IN would be misleading.
                    DotLeader(label: "DUTY CYCLE",
                              value: "\(Int(dc * 100))% / HOUR",
                              valueColor: DT.warn)
                    Text("EU HARDWARE IS CAPPED AT \(Int(dc * 3600 * 1000)) MS ON-AIR PER ROLLING HOUR BY ETSI EN 300 220.")
                        .walkieCaption()
                        .foregroundStyle(DT.textFaint)
                }
            }
        }
    }

    // MARK: - Actions

    private var actionFrame: some View {
        TerminalFrame("ACTIONS") {
            VStack(spacing: 10) {
                Button(action: { showingPairSheet = true }) {
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                        Text("PAIR NEW RADIO…")
                            .walkieLabel(12)
                    }
                    .foregroundStyle(DT.info)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .overlay(Rectangle().strokeBorder(DT.info.opacity(0.6), lineWidth: 1))
                }
                .buttonStyle(.plain)

                if state.rememberedDeviceId != nil {
                    Button(action: { state.forget() }) {
                        HStack {
                            Image(systemName: "xmark.circle")
                            Text("FORGET PAIRED RADIO")
                                .walkieLabel(12)
                        }
                        .foregroundStyle(DT.tx)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .overlay(Rectangle().strokeBorder(DT.tx.opacity(0.7), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Scan-and-pick sheet shown when the user taps PAIR NEW RADIO.
/// Starts a BLE scan on appear, shows discovered devices sorted by
/// strongest signal, invokes `onPick` with the chosen entry.
private struct PairSheet: View {
    let link: CoreBluetoothMeshtasticLink
    let onPick: (CoreBluetoothMeshtasticLink.ScanEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var results: [CoreBluetoothMeshtasticLink.ScanEntry] = []

    var body: some View {
        ZStack {
            DT.bg.ignoresSafeArea()
            VStack(spacing: 16) {
                HStack {
                    Text("SCAN")
                        .walkieLabel(13, weight: .heavy, tracking: 3)
                        .foregroundStyle(DT.text)
                    Spacer()
                    Button("CLOSE") { dismiss() }
                        .font(DT.mono(11, weight: .bold))
                        .tracking(DT.labelTracking)
                        .foregroundStyle(DT.textDim)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .overlay(Rectangle().strokeBorder(DT.border, lineWidth: 1))
                        .buttonStyle(.plain)
                }

                TerminalFrame("DISCOVERED") {
                    if results.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                ProgressView().tint(DT.info)
                                Text("SCANNING FOR MESHTASTIC RADIOS…")
                                    .walkieLabel(11)
                                    .foregroundStyle(DT.textDim)
                            }
                            Text("KEEP THE RADIO POWERED ON AND WITHIN A FEW METERS.")
                                .walkieCaption()
                                .foregroundStyle(DT.textFaint)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(results) { entry in
                                Button { onPick(entry) } label: {
                                    HStack {
                                        Text(entry.name.uppercased())
                                            .walkieLabel(12)
                                            .foregroundStyle(DT.text)
                                        Spacer()
                                        Text("\(entry.rssi) DBM")
                                            .font(DT.mono(10))
                                            .foregroundStyle(DT.textDim)
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(DT.info)
                                    }
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 10)
                                    .overlay(Rectangle().strokeBorder(DT.border, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            link.onScanResults = { entries in
                Task { @MainActor in
                    results = entries
                }
            }
            link.startScan()
        }
        .onDisappear {
            link.stopScan()
        }
    }
}
