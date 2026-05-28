import SwiftUI
import Sodium

/// Sheet for creating a new channel. Generates a fresh key and persists
/// the channel immediately on CREATE.
struct ChannelCreateView: View {
    @ObservedObject var channelStore: ChannelStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var passphrase: String = ""

    var body: some View {
        ZStack {
            DT.bg.ignoresSafeArea()
            VStack(spacing: 20) {
                HStack {
                    Text("NEW CHANNEL")
                        .walkieLabel(13, weight: .heavy, tracking: 3)
                        .foregroundStyle(DT.text)
                    Spacer()
                    Button("CANCEL") { dismiss() }
                        .font(DT.mono(11, weight: .bold))
                        .tracking(DT.labelTracking)
                        .foregroundStyle(DT.textDim)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .overlay(Rectangle().strokeBorder(DT.border, lineWidth: 1))
                        .buttonStyle(.plain)
                }

                TerminalFrame("NAME") {
                    TextField("", text: $name)
                        .font(DT.mono(14, weight: .semibold))
                        .foregroundStyle(DT.text)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                        .padding(.vertical, 8)
                }

                Text("≤ 32 CHARACTERS · FREE TEXT")
                    .walkieCaption()
                    .foregroundStyle(DT.textFaint)

                TerminalFrame("OR JOIN BY PASSPHRASE") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("TYPE SHARED PASSPHRASE", text: $passphrase)
                            .font(DT.mono(14, weight: .semibold))
                            .foregroundStyle(DT.text)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(.vertical, 8)
                        Text("EVERYONE WITH THE SAME PASSPHRASE JOINS THE SAME CHANNEL.")
                            .walkieCaption()
                            .foregroundStyle(DT.textFaint)
                        Button(action: joinByPassphrase) {
                            Text("JOIN")
                                .walkieLabel(11, weight: .heavy, tracking: 2)
                                .foregroundStyle(DT.bg)
                                .frame(maxWidth: .infinity)
                                .frame(height: 36)
                                .background(DT.info)
                        }
                        .buttonStyle(.plain)
                        .disabled(passphrase.trimmingCharacters(in: .whitespaces).isEmpty)
                        .opacity(passphrase.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
                    }
                }

                Spacer()

                Button(action: createChannel) {
                    Text("CREATE NEW")
                        .walkieLabel(13, weight: .heavy, tracking: 3)
                        .foregroundStyle(DT.bg)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(DT.ok)
                }
                .buttonStyle(.plain)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            name = channelStore.nextDefaultName
        }
    }

    private func createChannel() {
        let trimmed = String(name.trimmingCharacters(in: .whitespaces).prefix(32))
        guard !trimmed.isEmpty else { return }
        let sodium = Sodium()
        let key = sodium.secretBox.key()
        let channel = channelStore.create(name: trimmed, key: Data(key))
        channelStore.setActive(channel.id)
        dismiss()
    }

    private func joinByPassphrase() {
        let trimmed = passphrase.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        channelStore.joinByPassphrase(trimmed)
        dismiss()
    }
}
