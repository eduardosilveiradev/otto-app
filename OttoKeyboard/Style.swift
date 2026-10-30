import UIKit

/// Everything the keyboard draws with. A preset is a starting point; the settings panel
/// can then change the accent, key shape, font and press effects on top of it, and the
/// result is saved whole, so a custom style is just another `KeyStyle`.
struct KeyStyle: Codable, Equatable {
    enum Font: String, Codable, CaseIterable { case system, rounded, serif, mono }

    var name: String
    var background: [RGBA]       // one colour, two for a vertical gradient, or none: the system's glass shows through
    var key: RGBA
    var specialKey: RGBA         // shift, delete, 123, return when it isn't the accent
    var text: RGBA
    var shadow: RGBA
    var accent: RGBA             // Otto button, return, swipe trail, caps lock
    var corner: CGFloat = 5
    var font: Font = .system
    var keyBorder: CGFloat = 0
    /// Follows the system's light/dark (only the built-in default does).
    var followsSystem = false
    /// Small digits on the top row; a long press there types the digit.
    var numberHints = false

    /// Nothing painted behind the keys, so the keyboard and the system's globe/mic strip share one backdrop.
    var seeThrough: Bool { background.isEmpty }

    func uiFont(_ size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        let design: UIFontDescriptor.SystemDesign = switch font {
        case .system: .default
        case .rounded: .rounded
        case .serif: .serif
        case .mono: .monospaced
        }
        return base.fontDescriptor.withDesign(design).map { UIFont(descriptor: $0, size: size) } ?? base
    }

    /// The default style, resolved for light or dark.
    static func system(dark: Bool) -> KeyStyle {
        dark
            ? KeyStyle(name: "System", background: [RGBA(0.10, 0.10, 0.11)], key: RGBA(0.42, 0.42, 0.44),
                       specialKey: RGBA(0.27, 0.27, 0.29), text: RGBA(1, 1, 1), shadow: RGBA(0, 0, 0, 0.6),
                       accent: RGBA(1, 0.62, 0.24), followsSystem: true)
            : KeyStyle(name: "System", background: [RGBA(0.82, 0.83, 0.86)], key: RGBA(1, 1, 1),
                       specialKey: RGBA(0.67, 0.69, 0.73), text: RGBA(0, 0, 0), shadow: RGBA(0.53, 0.54, 0.56),
                       accent: RGBA(1, 0.58, 0.2), followsSystem: true)
    }

    static let presets: [KeyStyle] = [
        .system(dark: false),
        KeyStyle(name: "Smoke", background: [], key: RGBA(0.07, 0.07, 0.08, 0.82),
                 specialKey: RGBA(0.07, 0.07, 0.08, 0.82), text: RGBA(1, 1, 1), shadow: RGBA(0, 0, 0, 0),
                 accent: RGBA(0.22, 0.52, 0.98), corner: 9, numberHints: true),
        KeyStyle(name: "Frost", background: [], key: RGBA(1, 1, 1, 0.78),
                 specialKey: RGBA(1, 1, 1, 0.45), text: RGBA(0, 0, 0), shadow: RGBA(0, 0, 0, 0.12),
                 accent: RGBA(0.22, 0.52, 0.98), corner: 9, numberHints: true),
        KeyStyle(name: "Tangerine", background: [RGBA(1, 0.80, 0.55), RGBA(1, 0.62, 0.30)], key: RGBA(1, 0.97, 0.92),
                 specialKey: RGBA(1, 0.84, 0.66), text: RGBA(0.35, 0.18, 0.05), shadow: RGBA(0.75, 0.42, 0.12),
                 accent: RGBA(0.85, 0.40, 0.08), corner: 9, font: .rounded),
        KeyStyle(name: "Midnight", background: [RGBA(0.06, 0.07, 0.14), RGBA(0.02, 0.02, 0.06)], key: RGBA(0.16, 0.18, 0.30),
                 specialKey: RGBA(0.10, 0.11, 0.20), text: RGBA(0.86, 0.89, 1), shadow: RGBA(0, 0, 0, 0.8),
                 accent: RGBA(0.45, 0.55, 1), corner: 8),
        KeyStyle(name: "Paper", background: [RGBA(0.95, 0.93, 0.88)], key: RGBA(0.99, 0.98, 0.95),
                 specialKey: RGBA(0.88, 0.85, 0.79), text: RGBA(0.20, 0.18, 0.15), shadow: RGBA(0.75, 0.71, 0.64),
                 accent: RGBA(0.70, 0.25, 0.15), corner: 3, font: .serif, keyBorder: 0.5),
        KeyStyle(name: "Mint", background: [RGBA(0.80, 0.94, 0.88)], key: RGBA(0.97, 1, 0.98),
                 specialKey: RGBA(0.66, 0.86, 0.78), text: RGBA(0.07, 0.25, 0.18), shadow: RGBA(0.45, 0.68, 0.58),
                 accent: RGBA(0.10, 0.60, 0.42), corner: 12, font: .rounded),
        KeyStyle(name: "Terminal", background: [RGBA(0, 0, 0)], key: RGBA(0.06, 0.08, 0.06),
                 specialKey: RGBA(0.03, 0.04, 0.03), text: RGBA(0.35, 1, 0.45), shadow: RGBA(0, 0, 0, 0),
                 accent: RGBA(0.35, 1, 0.45), corner: 2, font: .mono, keyBorder: 1),
        KeyStyle(name: "Glass", background: [RGBA(0.55, 0.60, 0.95), RGBA(0.85, 0.55, 0.85)], key: RGBA(1, 1, 1, 0.35),
                 specialKey: RGBA(1, 1, 1, 0.18), text: RGBA(1, 1, 1), shadow: RGBA(0, 0, 0, 0.15),
                 accent: RGBA(1, 1, 1), corner: 10, font: .rounded, keyBorder: 0.5),
    ]

    /// Accent swatches offered in the settings panel.
    static let accents: [RGBA] = [RGBA(1, 0.58, 0.2), RGBA(0.0, 0.48, 1), RGBA(0.20, 0.78, 0.35), RGBA(1, 0.18, 0.33),
                                  RGBA(0.69, 0.32, 0.87), RGBA(1, 0.80, 0), RGBA(0.35, 0.78, 0.98), RGBA(0.5, 0.5, 0.5)]
}

struct RGBA: Codable, Equatable, Hashable {
    var r, g, b, a: CGFloat
    init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    var ui: UIColor { UIColor(red: r, green: g, blue: b, alpha: a) }
}

/// What the user chose. Lives in the extension's own defaults: a free team can't have an
/// app group, so the keyboard is configured from its own settings panel.
struct KeyboardSettings: Codable, Equatable {
    var languages: [Lang] = [.en]           // one or two: two makes it bilingual
    var style: KeyStyle = .system(dark: false)
    var autocorrect = true
    var autoCapitalize = true
    var swipe = true
    var doubleSpacePeriod = true
    var haptics = true
    var clicks = true
    var keyPopups = true

    private static let key = "keyboardSettings"

    static func load() -> KeyboardSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(KeyboardSettings.self, from: data) else { return KeyboardSettings() }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

enum Lang: String, Codable, CaseIterable {
    case en, it, pt
    var label: String { rawValue.uppercased() }
    var name: String { switch self { case .en: "English"; case .it: "Italiano"; case .pt: "Português" } }
    /// UITextChecker's code.
    var checker: String { switch self { case .en: "en_US"; case .it: "it_IT"; case .pt: "pt_BR" } }
    var spaceLabel: String { switch self { case .en: "space"; case .it: "spazio"; case .pt: "espaço" } }
}
