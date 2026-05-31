import SwiftUI

/// Terminal-style settings sheet.
struct SettingsView: View {
    @ObservedObject var radio: RadioState
    /// Optional mesh link, forwarded to `RadioView` so its PAIR sheet can
    /// drive a real BLE scan. Nil in previews / unit tests.
    var meshLink: CoreBluetoothMeshtasticLink?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = DeviceName.current
    @State private var rangeMode: RangeMode = RangeModeStore.current
    @State private var region: Region = RegionStore.current
    @State private var discoverable: Bool = DiscoverabilityStore.isDiscoverable
    @State private var meshRelayEnabled: Bool = MeshRelayStore.isEnabled
    @State private var customRelayURL: String = RelayConfig.customURL ?? ""
    @State private var showingUnpairConfirm = false
    @State private var unpaired = false

    var body: some View {
        NavigationStack {
            ZStack {
                DT.bg.ignoresSafeArea()
                ScrollView(.vertical) {
                    VStack(spacing: 16) {
                        header

                        TerminalFrame("IDENTITY") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("DEVICE NAME")
                                    .walkieLabel(10)
                                    .foregroundStyle(DT.textDim)
                                TextField("", text: $name)
                                    .textInputAutocapitalization(.characters)
                                    .autocorrectionDisabled()
                                    .submitLabel(.done)
                                    .font(DT.mono(14, weight: .semibold))
                                    .foregroundStyle(DT.text)
                                    .tint(DT.info)
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 10)
                                    .background(DT.panel)
                                    .overlay(Rectangle().strokeBorder(DT.border, lineWidth: 1))
                                Text("SHOWN TO OTHER DEVICES DURING DISCOVERY.")
                                    .walkieCaption()
                                    .foregroundStyle(DT.textFaint)
                            }
                        }

                        TerminalFrame("DISCOVERY") {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("DISCOVERABLE")
                                        .walkieLabel(11)
                                        .foregroundStyle(DT.text)
                                    Spacer()
                                    Text(discoverable ? "ON" : "OFF")
                                        .font(DT.mono(11, weight: .bold))
                                        .foregroundStyle(discoverable ? DT.ok : DT.textFaint)
                                }
                                .contentShape(.rect)
                                .onTapGesture { discoverable.toggle() }
                                Text(discoverable
                                     ? "OTHERS CAN SEE YOU IN PEER SCANS."
                                     : "HIDDEN · YOU CAN STILL SEE OTHERS.")
                                    .walkieCaption()
                                    .foregroundStyle(DT.textFaint)

                                Rectangle().fill(DT.border).frame(height: 1).opacity(0.4)

                                HStack {
                                    Text("MESH RELAY")
                                        .walkieLabel(11)
                                        .foregroundStyle(DT.text)
                                    Spacer()
                                    Text(meshRelayEnabled ? "ON" : "OFF")
                                        .font(DT.mono(11, weight: .bold))
                                        .foregroundStyle(meshRelayEnabled ? DT.ok : DT.textFaint)
                                }
                                .contentShape(.rect)
                                .onTapGesture { meshRelayEnabled.toggle() }
                                Text("RELAY PACKETS FOR PEERS NOT IN DIRECT RANGE.")
                                    .walkieCaption()
                                    .foregroundStyle(DT.textFaint)
                            }
                        }

