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
            FailureNote(message: message, retry: retry)
        case .loaded(let value):
            content(value)
        }
    }
}

/// Says something did not load, with a way to ask again. Sits inside the
/// block that failed.
struct FailureNote: View {
    let message: String
    var retry: (() async -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(Theme.small)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let retry {
                Button("Try again") {
                    Task { await retry() }
                }
                .font(Theme.smallStrong)
                .foregroundStyle(Theme.text)
                .frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A short line that something went wrong, or needs care, with an icon in
/// front. Red is for what failed. Amber is for a caution that is not an error.
struct Notice: View {
    enum Kind {
        case error, warning

        var color: Color { self == .error ? Theme.negative : Theme.warning }
        var symbol: String { self == .error ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill" }
    }

    let text: String
    var kind = Kind.error
    /// Replaces the kind's own icon.
    var symbol: String?
    var retry: (() async -> Void)?

    init(_ text: String, kind: Kind = .error, symbol: String? = nil, retry: (() async -> Void)? = nil) {
        self.text = text
        self.kind = kind
        self.symbol = symbol
        self.retry = retry
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(text, systemImage: symbol ?? kind.symbol)
                .font(Theme.small)
                .foregroundStyle(kind.color)
                .fixedSize(horizontal: false, vertical: true)
            if let retry {
                Button("Try again") {
                    Task { await retry() }
                }
                .font(Theme.smallStrong)
                .foregroundStyle(Theme.text)
                .frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
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
        .cardSurface()
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

/// A small round avatar with one letter, in the pale tint of whatever it
/// stands for, as Sure draws categories and merchants.
struct LetterTile: View {
    let name: String
    let tint: Tint
    var round = true

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
    /// Where the line starts, so it lines up with the text of the rows.
    enum Inset: CGFloat {
        /// Full width, for rows in a padded card.
        case none = 0
        /// Rows whose text starts at the edge padding.
        case text = 16
        /// Rows that lead with a 40pt tile or icon.
        case tile = 68
    }

    var inset = Inset.none

    var body: some View {
        Rectangle()
            .fill(Theme.rule)
            .frame(height: 1)
            .padding(.leading, inset.rawValue)
    }
}

/// A chevron at the end of a row that opens another screen.
struct DisclosureChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(Theme.glyphSmall)
            .foregroundStyle(Theme.muted)
            .accessibilityHidden(true)
    }
}

/// A row in a list of choices where one is picked: a title, a line under it,
/// and a round mark that fills in when chosen.
struct ChoiceRow: View {
    let title: String
    var detail: String?
    let isOn: Bool
    /// Space around the row's content.
    var padding: EdgeInsets = EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0)
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.body)
                        .foregroundStyle(Theme.text)
                    if let detail {
                        Text(detail)
                            .font(Theme.small)
                            .foregroundStyle(Theme.muted)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(Theme.glyphLarge)
                    .foregroundStyle(isOn ? Theme.text : Theme.control)
                    .accessibilityHidden(true)
            }
            .padding(padding)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
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

/// A round button holding one icon: white, or near-black when it is the
/// screen's main action, such as Send.
struct IconButtonStyle: ButtonStyle {
    var isProminent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(Theme.glyph)
            .foregroundStyle(isProminent ? Theme.onPrimary : Theme.text)
            .frame(width: 44, height: 44)
            .background(isProminent ? Theme.primary : Theme.surface, in: .circle)
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
    }
}

/// A button that is only its words: for Cancel, and for actions that sit
/// quietly under a card. Red when it removes or stops something.
struct TextButtonStyle: ButtonStyle {
    var isDestructive = false
    var fullWidth = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.bodyStrong)
            .foregroundStyle(isDestructive ? Theme.negative : Theme.text)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 48, alignment: fullWidth ? .center : .leading)
            .contentShape(.rect)
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
    }
}

/// A small grey pill for an action inside a row, such as Track.
struct PillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.smallStrong)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(Theme.raised, in: .capsule)
            .frame(minHeight: 44)
            .contentShape(.rect)
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
    }
}

/// Dims a row while it is pressed.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.raised : Color.clear)
    }
}

