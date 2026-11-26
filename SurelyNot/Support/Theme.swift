import SwiftUI
import UIKit

/// The app's look in one place: colours, type and measurements.
///
/// Taken from Sure's own design system (`design/tokens/sure.tokens.json` in
/// we-promise/sure, also used by Sure's Flutter app), so the phone matches
/// Sure on the web: neutral greys, white containers on a pale grey page,
/// near-black buttons, Geist type and Sure's blue for links and the main
/// figure. Colour belongs on data. Money coming in is Sure's success green,
/// and red is kept for what is actually over or wrong.
enum Theme {
    // MARK: Colour

    /// Sure's `surface`: the page behind everything.
    static let ground = Color(light: 0xF7F7F7, dark: 0x0B0B0B)
    /// Sure's `container`: cards and panels.
    static let surface = Color(light: 0xFFFFFF, dark: 0x171717)
    /// Sure's `surface-inset`: fields, chips and pressed rows.
    static let raised = Color(light: 0xF0F0F0, dark: 0x242424)
    /// Sure's `border-subdued` hairline between rows.
    static let rule = Color(light: 0xEBEBEB, dark: 0x2A2A2A)
    /// The hairline ring around a card, Sure's `shadow-border-xs`.
    static let ring = Color(light: 0x0B0B0B, dark: 0xFFFFFF).opacity(0.06)
    static let control = Color(light: 0xCFCFCF, dark: 0x363636)
    /// Sure's `text-primary`.
    static let text = Color(light: 0x171717, dark: 0xFFFFFF)
    /// Sure's `text-secondary`.
    static let muted = Color(light: 0x737373, dark: 0xCFCFCF)
    /// Sure's `text-subdued`.
    static let subdued = Color(light: 0x9E9E9E, dark: 0x9E9E9E)
    /// Fill of the main action: Sure's `button-bg-primary`.
    static let primary = Color(light: 0x171717, dark: 0xFFFFFF)
    static let onPrimary = Color(light: 0xFFFFFF, dark: 0x171717)
    /// The one data colour: Sure's `link` and `info` blue.
    static let accent = Color(light: 0x1570EF, dark: 0x2E90FA)
    /// Sure's `success`.
    static let positive = Color(light: 0x078C52, dark: 0x32D583)
    /// Sure's `destructive`.
    static let negative = Color(light: 0xEC2222, dark: 0xED4E4E)
    /// Sure's `warning`.
    static let warning = Color(light: 0xB54708, dark: 0xFDB022)
    /// The quiet series in a chart and the empty part of a bar
    /// (Sure's `budget-unused-fill`).
    static let track = Color(light: 0xE7E7E7, dark: 0x363636)
    static let grid = Color(light: 0xE7E7E7, dark: 0x2A2A2A)
    /// The two greens of Sure's logomark.
    static let brandGreen = Color(rgb: 0x61A446)

    // MARK: Measurements

    /// Sure's cards are `rounded-xl`; controls and tiles `rounded-lg`.
    static let cardRadius: CGFloat = 12
    static let controlRadius: CGFloat = 10
    static let tileRadius: CGFloat = 8
    static let gap: CGFloat = 16
    static let cardPadding: CGFloat = 20
    static let margin: CGFloat = 16
    /// Space under the last thing on a screen. The tab bar shrinks to a
    /// floating button while scrolling down, and this keeps it off the last row.
    static let bottomRoom: CGFloat = 96

    // MARK: Type

    static let fontName = "Geist"

