import SwiftUI

// Layout for wide screens: iPhone Duo's inner display, and any window wider
// than a phone. On a phone none of this changes anything: the screen is
// narrower than every limit here, so columns stay single and full width.
//
// Layout decisions read the space the view is given, never the device, its
// orientation or `UIScreen`, because on iPhone Duo the same scene moves
// between the outer and inner displays as it folds and unfolds.

extension Theme {
    /// Widest a single column of cards gets. Past this, lines of figures get
    /// too long to read, so the column stays centred with ground either side.
    static let columnWidth: CGFloat = 720
    /// Widest a screen that splits into two columns gets.
    static let wideColumnWidth: CGFloat = 1200
    /// Widest the sign-in and setup forms get.
    static let formWidth: CGFloat = 520
    /// Width from which `WideColumns` sets its two groups side by side. Each
    /// column then gets at least as much room as a large phone.
    static let twoColumnMinimum: CGFloat = 700
}

extension View {
    /// The horizontal frame of a screen's content: the usual margin, capped
    /// at a readable width and centred when the screen is wider than that.
    func screenColumn(margin: CGFloat = Theme.margin, maxWidth: CGFloat = Theme.columnWidth) -> some View {
        padding(.horizontal, margin)
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }
}

/// Two groups of cards, side by side when there is room for both and one
/// above the other when there is not.
///
/// Both arrangements keep the same views, so unfolding or folding iPhone Duo
/// moves the cards without reloading them or losing their state.
struct WideColumns<Leading: View, Trailing: View>: View {
    var spacing: CGFloat = Theme.gap
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @State private var isWide = false

    var body: some View {
        let layout = isWide
            ? AnyLayout(HStackLayout(alignment: .top, spacing: spacing))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
        layout {
            VStack(alignment: .leading, spacing: spacing) { leading }
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: spacing) { trailing }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.size.width >= Theme.twoColumnMinimum
        } action: { wide in
            isWide = wide
        }
    }
}

/// A list with its details beside it when the screen is wide, as on iPhone
/// Duo's inner display, and a plain stack that pushes the details on a phone.
///
/// Links in the list open in the detail column when it is showing.
struct ListDetailStack<Sidebar: View, Placeholder: View>: View {
    @ViewBuilder var list: Sidebar
    @ViewBuilder var placeholder: Placeholder
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if sizeClass == .regular {
            NavigationSplitView {
                list
                    .navigationSplitViewColumnWidth(min: 340, ideal: 420, max: 520)
            } detail: {
                NavigationStack {
                    placeholder
                }
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            NavigationStack {
                list
            }
        }
    }
}

/// What the detail column shows before anything in the list is picked.
struct DetailPlaceholder: View {
    let title: String
    let systemImage: String
    let note: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
                .font(Theme.section)
                .foregroundStyle(Theme.text)
        } description: {
            Text(note)
                .font(Theme.body)
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenBackground()
    }
}