/// The main button of a step that takes a moment. It stays solid while
/// idle, and shows a spinner and a new label while the work runs.
struct WorkingButton: View {
    let title: String
    let workingTitle: String
    let isWorking: Bool
    var isDestructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isWorking {
                    ProgressView().tint(isDestructive ? Color.white : Theme.onPrimary)
                }
                Text(isWorking ? workingTitle : title)
            }
        }
        .buttonStyle(PrimaryButtonStyle(fullWidth: true, isDestructive: isDestructive))
        .allowsHitTesting(!isWorking)
    }
}

/// The label of a menu that picks a value: a pill with the current choice
/// and a chevron. Dark while it narrows what is shown. Use `onCard` when it
/// sits on a white card, where it takes the grey fill instead.
struct MenuChip: View {
    let text: String
    var isActive = false
    var onCard = false
    var symbol = "chevron.down"

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(Theme.smallStrong)
                .lineLimit(1)
            Image(systemName: symbol)
                .font(Theme.glyphSmall)
        }
        .foregroundStyle(isActive ? Theme.onPrimary : Theme.text)
        .padding(.horizontal, 14)
        .frame(minHeight: 36)
        .background(isActive ? Theme.primary : (onCard ? Theme.raised : Theme.surface), in: .capsule)
        .frame(minHeight: 44)
        .contentShape(.rect)
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

/// The frame every small sheet in the app shares: a title, a line under it,
/// optional content, then its buttons. Sized to fit, on the page background.
struct SheetFrame<Content: View, Actions: View>: View {
    let title: String
    var message: String?
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    @State private var height: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(Theme.section)
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let message, !message.isEmpty {
                    Text(message)
                        .font(Theme.body)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
            VStack(spacing: 4) {
                actions
            }
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

/// Asks before something that is hard to take back: a title, a line on what
/// happens, optional choices, then the action and Cancel. Used everywhere
/// instead of the system's confirmation dialog.
struct ConfirmSheet<Options: View>: View {
    let title: String
    var message: String?
    let confirmTitle: String
    var isDestructive = true
    let confirm: () -> Void
    @ViewBuilder var options: Options

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetFrame(title: title, message: message) {
            options
        } actions: {
            Button(confirmTitle) {
                dismiss()
                confirm()
            }
            .buttonStyle(PrimaryButtonStyle(fullWidth: true, isDestructive: isDestructive))
            .animation(.snappy(duration: 0.2), value: isDestructive)
            Button("Cancel") { dismiss() }
                .buttonStyle(TextButtonStyle(fullWidth: true))
        }
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

/// Tells the person something they need to read, such as why an action did
/// not go through, with one button to close it. Used instead of system alerts.
struct MessageSheet: View {
    let title: String
    let message: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetFrame(title: title, message: message) {
            EmptyView()
        } actions: {
            Button("OK") { dismiss() }
                .buttonStyle(PrimaryButtonStyle(fullWidth: true))
        }
    }
}

/// A message held while its sheet is up, so the text stays put as it closes.
private struct ShownMessage: Identifiable {
    let text: String
    var id: String { text }
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

    /// Shows a `MessageSheet` while `isPresented` is true.
    func messageSheet(_ title: String, isPresented: Binding<Bool>, message: String) -> some View {
        sheet(isPresented: isPresented) {
            MessageSheet(title: title, message: message)
        }
    }

    /// Shows why something failed in a `MessageSheet`, while `error` holds
    /// text. Closing it clears the error.
    func errorSheet(_ error: Binding<String?>, title: String = "That did not work") -> some View {
        sheet(item: Binding(
            get: { error.wrappedValue.flatMap { $0.isEmpty ? nil : ShownMessage(text: $0) } },
            set: { if $0 == nil { error.wrappedValue = nil } }
        )) { shown in
            MessageSheet(title: title, message: shown.text)
        }
    }

    /// A white panel with Sure's hairline edge, holding rows edge to edge, with the card corner radius.
    func rowGroup() -> some View {
        background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
            .clipShape(.rect(cornerRadius: Theme.cardRadius))
            .sureCardEdge()
    }

    /// The padded white panel of a card, for content that is not a `Card`,
    /// such as a whole card that is one link.
    func cardSurface() -> some View {
        padding(Theme.cardPadding)
            .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
            .sureCardEdge()
    }

    /// The page background and default type for a screen.
    func screenBackground() -> some View {
        background(Theme.ground.ignoresSafeArea())
    }
}