    /// Geist, Sure's typeface, at a size that follows the person's text-size setting.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(fontName, size: size, relativeTo: style).weight(weight)
    }

    static let title = font(26, .semibold, relativeTo: .title)
    static let section = font(18, .medium, relativeTo: .title3)
    static let figure = font(30, .medium, relativeTo: .largeTitle)
    static let body = font(16, .regular, relativeTo: .body)
    static let bodyStrong = font(16, .semibold, relativeTo: .body)
    static let small = font(14, .regular, relativeTo: .subheadline)
    static let smallStrong = font(14, .semibold, relativeTo: .subheadline)

    // MARK: Icons

    /// Chevrons and other small marks beside text.
    static let glyphSmall = Font.system(size: 12, weight: .semibold)
    /// An icon in a button, a tile or a field.
    static let glyph = Font.system(size: 17, weight: .medium)
    /// The round mark of a choice that can be picked.
    static let glyphLarge = Font.system(size: 22)

    /// Applies Geist to the navigation and tab bars, which SwiftUI does not
    /// reach through the environment.
    static func applyBarAppearance() {
        func barFont(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
            let descriptor = UIFontDescriptor(fontAttributes: [
                .family: fontName,
                .traits: [UIFontDescriptor.TraitKey.weight: weight],
            ])
            return UIFont(descriptor: descriptor, size: size)
        }
        let navigation = UINavigationBarAppearance()
        navigation.configureWithTransparentBackground()
        navigation.backgroundColor = UIColor(ground)
        navigation.titleTextAttributes = [.font: barFont(17, .semibold), .foregroundColor: UIColor(text)]
        UINavigationBar.appearance().standardAppearance = navigation
        UINavigationBar.appearance().scrollEdgeAppearance = navigation
        UITabBarItem.appearance().setTitleTextAttributes([.font: barFont(11, .medium)], for: .normal)
    }
}

extension Color {
    init(rgb: UInt32) {
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }

    /// A colour with separate values for light and dark appearance.
    init(light: UInt32, dark: UInt32) {
        self = AdaptiveColor.make(light: UIColor(Color(rgb: light)), dark: UIColor(Color(rgb: dark)))
    }
}

/// Builds colours that differ between light and dark appearance.
///
/// SwiftUI can ask for these on a background thread while it draws an
/// animation. So the choice between the two is made in code that is not tied
/// to the main thread; tying it there crashes the app mid-animation.
nonisolated enum AdaptiveColor {
    static func make(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}

/// A pale background and a dark ink of the same hue, for tiles and chips.
struct Tint {
    let background: Color
    let ink: Color

    static let neutral = Tint(background: Theme.raised, ink: Theme.muted)

    /// From a hue in degrees. The pale fill and dark ink keep readable
    /// contrast whatever the hue, in both light and dark appearance.
    init(hue: Double) {
        let h = hue.truncatingRemainder(dividingBy: 360) / 360
        background = AdaptiveColor.make(
            light: UIColor(hue: h, saturation: 0.14, brightness: 0.99, alpha: 1),
            dark: UIColor(hue: h, saturation: 0.55, brightness: 0.24, alpha: 1)
        )
        ink = AdaptiveColor.make(
            light: UIColor(hue: h, saturation: 0.85, brightness: 0.42, alpha: 1),
            dark: UIColor(hue: h, saturation: 0.35, brightness: 0.95, alpha: 1)
        )
    }

    private init(background: Color, ink: Color) {
        self.background = background
        self.ink = ink
    }

    /// From a colour the server gives a category, such as "#0ea5e9".
    /// Greys and unreadable values fall back to the neutral tint.
    init(hex: String?) {
        guard let hue = Self.hue(ofHex: hex) else {
            self = .neutral
            return
        }
        self.init(hue: hue)
    }

    /// A stable tint for a name, so one institution always gets one colour.
    init(name: String) {
        // A simple fixed hash: Swift's own hashing changes between launches.
        var hash: UInt32 = 2_166_136_261
        for byte in name.lowercased().utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        self.init(hue: Self.palette[Int(hash % UInt32(Self.palette.count))])
    }

    /// Hues spaced well apart, leaving out violet.
    private static let palette: [Double] = [205, 160, 25, 340, 95, 185, 45, 0, 130, 225]

    static func hue(ofHex hex: String?) -> Double? {
        guard let hex else { return nil }
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        let color = UIColor(Color(rgb: value))
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        guard color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil),
              saturation > 0.12 else { return nil }
        return Double(hue) * 360
    }
}

/// Sure's logomark: "su" over "re", grey and green.
struct ProductMark: View {
    var size: CGFloat = 28
    /// Spoken by VoiceOver when set; otherwise the mark is decoration.
    var label: String?

    var body: some View {
        Image(decorative: "SureLogomark")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(label == nil)
            .accessibilityLabel(label ?? "")
    }
}

extension View {
    /// Sure's card edge: a 1pt shadow and a hairline ring, `shadow-border-xs`.
    func sureCardEdge(radius: CGFloat = Theme.cardRadius) -> some View {
        overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.ring, lineWidth: 1))
            .shadow(color: .black.opacity(0.06), radius: 1, x: 0, y: 1)
    }
}
