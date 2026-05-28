import SwiftUI

/// Sheet showing pending channel invites with accept/decline.
struct InviteReceivedView: View {
    @ObservedObject var session: PTTSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            DT.bg.ignoresSafeArea()
            VStack(spacing: 14) {
                HStack {
                    Text("INVITES")
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

                if session.pendingInvites.isEmpty {
                    Spacer()
                    Text("NO PENDING INVITES")
                        .walkieCaption()
                        .foregroundStyle(DT.textFaint)
                    Spacer()
                } else {
                    TerminalFrame("PENDING") {
                        VStack(spacing: 0) {
                            ForEach(session.pendingInvites) { invite in
                                inviteRow(invite)
                                Rectangle().fill(DT.border).frame(height: 1).opacity(0.4)
                            }
                        }
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .preferredColorScheme(.dark)
    }

    private func inviteRow(_ invite: ChannelInvite) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CH: \(invite.channelName.uppercased())")
                    .font(DT.mono(13, weight: .semibold))
                    .foregroundStyle(DT.text)
                Spacer()
                Text("FROM: \(invite.senderName.uppercased())")
                    .font(DT.mono(10, weight: .bold))
                    .foregroundStyle(DT.textDim)
            }
            Text("KEY: \(PairingService.fingerprint(of: invite.channelKey))")
                .font(DT.mono(10))
                .foregroundStyle(DT.textFaint)
            HStack(spacing: 10) {
                Button {
                    session.acceptInvite(invite)
                    if session.pendingInvites.isEmpty { dismiss() }
                } label: {
                    Text("JOIN")
                        .walkieLabel(11, weight: .heavy, tracking: 2)
                        .foregroundStyle(DT.bg)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(DT.ok)
                }
                .buttonStyle(.plain)
                Button {
                    session.declineInvite(invite)
                    if session.pendingInvites.isEmpty { dismiss() }
                } label: {
                    Text("DECLINE")
                        .walkieLabel(11, weight: .heavy, tracking: 2)
                        .foregroundStyle(DT.tx)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .overlay(Rectangle().strokeBorder(DT.tx.opacity(0.6), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 2)
    }
}