                        TerminalFrame("RANGE MODE") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(RangeMode.allCases, id: \.self) { mode in
                                    RangeModeRow(
                                        mode: mode,
                                        isSelected: rangeMode == mode,
                                        onTap: { rangeMode = mode }
                                    )
                                }
                                Text("CHANGES APPLY AFTER YOU RESTART THE SESSION (STOP → START).")
                                    .walkieCaption()
                                    .foregroundStyle(DT.textFaint)
                            }
                        }

                        TerminalFrame("RELAY") {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("SERVER")
                                        .walkieLabel(10)
                                        .foregroundStyle(DT.textDim)
                                    Spacer()
                                    Text(customRelayURL.isEmpty ? "DEFAULT" : "CUSTOM")
                                        .font(DT.mono(10, weight: .bold))
                                        .foregroundStyle(customRelayURL.isEmpty ? DT.ok : DT.info)
                                }
                                TextField("wss://your-relay.workers.dev", text: $customRelayURL)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .keyboardType(.URL)
                                    .font(DT.mono(12, weight: .regular))
                                    .foregroundStyle(DT.text)
                                    .tint(DT.info)
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 8)
                                    .background(DT.panel)
                                    .overlay(Rectangle().strokeBorder(DT.border, lineWidth: 1))
                                Text("LEAVE EMPTY TO USE DEFAULT RELAY. ENTER CUSTOM URL FOR SELF-HOSTED.")
                                    .walkieCaption()
                                    .foregroundStyle(DT.textFaint)
                            }
                        }

                        TerminalFrame("REGION") {
                            VStack(alignment: .leading, spacing: 10) {
                                // Custom Menu in place of .pickerStyle(.menu)
                                // so the label respects our mono font —
                                // SwiftUI's built-in picker button uses
                                // the system font and ignores `.font` in
                                // most iOS versions.
                                Menu {
                                    ForEach(Region.allCases, id: \.self) { r in
                                        Button {
                                            region = r
                                        } label: {
                                            Text(r.displayName)
                                            if r == region {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                } label: {
                                    HStack {
                                        Text(region.displayName)
                                            .font(DT.mono(13, weight: .semibold))
                                            .foregroundStyle(DT.text)
                                        Spacer()
                                        Image(systemName: "chevron.up.chevron.down")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(DT.info)
                                    }
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 10)
                                    .background(DT.panel)
                                    .overlay(Rectangle().strokeBorder(DT.border, lineWidth: 1))
                                }
                                .buttonStyle(.plain)

                                if !RegionStore.isUserOverridden {
                                    // Tell the user we defaulted this from
                                    // their locale so they know it's a guess
                                    // they can override.
                                    Text("AUTO · DEFAULTED FROM YOUR DEVICE LOCALE.")
                                        .walkieCaption()
                                        .foregroundStyle(DT.textFaint)
                                }

                                DotLeader(label: "BAND",      value: region.displayName)
                                DotLeader(label: "MAX POWER", value: "\(region.maxPowerDbm) DBM")
                                if let dc = region.dutyCycle {
                                    DotLeader(label: "DUTY CYCLE",
                                              value: "\(Int(dc * 100))% / HOUR",
                                              valueColor: DT.warn)
                                }
                                Text("REGION GOVERNS LORA BAND + POWER IN PHASE 3B. TODAY IT'S DISPLAY-ONLY.")
                                    .walkieCaption()
                                    .foregroundStyle(DT.textFaint)
                            }
                        }

                        TerminalFrame("RADIO") {
                            VStack(alignment: .leading, spacing: 10) {
                                DotLeader(label: "STATUS",
                                          value: radioStatusText,
                                          valueColor: radioStatusColor)
                                if let info = radio.displayInfo {
                                    DotLeader(label: "DEVICE", value: info.deviceName.uppercased())
                                }
                                NavigationLink {
                                    RadioView(state: radio, link: meshLink)
                                } label: {
                                    HStack {
                                        Image(systemName: "antenna.radiowaves.left.and.right")
                                        Text("OPEN RADIO…")
                                            .walkieLabel(12)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 10, weight: .bold))
                                    }
                                    .foregroundStyle(DT.info)
                                    .padding(.vertical, 10)
                                    .padding(.horizontal, 10)
                                    .overlay(Rectangle().strokeBorder(DT.info.opacity(0.6), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                Text("PHASE 3B.1 · READ-ONLY STATUS. BLE PAIRING SHIPS LATER.")
                                    .walkieCaption()
                                    .foregroundStyle(DT.textFaint)
                            }
                        }

                        TerminalFrame("PAIRING") {
                            VStack(alignment: .leading, spacing: 10) {
                                DotLeader(
                                    label: "STATUS",
                                    value: unpaired ? "UNPAIRED" : "SEE MAIN SCREEN",
                                    valueColor: unpaired ? DT.warn : DT.info
                                )
                                Button(action: { showingUnpairConfirm = true }) {
                                    HStack {
                                        Image(systemName: "lock.slash")
                                        Text("UNPAIR THIS DEVICE")
                                            .walkieLabel(12)
                                    }
                                    .foregroundStyle(DT.tx)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .overlay(Rectangle().strokeBorder(DT.tx.opacity(0.7), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                Text("REMOVES THE SHARED KEY FROM KEYCHAIN. YOU'LL NEED TO RE-SCAN A QR CODE TO TALK.")
                                    .walkieCaption()
                                    .foregroundStyle(DT.textFaint)
                            }
                        }

                        TerminalFrame("ABOUT") {
                            VStack(alignment: .leading, spacing: 8) {
                                DotLeader(label: "BUILD",    value: appVersion)
                                DotLeader(label: "CODEC",    value: "OPUS/48K/MONO")
                                DotLeader(label: "CIPHER",   value: "XSALSA20 + P1305")
                                DotLeader(label: "DISCOVERY", value: "_WALKIE._UDP.")
                                DotLeader(label: "PACKET",   value: "40B HEADER")
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .onAppear {
                    // iOS 26: prevent horizontal bounce on vertical-only ScrollView
                    UIScrollView.appearance().alwaysBounceHorizontal = false
                    UIScrollView.appearance().showsHorizontalScrollIndicator = false
                }
            }
            .preferredColorScheme(.dark)
            .toolbar(.hidden)
            .confirmationDialog(
                "REMOVE PAIRED KEY?",
                isPresented: $showingUnpairConfirm,
                titleVisibility: .visible
            ) {
                Button("UNPAIR", role: .destructive) {
                    try? PairingService().unpair()
                    unpaired = true
                }
                Button("CANCEL", role: .cancel) {}
            } message: {
                Text("YOU'LL NEED TO RE-SCAN A QR CODE TO TALK AGAIN.")
            }
        }
    }

    private var header: some View {
        HStack {
            Text("KLICK · SYS SETTINGS")
                .walkieLabel(11, weight: .bold)
                .foregroundStyle(DT.text)
            Spacer()
            Button(action: { dismiss() }) {
                Text("CANCEL")
                    .walkieLabel(11)
                    .foregroundStyle(DT.textDim)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .overlay(Rectangle().strokeBorder(DT.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            Button(action: save) {
                Text("SAVE")
                    .walkieLabel(11)
                    .foregroundStyle(DT.ok)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .overlay(Rectangle().strokeBorder(DT.ok.opacity(0.6), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private func save() {
        DeviceName.set(name)
        RangeModeStore.set(rangeMode)
        RegionStore.current = region
        DiscoverabilityStore.isDiscoverable = discoverable
        MeshRelayStore.isEnabled = meshRelayEnabled
        RelayConfig.customURL = customRelayURL.trimmingCharacters(in: .whitespaces).isEmpty ? nil : customRelayURL
        dismiss()
    }

    private var radioStatusText: String {
        switch radio.phase {
        case .connected:    return "CONNECTED"
        case .pairing:      return "PAIRING…"
        case .disconnected:
            return radio.rememberedDeviceId == nil ? "NOT PAIRED" : "DISCONNECTED"
        }
    }

    private var radioStatusColor: Color {
        switch radio.phase {
        case .connected:    return DT.ok
        case .pairing:      return DT.warn
        case .disconnected: return radio.rememberedDeviceId != nil ? DT.warn : DT.textFaint
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(v).\(b)"
    }
}

/// One row in the RANGE MODE picker. Radio-button style: a filled square
/// for the selected row, hollow for others. Tap area covers the whole row.
private struct RangeModeRow: View {
    let mode: RangeMode
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // "●" filled / "○" hollow indicator, styled as a mono glyph so
            // it aligns with the rest of the terminal look.
            ZStack {
                Rectangle()
                    .strokeBorder(isSelected ? DT.ok : DT.border, lineWidth: 1)
                    .frame(width: 12, height: 12)
                if isSelected {
                    Rectangle()
                        .fill(DT.ok)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.top, 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(mode.displayName)
                    .walkieLabel(12, weight: .bold)
                    .foregroundStyle(isSelected ? DT.text : DT.textDim)
                Text(mode.subtitle)
                    .walkieCaption()
                    .foregroundStyle(DT.textFaint)
            }

            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        .onTapGesture(perform: onTap)
    }
}
