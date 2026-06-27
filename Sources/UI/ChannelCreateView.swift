import SwiftUI
import Sodium

/// Sheet for creating a new channel. Single-purpose: pick a name, generate
/// a fresh 32-byte key, persist. The parent is expected to present
/// `InviteSheet` for the new channel immediately after dismissal so the
/// user lands directly on the share/invite step.
struct ChannelCreateView: View {
    @ObservedObject var channelStore: ChannelStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""

    /// Called with the freshly-created channel right before dismissal so
    /// the parent can immediately present an invite sheet for it.
    var onCreated: ((Channel) -> Void)?

    var body: some View {
        ZStack {
            DT.bg.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 20) {
                    HStack {
                        Text("NEW CHANNEL")
                            .walkieLabel(13, weight: .bold, tracking: 3)
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

                    TerminalFrame("CREATE NEW") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("CHANNEL NAME")
                                .walkieLabel(10)
                                .foregroundStyle(DT.textDim)
                            TextField("", text: $name)
                                .font(DT.mono(14, weight: .semibold))
                                .foregroundStyle(DT.text)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.characters)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 8)
                                .background(DT.panel)
                                .overlay(Rectangle().strokeBorder(DT.border, lineWidth: 1))
                            Text("≤ 32 CHARACTERS · FREE TEXT")
                                .walkieCaption()
                                .foregroundStyle(DT.textFaint)
                            Button(action: createChannel) {
                                Text("CREATE")
                                    .walkieLabel(11, weight: .bold, tracking: 2)
                                    .foregroundStyle(DT.bg)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 36)
                                    .background(DT.ok)
                            }
                            .buttonStyle(.plain)
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                            .opacity(name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
                            Text("YOU'LL GET AN INVITE SHEET TO SHARE THE CHANNEL NEXT.")
                                .walkieCaption()
                                .foregroundStyle(DT.textFaint)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
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
        onCreated?(channel)
        dismiss()
    }
}
