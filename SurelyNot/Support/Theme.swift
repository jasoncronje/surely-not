import SwiftUI
import UIKit

/// The app's look in one place: colours, type and measurements.
///
/// The rules behind it: colour belongs on data, not on buttons and bars.
/// The one blue marks the main thing a screen is about. Categories and
/// institutions get a pale tint of their own colour. Surfaces are flat, with
/// one large corner radius. Money coming in is green with a plus sign, and red
/// is kept for what is actually over or wrong.
enum Theme {
    // MARK: Colour

    static let ground = Color(light: 0xF3F5F7, dark: 0x000000)
    static let surface = Color(light: 0xFFFFFF, dark: 0x111111)
    static let raised = Color(light: 0xEEF1F4, dark: 0x222222)
    static let rule = Color(light: 0xEEF0F2, dark: 0x1E1E1E)
    static let control = Color(light: 0xD6D9DD, dark: 0x444444)
    static let text = Color(light: 0x1B1D1F, dark: 0xFFFFFF)
    static let muted = Color(light: 0x5C6064, dark: 0xB4B4B4)
    /// Fill of the main action. Near-black, so buttons do not compete with data.
    static let primary = Color(light: 0x1B1D1F, dark: 0xFFFFFF)
    static let onPrimary = Color(light: 0xFFFFFF, dark: 0x000000)
    /// The one data colour.
    static let accent = Color(light: 0x1D5FD6, dark: 0x5B93F0)
    static let positive = Color(light: 0x2F7A45, dark: 0x3FC07A)
    static let negative = Color(light: 0xC41C29, dark: 0xE5566F)
    static let warning = Color(light: 0x92400E, dark: 0xD9A441)
    /// The quiet series in a chart and the empty part of a bar.
    static let track = Color(light: 0xDDE1E6, dark: 0x2B2B2B)
    static let grid = Color(light: 0xE5E5E5, dark: 0x2B2B2B)

    // MARK: Measurements

    static let cardRadius: CGFloat = 20
    static let controlRadius: CGFloat = 10
    static let tileRadius: CGFloat = 10
    static let gap: CGFloat = 16
    static let cardPadding: CGFloat = 20
    static let margin: CGFloat = 16

    // MARK: Type

    static let fontName = "Manrope"

    /// Manrope at a size that follows the person's text-size setting.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(fontName, size: size, relativeTo: style).weight(weight)
    }

    static let title = font(28, .semibold, relativeTo: .title)
    static let section = font(20, .regular, relativeTo: .title3)
    static let figure = font(32, .semibold, relativeTo: .largeTitle)
    static let body = font(16, .regular, relativeTo: .body)
    static let bodyStrong = font(16, .semibold, relativeTo: .body)
    static let small = font(14, .regular, relativeTo: .subheadline)
    static let smallStrong = font(14, .semibold, relativeTo: .subheadline)

    /// Applies Manrope to the navigation and tab bars, which SwiftUI does not
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
        self.init(uiColor: UIColor { traits in
            UIColor(Color(rgb: traits.userInterfaceStyle == .dark ? dark : light))
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
        background = Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hue: h, saturation: 0.55, brightness: 0.24, alpha: 1)
                : UIColor(hue: h, saturation: 0.14, brightness: 0.99, alpha: 1)
        })
        ink = Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hue: h, saturation: 0.35, brightness: 0.95, alpha: 1)
                : UIColor(hue: h, saturation: 0.85, brightness: 0.42, alpha: 1)
        })
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

/// The app's mark: a tick with a stroke through it. Sure, with a "not".
struct ProductMark: View {
    var size: CGFloat = 28
    var color: Color = Theme.accent

    var body: some View {
        Canvas { context, canvas in
            let unit = canvas.width / 24
            var tick = Path()
            tick.move(to: CGPoint(x: 3.5 * unit, y: 12.5 * unit))
            tick.addLine(to: CGPoint(x: 9.5 * unit, y: 18.5 * unit))
            tick.addLine(to: CGPoint(x: 20.5 * unit, y: 5.5 * unit))
            var strike = Path()
            strike.move(to: CGPoint(x: 11.5 * unit, y: 5 * unit))
            strike.addLine(to: CGPoint(x: 20.5 * unit, y: 16 * unit))
            let style = StrokeStyle(lineWidth: 2.8 * unit, lineCap: .round, lineJoin: .round)
            context.stroke(tick, with: .color(color), style: style)
            context.stroke(strike, with: .color(color), style: style)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
