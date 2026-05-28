import WidgetKit
import SwiftUI
import ActivityKit

/// Live Activity widget displaying PTT state on the lock screen and Dynamic Island.
struct KlickLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: KlickActivityAttributes.self) { context in
            // LOCK SCREEN / STANDBY EXPANDED VIEW
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // EXPANDED VIEW
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 4) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 12, weight: .bold))
                        Text(context.state.channelName)
                            .font(.system(size: 13, weight: .heavy, design: .monospaced))
                    }
                    .foregroundStyle(context.state.isTransmitting ? .red : .green)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.isTransmitting ? "TX" : "LIVE")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(context.state.isTransmitting ? .red : .green)
                }
                DynamicIslandExpandedRegion(.center) {
                    Button(intent: TogglePTTIntent()) {
                        HStack(spacing: 6) {
                            Image(systemName: context.state.isTransmitting ? "stop.fill" : "mic.fill")
                            Text(context.state.isTransmitting ? "STOP" : "TALK")
                                .font(.system(size: 14, weight: .heavy, design: .monospaced))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(context.state.isTransmitting ? Color.red : Color.green)
                        )
                    }
                    .buttonStyle(.plain)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.state.peerNames)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(context.state.onlinePeerCount) ONLINE")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                // COMPACT — left pill
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(context.state.isTransmitting ? .red : .green)
            } compactTrailing: {
                // COMPACT — right pill
                Text(context.state.isTransmitting ? "TX" : context.state.channelName)
                    .font(.system(size: 12, weight: .heavy, design: .monospaced))
                    .foregroundStyle(context.state.isTransmitting ? .red : .green)
            } minimal: {
                // MINIMAL — single icon
                Image(systemName: context.state.isTransmitting
                      ? "mic.fill"
                      : "antenna.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(context.state.isTransmitting ? .red : .green)
            }
        }
    }

    // MARK: - Lock Screen View

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<KlickActivityAttributes>) -> some View {
        VStack(spacing: 10) {
            // Header row
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 12, weight: .bold))
                    Text("KLICK · \(context.state.channelName)")
                        .font(.system(size: 13, weight: .heavy, design: .monospaced))
                }
                Spacer()
                HStack(spacing: 4) {
                    Circle()
                        .fill(context.state.isRunning ? Color.green : Color.gray)
                        .frame(width: 6, height: 6)
                    Text(context.state.isTransmitting ? "TX" : (context.state.isRunning ? "LIVE" : "IDLE"))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                }
            }
            .foregroundStyle(context.state.isTransmitting ? .red : .primary)

            // PTT Toggle Button
            Button(intent: TogglePTTIntent()) {
                HStack(spacing: 8) {
                    Image(systemName: context.state.isTransmitting ? "stop.fill" : "mic.fill")
                        .font(.system(size: 16, weight: .bold))
                    Text(context.state.isTransmitting ? "STOP" : "TALK")
                        .font(.system(size: 15, weight: .heavy, design: .monospaced))
                        .tracking(2)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(context.state.isTransmitting ? Color.red : Color.green)
                )
            }
            .buttonStyle(.plain)

            // Footer — peers
            HStack {
                Text(context.state.peerNames)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(context.state.onlinePeerCount) ONLINE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.black)
    }
}
