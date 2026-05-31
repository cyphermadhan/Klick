import SwiftUI

/// Sheet showing current channel members with online/offline status
/// and invite/remove actions.
struct ChannelMembersView: View {
    @ObservedObject var session: PTTSession
    @Environment(\.dismiss) private var dismiss
    @State private var showingInvite = false
    @State private var showingDeleteConfirm = false

    private var channel: Channel? { session.channelStore.activeChannel }

    var body: some View {
        ZStack {
            DT.bg.ignoresSafeArea()
            VStack(spacing: 14) {
                HStack {
                    Text("MEMBERS · \(channel?.displayName ?? "")")
                        .walkieLabel(13, weight: .bold, tracking: 3)
                        .foregroundStyle(DT.text)
                    Spacer()
                    Button("DONE") { dismiss() }
                        .font(DT.mono(11, weight: .bold))
                        .tracking(DT.labelTracking)
                        .foregroundStyle(DT.textDim)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .overlay(Rectangle().strokeBorder(DT.border, lineWidth: 1))
                        .buttonStyle(.plain)
                }

                if let channel {
                    TerminalFrame("ROSTER") {
                        if channel.members.isEmpty {
                            Text("NO MEMBERS YET · INVITE PEERS BELOW")
                                .walkieCaption()
                                .foregroundStyle(DT.textFaint)
                                .padding(.vertical, 8)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(channel.members) { member in
                                    memberRow(member)
                                    if member.id != channel.members.last?.id {
                                        Rectangle().fill(DT.border).frame(height: 1).opacity(0.4)
                                    }
                                }
                            }
                        }
                    }
                }

                Spacer()

                if let channel, channel.creatorName == DeviceName.current {
                    TerminalFrame("MODE") {
                        HStack {
                            Text("BROADCAST")
                                .walkieLabel(11)
                                .foregroundStyle(DT.text)
                            Spacer()
                            Text(channel.isBroadcast ? "ON" : "OFF")
                                .font(DT.mono(11, weight: .bold))
                                .foregroundStyle(channel.isBroadcast ? DT.warn : DT.textFaint)
                        }
                        .contentShape(.rect)
                        .onTapGesture {
                            if let id = channel.id as String? {
                                session.channelStore.toggleBroadcast(id)
                            }
                        }
                    }
                }

                Button(action: { showingInvite = true }) {
                    Text("INVITE PEER")
                        .walkieLabel(13, weight: .bold, tracking: 3)
                        .foregroundStyle(DT.bg)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(DT.info)
                }
                .buttonStyle(.plain)

                if session.channelStore.channels.count > 1 {
                    Button(action: { showingDeleteConfirm = true }) {
                        Text("DELETE CHANNEL")
                            .walkieLabel(11, weight: .bold, tracking: 2)
                            .foregroundStyle(DT.tx)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .overlay(Rectangle().strokeBorder(DT.tx.opacity(0.5), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingInvite) {
            InvitePeerSheet(session: session)
        }
        .alert("DELETE CHANNEL", isPresented: $showingDeleteConfirm) {
            Button("DELETE", role: .destructive) {
                if let id = channel?.id {
                    session.channelStore.delete(id: id)
                    dismiss()
                }
            }
            Button("CANCEL", role: .cancel) {}
        } message: {
            Text("This will remove the channel and its key from this device. Other members are not affected.")
        }
    }

    private func memberRow(_ member: ChannelMember) -> some View {
        let online = session.directory.isOnline(member.name)
        return HStack(spacing: 10) {
            Text(member.name.uppercased())
                .font(DT.mono(13, weight: .semibold))
                .foregroundStyle(DT.text)
                .lineLimit(1)
            Spacer()
            Text(online ? "ONLINE" : "OFFLINE")
                .font(DT.mono(10, weight: .bold))
                .tracking(1)
                .foregroundStyle(online ? DT.ok : DT.textFaint)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .overlay(
                    Rectangle().strokeBorder(
                        (online ? DT.ok : DT.textFaint).opacity(0.5), lineWidth: 1
                    )
                )
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 2)
        .contentShape(.rect)
        .contextMenu {
            Button(role: .destructive) {
                if let chId = channel?.id {
                    session.channelStore.removeMember(name: member.name, from: chId)
                }
            } label: {
                Label("Remove", systemImage: "minus.circle")
            }
        }
    }
}

/// Sub-sheet for picking an online peer to send a channel invite to,
/// or sharing an invite link via any messaging app.
struct InvitePeerSheet: View {
    @ObservedObject var session: PTTSession
    @Environment(\.dismiss) private var dismiss
    @State private var showingShareSheet = false

    private var inviteLink: String? {
        guard let channel = session.channelStore.activeChannel,
              let key = session.channelStore.key(for: channel.id) else { return nil }
        let pairing = PairingService()
        let payload = pairing.channelQRPayload(channelId: channel.id, channelKey: key, channelName: channel.name)
        // URL-encode the payload so it's a tappable link that opens the app
        let encoded = payload.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? payload
        return "klick://join?payload=\(encoded)"
    }

    var body: some View {
        ZStack {
            DT.bg.ignoresSafeArea()
            VStack(spacing: 14) {
                HStack {
                    Text("INVITE")
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

                // MARK: Invite via link
                TerminalFrame("SHARE LINK") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("SEND VIA ANY APP — RECIPIENT TAPS TO JOIN.")
                            .walkieCaption()
                            .foregroundStyle(DT.textFaint)
                        Button(action: { showingShareSheet = true }) {
                            HStack(spacing: 6) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 12, weight: .bold))
                                Text("SHARE INVITE LINK")
                                    .walkieLabel(11, weight: .bold, tracking: 2)
                            }
                            .foregroundStyle(DT.bg)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(DT.info)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // MARK: Send to online peer directly
                TerminalFrame("ONLINE PEERS") {
                    if session.directory.peers.isEmpty {
                        Text("NO PEERS NEARBY")
                            .walkieCaption()
                            .foregroundStyle(DT.textFaint)
                            .padding(.vertical, 8)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(session.directory.peers) { peer in
                                Button {
                                    sendInvite(to: peer)
                                } label: {
                                    HStack {
                                        Text(peer.name.uppercased())
                                            .font(DT.mono(13, weight: .semibold))
                                            .foregroundStyle(DT.text)
                                        Spacer()
                                        Text(peer.transport.tag)
                                            .font(DT.mono(10, weight: .bold))
                                            .foregroundStyle(DT.info)
                                    }
                                    .padding(.vertical, 10)
                                    .padding(.horizontal, 2)
                                    .contentShape(.rect)
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
        .sheet(isPresented: $showingShareSheet) {
            if let link = inviteLink {
                ShareSheet(items: [
                    "Join my Klick channel: \(link)"
                ])
            }
        }
    }

    private func sendInvite(to peer: PeerInfo) {
        guard let channel = session.channelStore.activeChannel else { return }
        session.sendChannelInvite(channel: channel, to: peer)
        session.channelStore.addMember(
            ChannelMember(name: peer.name, addedAt: .now),
            to: channel.id
        )
        dismiss()
    }
}

/// UIKit share sheet wrapped for SwiftUI.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
