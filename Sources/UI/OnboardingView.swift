import SwiftUI

/// First-launch walkthrough — points at the real TALK screen instead of
/// describing it. Each step dims a real screenshot (`OnboardingTalkScreen`
/// in Assets.xcassets, the same capture used on the marketing site) except
/// for a spotlighted region, so the user sees exactly what LINK/PAIR/PEER/
/// TRANSMIT/SETTINGS look like before they ever open those screens.
///
/// Shown automatically once (driven by `ContentView.hasSeenOnboarding`)
/// and reopenable anytime via the `?` button in the brand strip. Owns no
/// presentation state itself — `onFinish` is called by both SKIP and the
/// final GET STARTED tap, and the parent decides what that means.
struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var step = 0

    /// Unit-space (0...1) boxes measured off `OnboardingTalkScreen`, so
    /// they scale to whatever size the screenshot is rendered at.
    private let steps: [OnboardingStep] = [
        OnboardingStep(
            title: "NO SERVERS.\nNO ACCOUNTS.",
            caption: "Every packet is encrypted phone-to-phone — nothing to sign up for.",
            accent: DT.ok,
            highlight: nil
        ),
        OnboardingStep(
            title: "LINK GOES LIVE",
            caption: "Tap LINK to switch on WiFi + Bluetooth so nearby phones can find you.",
            accent: DT.info,
            highlight: UnitRect(x: 0.041, y: 0.169, width: 0.287, height: 0.121)
        ),
        OnboardingStep(
            title: "PAIR EXCHANGES A KEY",
            caption: "Tap PAIR and scan a QR code to set up encryption with one device.",
            accent: DT.warn,
            highlight: UnitRect(x: 0.354, y: 0.169, width: 0.289, height: 0.121)
        ),
        OnboardingStep(
            title: "PEER PICKS WHO YOU REACH",
            caption: "Tap PEER to select who your next transmission goes to.",
            accent: DT.sys,
            highlight: UnitRect(x: 0.670, y: 0.169, width: 0.289, height: 0.121)
        ),
        OnboardingStep(
            title: "HOLD TO TALK",
            caption: "Or switch to CHAT to type, or LISTEN to decode Morse.",
            accent: DT.tx,
            highlight: UnitRect(x: 0.041, y: 0.7725, width: 0.917, height: 0.1425)
        ),
        OnboardingStep(
            title: "CHANNELS & SETTINGS",
            caption: "Group peers into a channel; tune region + relay in SETTINGS.",
            accent: DT.navSettings,
            highlight: UnitRect(x: 0.741, y: 0.121, width: 0.233, height: 0.029)
        ),
    ]

    var body: some View {
        ZStack {
            DT.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                TabView(selection: $step) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, item in
                        stepContent(item)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                pageIndicator
                    .padding(.bottom, 18)

                actionButton
                    .padding(.horizontal, 24)
                    .padding(.bottom, 28)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("HOW KLICK WORKS")
                .walkieLabel(11)
                .foregroundStyle(DT.textDim)
            Spacer()
            Button("SKIP") { onFinish() }
                .font(DT.mono(11, weight: .bold))
                .tracking(DT.labelTracking)
                .foregroundStyle(DT.textDim)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    // MARK: - Step content

    private func stepContent(_ item: OnboardingStep) -> some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)

            SpotlightScreenshot(highlight: item.highlight, accent: item.accent)
                .frame(width: 212, height: 212 * 2622.0 / 1206.0)

            VStack(spacing: 8) {
                Text(item.title)
                    .walkieLabel(16, weight: .heavy, tracking: 1.6)
                    .foregroundStyle(item.accent)
                    .multilineTextAlignment(.center)

                Text(item.caption)
                    .font(DT.mono(12.5, weight: .regular))
                    .foregroundStyle(DT.textDim)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 30)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Page indicator (pixel-square, matches the terminal idiom
    // instead of the default TabView dots)

    private var pageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(steps.indices, id: \.self) { index in
                Rectangle()
                    .fill(index == step ? DT.text : DT.textFaint)
                    .frame(width: index == step ? 16 : 6, height: 6)
            }
        }
        .animation(.easeOut(duration: 0.2), value: step)
    }

    // MARK: - Action button

    private var isLastStep: Bool { step == steps.count - 1 }

    private var actionButton: some View {
        Button(action: advance) {
            Text(isLastStep ? "GET STARTED" : "NEXT")
                .walkieLabel(13, weight: .heavy, tracking: 2)
                .foregroundStyle(DT.bg)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(isLastStep ? DT.ok : DT.info)
        }
        .buttonStyle(.plain)
    }

    private func advance() {
        if isLastStep {
            onFinish()
        } else {
            withAnimation { step += 1 }
        }
    }
}

/// A real screenshot with everything but `highlight` dimmed out — the
/// "point at it" idiom, using an even-odd path to punch a clear window
/// through a black scrim rather than four separately-positioned strips.
private struct SpotlightScreenshot: View {
    let highlight: UnitRect?
    let accent: Color

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Image("OnboardingTalkScreen")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width, height: size.height)

                if let highlight {
                    let rect = CGRect(
                        x: highlight.x * size.width,
                        y: highlight.y * size.height,
                        width: highlight.width * size.width,
                        height: highlight.height * size.height
                    ).insetBy(dx: -5, dy: -5)

                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: size))
                        path.addRect(rect)
                    }
                    .fill(Color.black.opacity(0.68), style: FillStyle(eoFill: true))

                    Rectangle()
                        .fill(accent.opacity(0.15))
                        .overlay(Rectangle().strokeBorder(accent, lineWidth: 2))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: DT.tileCorner).strokeBorder(DT.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: DT.tileCorner))
    }
}

private struct UnitRect {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
}

private struct OnboardingStep {
    let title: String
    let caption: String
    let accent: Color
    let highlight: UnitRect?
}

#Preview {
    OnboardingView(onFinish: {})
}
