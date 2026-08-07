import SwiftUI

/// First-launch walkthrough explaining the app's core vocabulary —
/// LINK / PAIR / PEER, TALK / CHAT / LISTEN, channels & settings.
///
/// Shown automatically once (driven by `ContentView.hasSeenOnboarding`)
/// and reopenable anytime via the `?` button in the brand strip. Owns no
/// presentation state itself — `onFinish` is called by both SKIP and the
/// final GET STARTED tap, and the parent decides what that means.
struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var step = 0

    private let steps: [OnboardingStep] = [
        OnboardingStep(
            icon: "shield.lefthalf.filled",
            accent: DT.ok,
            title: "NO SERVERS.\nNO ACCOUNTS.",
            body: "Klick connects your phone directly to another phone over WiFi or Bluetooth and encrypts every packet end-to-end. There's nothing to sign up for and nothing to sign in to."
        ),
        OnboardingStep(
            icon: "antenna.radiowaves.left.and.right",
            accent: DT.info,
            title: "LINK\nGOES LIVE",
            body: "Tap the LINK tile to switch on your radios. That's what makes you discoverable to nearby Klick devices — tap it again anytime to stop."
        ),
        OnboardingStep(
            icon: "lock.shield.fill",
            accent: DT.warn,
            title: "PAIR\nEXCHANGES A KEY",
            body: "Tap PAIR and show or scan a QR code with one other device. That one-time exchange sets up the encryption key you'll both use."
        ),
        OnboardingStep(
            icon: "iphone.gen3.radiowaves.left.and.right",
            accent: DT.sys,
            title: "PEER\nPICKS WHO YOU REACH",
            body: "Once you're live, PEER lists everyone nearby. Select one, several, or everyone — that's who your next transmission or message goes to."
        ),
        OnboardingStep(
            icon: "dot.radiowaves.left.and.right",
            accent: DT.navTalk,
            title: "TALK · CHAT · LISTEN",
            body: "Hold the button at the bottom to transmit voice. Switch to CHAT to type instead, or LISTEN to decode Morse from a camera or a mic."
        ),
        OnboardingStep(
            icon: "slider.horizontal.3",
            accent: DT.navSettings,
            title: "CHANNELS &\nSETTINGS",
            body: "Create a channel to group a crew under one key instead of re-picking peers each time. Settings holds region, discoverability, and mesh-relay options. Tap ? up top anytime to see this again."
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
                    .padding(.bottom, 20)

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
        VStack(spacing: 28) {
            Spacer(minLength: 0)

            ZStack {
                Rectangle()
                    .fill(item.accent.opacity(0.15))
                    .overlay(Rectangle().strokeBorder(item.accent, lineWidth: 1))
                    .frame(width: 88, height: 88)
                Image(systemName: item.icon)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(item.accent)
            }

            VStack(spacing: 14) {
                Text(item.title)
                    .walkieLabel(22, weight: .heavy, tracking: 2)
                    .foregroundStyle(DT.text)
                    .multilineTextAlignment(.center)

                TerminalFrame(accent: DT.border) {
                    Text(item.body)
                        .font(DT.mono(13, weight: .regular))
                        .foregroundStyle(DT.textDim)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 28)

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

private struct OnboardingStep {
    let icon: String
    let accent: Color
    let title: String
    let body: String
}

#Preview {
    OnboardingView(onFinish: {})
}
