import SwiftUI

/// The first thing a new person sees: what the app is, and two ways in.
/// Connecting a server leads on to sign-in; the sample opens the real app
/// on a made-up household.
struct OnboardingView: View {
    private enum Step: Hashable { case signIn }

    @Environment(Session.self) private var session
    @State private var path: [Step] = []

    var body: some View {
        NavigationStack(path: $path) {
            WelcomeView(
                connect: { path = [.signIn] },
                lookAround: { session.startSample() }
            )
            .navigationDestination(for: Step.self) { _ in
                SignInView()
            }
        }
        .onAppear {
            // Back from the sample, or signed out by the server: go straight
            // to the form rather than the pitch.
            if session.opensSignIn || session.notice != nil {
                session.opensSignIn = false
                path = [.signIn]
            }
        }
    }
}

struct WelcomeView: View {
    let connect: () -> Void
    let lookAround: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    static let sureProject = URL(string: "https://github.com/we-promise/sure")!

    /// The pitch, with "Sure" linking to the project for anyone new to it.
    private static var pitch: AttributedString {
        var text = AttributedString("An iPhone app for ")
        var sure = AttributedString("Sure")
        sure.link = sureProject
        sure.underlineStyle = .single
        sure.foregroundColor = Theme.text
        text += sure
        text += AttributedString(", the open source finance app you host yourself. Your money stays on your server.")
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                ProductMark(size: 44)
                Text("Your money,\nin your pocket.")
                    .font(Theme.font(34, .bold, relativeTo: .largeTitle))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.pitch)
                    .font(Theme.body)
                    .foregroundStyle(Theme.muted)
                    .tint(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 48)
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 12)

            Spacer(minLength: 24)

            WelcomePreview(shown: shown)
                .accessibilityHidden(true)

            Spacer(minLength: 24)

            VStack(spacing: 6) {
                Button("Connect my server", action: connect)
                    .buttonStyle(PrimaryButtonStyle(fullWidth: true))
                Button(action: lookAround) {
                    Text("Look around with sample data")
                        .font(Theme.bodyStrong)
                        .foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                Link(destination: Self.sureProject) {
                    HStack(spacing: 4) {
                        Text("New to Sure? See the project")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .font(Theme.smallStrong)
                    .foregroundStyle(Theme.muted)
                    .frame(minHeight: 32)
                }
                Text("An unofficial app, not affiliated with the Sure project.")
                    .font(Theme.small)
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
            }
            .opacity(shown ? 1 : 0)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .screenBackground()
        .toolbarVisibility(.hidden, for: .navigationBar)
        .onAppear {
            guard !shown else { return }
            withAnimation(reduceMotion ? .none : .smooth(duration: 0.7)) { shown = true }
        }
    }
}

/// Two cards from the app itself, a net worth that rises and this month's
/// bills, so the welcome shows the product instead of describing it.
private struct WelcomePreview: View {
    let shown: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var worth: Double = 0

    private let heights: [CGFloat] = [0.38, 0.46, 0.42, 0.55, 0.52, 0.64, 0.7, 0.68, 0.82, 1]
    private let target = 84_210.0

    var body: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Net worth")
                    .font(Theme.small)
                    .foregroundStyle(Theme.muted)
                Text(worth, format: .currency(code: "USD").precision(.fractionLength(0)))
                    .font(Theme.font(32, .semibold, relativeTo: .largeTitle))
                    .foregroundStyle(Theme.text)
                    .contentTransition(.numericText(value: worth))
                    .monospacedDigit()
                HStack(alignment: .bottom, spacing: 5) {
                    ForEach(heights.indices, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(index == heights.count - 1 ? Theme.accent : Theme.accent.opacity(0.22))
                            .frame(height: shown ? 56 * heights[index] : 4)
                            .animation(
                                reduceMotion ? nil : .spring(duration: 0.6, bounce: 0.25).delay(0.25 + Double(index) * 0.05),
                                value: shown
                            )
                    }
                }
                .frame(height: 56, alignment: .bottom)
            }
            .padding(Theme.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Still to pay")
                        .font(Theme.small)
                        .foregroundStyle(Theme.muted)
                    Text("$214")
                        .font(Theme.font(22, .semibold, relativeTo: .title2))
                        .foregroundStyle(Theme.text)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text("7 of 11 bills paid")
                        .font(Theme.small)
                        .foregroundStyle(Theme.muted)
                    Capsule()
                        .fill(Theme.track)
                        .frame(width: 110, height: 6)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(Theme.positive)
                                .frame(width: shown ? 70 : 0, height: 6)
                                .animation(reduceMotion ? nil : .smooth(duration: 0.8).delay(0.7), value: shown)
                        }
                }
            }
            .padding(Theme.cardPadding)
            .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 16)
            .animation(reduceMotion ? nil : .smooth(duration: 0.6).delay(0.45), value: shown)
        }
        .onChange(of: shown, initial: true) {
            guard shown else { return }
            if reduceMotion {
                worth = target
            } else {
                withAnimation(.smooth(duration: 1.1).delay(0.2)) { worth = target }
            }
        }
    }
}

/// Shown under the tab bar while the sample household is open, with the
/// way out to a real server.
struct SampleAccessory: ViewModifier {
    let isSample: Bool

    func body(content: Content) -> some View {
        if isSample {
            content.tabViewBottomAccessory { SampleBar() }
        } else {
            content
        }
    }
}

private struct SampleBar: View {
    @Environment(Session.self) private var session

    var body: some View {
        Button {
            session.opensSignIn = true
            session.signOut()
        } label: {
            HStack(spacing: 8) {
                Text("Sample data")
                    .font(Theme.smallStrong)
                    .foregroundStyle(Theme.text)
                Text("Connect your server")
                    .font(Theme.small)
                    .foregroundStyle(Theme.muted)
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sample data. Connect your server")
    }
}
