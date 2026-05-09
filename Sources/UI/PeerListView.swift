import SwiftUI

/// Monospace list of discovered peers. Each row renders as a dot-leader
/// readout: `> NAME........ [WIFI] RDY  ▪▪▪▪▫`. Tapping selects a peer.
///
/// The transport pill (`WIFI` / `NEAR`) appears on every row so users know
/// which link they'd be talking over — meaningful once RangeMode can
/// surface peers from both paths simultaneously.
struct PeerListView: View {
    @ObservedObject var directory: PeerDirectory
    @Binding var selectedPeer: PeerInfo?

    var body: some View {
        Group {
            if directory.peers.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    ForEach(directory.peers) { peer in
                        PeerRow(peer: peer,
                                isSelected: peer == selectedPeer,
                                onTap: { selectedPeer = peer })
                        if peer.id != directory.peers.last?.id {
                            Rectangle()
                                .fill(DT.border)
                                .frame(height: 1)
                                .opacity(0.4)
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                PulsingDot(color: directory.isBrowsing ? DT.info : DT.textDim)
                Text(directory.isBrowsing ? "SCANNING" : "OFFLINE")
                    .walkieLabel(11)
                    .foregroundStyle(DT.textDim)
            }
            Text(directory.isBrowsing
                 ? "NO PEERS IN RANGE · WIFI + NEARBY"
                 : "TAP START TO BEGIN DISCOVERY")
                .walkieCaption()
                .foregroundStyle(DT.textFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}

private struct PeerRow: View {
    let peer: PeerInfo
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(isSelected ? ">" : " ")
                .font(DT.mono(13, weight: .bold))
                .foregroundStyle(isSelected ? DT.tx : DT.textFaint)

            Text(peer.name.uppercased())
                .font(DT.mono(13, weight: .semibold))
                .foregroundStyle(isSelected ? DT.text : DT.text.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)

            GeometryReader { geo in
                Text(String(repeating: ".", count: max(6, Int(geo.size.width / 4))))
                    .font(DT.mono(13))
                    .foregroundStyle(DT.textFaint)
                    .lineLimit(1)
                    .offset(y: 2)
            }
            .frame(height: 14)

            transportPill

            Text("RDY")
                .font(DT.mono(11, weight: .bold))
                .tracking(1)
                .foregroundStyle(DT.ok)

            signalMeter
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 10)
        .background(isSelected ? DT.tx.opacity(0.09) : Color.clear)
        .contentShape(.rect)
        .onTapGesture(perform: onTap)
    }

    /// Compact transport tag (WIFI / NEAR). Color-coded for scannability —
    /// nearby has a warmer tint since it's the "walked up to them" mode.
    private var transportPill: some View {
        let tint: Color = peer.transport == .wifi ? DT.info : DT.warn
        return Text(peer.transport.tag)
            .font(DT.mono(10, weight: .bold))
            .tracking(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .overlay(
                Rectangle().strokeBorder(tint.opacity(0.5), lineWidth: 1)
            )
    }

    /// 5-cell signal meter. We don't measure real signal yet — peers we
    /// can see are considered fully "in range" so we show 5/5 by default.
    /// Will be driven by real ping RTT in a future milestone.
    private var signalMeter: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                Rectangle()
                    .fill(i < 5 ? DT.ok : DT.textFaint)
                    .frame(width: 4, height: CGFloat(4 + i * 2))
            }
        }
        .frame(height: 14)
    }
}

/// Small square that softly pulses — used to signal "something is happening"
/// (browsing, listening) without animating a full progress view.
struct PulsingDot: View {
    var color: Color
    @State private var opacity: Double = 0.4

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    opacity = 1.0
                }
            }
    }
}
