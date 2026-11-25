import SwiftUI

/// Shows a placeholder while loading, an error with a retry inside the block
/// that failed, or the loaded content.
struct LoadableView<Value, Content: View>: View {
    let state: Loadable<Value>
    /// How many placeholder lines to draw while loading.
    var placeholderLines = 3
    let retry: () async -> Void
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        switch state {
        case .loading:
            LoadingLines(count: placeholderLines)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(Theme.small)
                    .foregroundStyle(Theme.muted)
                Button("Try again") {
                    Task { await retry() }
                }
                .font(Theme.smallStrong)
                .foregroundStyle(Theme.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .loaded(let value):
            content(value)
        }
    }
}

/// Flat grey bars standing in for content that is on its way.
struct LoadingLines: View {
    var count = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.raised)
                    .frame(maxWidth: index == 0 ? 180 : .infinity)
                    .frame(height: index == 0 ? 28 : 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Loading")
    }
}

/// A flat white panel with the app's one large radius.
struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let title {
                Text(title)
                    .font(Theme.section)
                    .foregroundStyle(Theme.text)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.cardPadding)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
    }
}

/// The top of a main screen: the title, and one action on the right.
struct ScreenHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(Theme.title)
                .foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            trailing
        }
        .frame(minHeight: 44)
    }
}

extension ScreenHeader where Trailing == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// A small tile with one letter, in the pale tint of whatever it stands for.
struct LetterTile: View {
    let name: String
    let tint: Tint
    var round = false

    var body: some View {
        Text(name.trimmingCharacters(in: .whitespaces).prefix(1).uppercased())
            .font(Theme.bodyStrong)
            .foregroundStyle(tint.ink)
            .frame(width: 40, height: 40)
            .background(tint.background, in: .rect(cornerRadius: round ? 20 : Theme.tileRadius))
            .accessibilityHidden(true)
    }
}

/// Money with the cents set smaller and grey, so the whole units lead.
struct MoneyText: View {
    let amount: String
    var font: Font = Theme.figure
    var centsFont: Font = Theme.font(20, .semibold, relativeTo: .title3)
    var color: Color = Theme.text

    /// Splits "$14,824.57" into "$14,824" and ".57". Amounts without two
    /// trailing decimals come back whole.
    static func split(_ amount: String) -> (whole: String, cents: String) {
        let characters = Array(amount)
        guard characters.count > 3 else { return (amount, "") }
        let separator = characters[characters.count - 3]
        let decimals = characters.suffix(2)
        guard separator == "." || separator == ",", decimals.allSatisfy(\.isNumber) else {
            return (amount, "")
        }
        return (String(characters.dropLast(3)), String(characters.suffix(3)))
    }

    var body: some View {
        let parts = Self.split(amount)
        Text("\(Text(parts.whole).font(font).foregroundStyle(color))\(Text(parts.cents).font(centsFont).foregroundStyle(Theme.muted))")
            .tracking(-0.5)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .accessibilityLabel(amount)
    }
}

/// A name and its amount: side by side, or the amount under the name once
/// the text is set very large, where the two no longer fit on one line.
/// Either way the amount stays on one line and is never broken mid-number.
struct NameAmount<Name: View, Amount: View>: View {
    var alignment: VerticalAlignment = .center
    @ViewBuilder let name: Name
    @ViewBuilder let amount: Amount
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        if textSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                name
                amount
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: alignment, spacing: 8) {
                name
                Spacer(minLength: 0)
                amount
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(1)
            }
        }
    }
}

/// A label on the left and a figure on the right.
struct FigureRow: View {
    let label: String
    let value: String
    var valueColor: Color = Theme.text

