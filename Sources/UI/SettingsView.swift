import SwiftUI

/// Terminal-style settings sheet. Phase 1: device name + unpair + about.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = DeviceName.current
    @State private var rangeMode: RangeMode = RangeModeStore.current
    @State private var showingUnpairConfirm = false
    @State private var unpaired = false

    var body: some View {
        NavigationStack {
            ZStack {
                DT.bg.ignoresSafeArea()
                ScrollView {
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
            Text("SYS · WALKIE SETTINGS")
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
        dismiss()
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