    var body: some View {
        NameAmount {
            Text(label)
                .font(Theme.body)
                .foregroundStyle(Theme.muted)
        } amount: {
            Text(value)
                .font(Theme.bodyStrong)
                .monospacedDigit()
                .foregroundStyle(valueColor)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A hairline between rows inside a card.
struct RowRule: View {
    var body: some View {
        Rectangle()
            .fill(Theme.rule)
            .frame(height: 1)
    }
}

/// How far something has gone against a reference amount.
///
/// The bar is as long as the larger of the two. The part up to the reference
/// is blue and anything past it is red, with a tick where the reference sits.
/// With no reference the bar is a plain share of `scale`.
struct PaceBar: View {
    let value: Double
    /// The budget, or the normal amount. Nil or zero means there is none.
    let reference: Double?
    /// What a full bar stands for when there is no reference.
    var scale: Double = 0

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let reference = reference.flatMap { $0 > 0 ? $0 : nil }
            let full = max(reference ?? scale, value, 0.01)
            let within = min(value, reference ?? value)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                if value > 0 {
                    Capsule()
                        .fill(Theme.negative)
                        .frame(width: max(width * value / full, 6))
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: max(width * within / full, 6))
                }
                if let reference, value > reference {
                    Rectangle()
                        .fill(Theme.surface)
                        .frame(width: 2)
                        .offset(x: width * reference / full - 1)
                }
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

/// The main action of a screen: a near-black pill, or red when the action
/// deletes or removes something.
struct PrimaryButtonStyle: ButtonStyle {
    var fullWidth = false
    var isDestructive = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.bodyStrong)
            .foregroundStyle(isDestructive ? Color.white : Theme.onPrimary)
            .padding(.horizontal, 18)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: fullWidth ? 52 : 44)
            .background(
                isDestructive ? Theme.negative : Theme.primary,
                in: .rect(cornerRadius: fullWidth ? Theme.controlRadius : 22)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// A round grey button holding one icon.
struct IconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(Theme.text)
            .frame(width: 44, height: 44)
            .background(Theme.surface, in: .circle)
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
    }
}

/// A message shown inside a block that has nothing to list.
struct EmptyNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.small)
            .foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Asks before something that is hard to take back: a title, a line on what
/// happens, optional choices, then the action and Cancel. The app's own sheet,
/// sized to fit, used instead of the system's confirmation dialog.
struct ConfirmSheet<Options: View>: View {
    let title: String
    var message: String?
    let confirmTitle: String
    var isDestructive = true
    let confirm: () -> Void
    @ViewBuilder var options: Options

    @Environment(\.dismiss) private var dismiss
    @State private var height: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(Theme.section)
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let message {
                    Text(message)
                        .font(Theme.body)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            options

            VStack(spacing: 4) {
                Button(confirmTitle) {
                    dismiss()
                    confirm()
                }
                .buttonStyle(PrimaryButtonStyle(fullWidth: true, isDestructive: isDestructive))
                Button("Cancel") { dismiss() }
                    .font(Theme.bodyStrong)
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .animation(.snappy(duration: 0.2), value: isDestructive)
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 8)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .presentationDetents([.height(height)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.ground)
        .presentationCornerRadius(32)
    }
}

extension ConfirmSheet where Options == EmptyView {
    init(
        title: String,
        message: String? = nil,
        confirmTitle: String,
        isDestructive: Bool = true,
        confirm: @escaping () -> Void
    ) {
        self.init(
            title: title,
            message: message,
            confirmTitle: confirmTitle,
            isDestructive: isDestructive,
            confirm: confirm
        ) { EmptyView() }
    }
}

extension View {
    /// Shows a `ConfirmSheet` while `isPresented` is true.
    func confirmSheet(
        _ title: String,
        isPresented: Binding<Bool>,
        message: String? = nil,
        confirmTitle: String,
        isDestructive: Bool = true,
        confirm: @escaping () -> Void
    ) -> some View {
        sheet(isPresented: isPresented) {
            ConfirmSheet(
                title: title,
                message: message,
                confirmTitle: confirmTitle,
                isDestructive: isDestructive,
                confirm: confirm
            )
        }
    }

    /// The page background and default type for a screen.
    func screenBackground() -> some View {
        background(Theme.ground.ignoresSafeArea())
    }
}
