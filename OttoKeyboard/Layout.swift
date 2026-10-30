import Foundation

/// One key on the board. Letters type themselves; the rest are actions.
enum KeyKind: Equatable {
    case char(String)
    case shift, delete, space, ret, globe, emoji, otto
    case page(Page)            // switches to letters / numbers / symbols
}

enum Page { case letters, numbers, symbols }

struct KeyDef {
    var kind: KeyKind
    var width: CGFloat = 1     // in letter-key widths
}

/// EN, IT and PT all use QWERTY on iOS, so one board serves any pair; the languages
/// differ in their accents, which come from a long press.
enum Layout {
    static func rows(_ page: Page, showGlobe: Bool) -> [[KeyDef]] {
        let bottomLeft: [KeyDef] = [KeyDef(kind: .page(page == .letters ? .numbers : .letters), width: 1.25)]
            + (showGlobe ? [KeyDef(kind: .globe, width: 1.25)] : [])
            + [KeyDef(kind: .emoji, width: 1.25)]
        let bottom = bottomLeft + [KeyDef(kind: .space, width: showGlobe ? 4.75 : 6), KeyDef(kind: .ret, width: 2.25)]
        func chars(_ s: String) -> [KeyDef] { s.map { KeyDef(kind: .char(String($0))) } }
        switch page {
        case .letters:
            return [chars("qwertyuiop"), chars("asdfghjkl"),
                    [KeyDef(kind: .shift, width: 1.4)] + chars("zxcvbnm") + [KeyDef(kind: .delete, width: 1.4)],
                    bottom]
        case .numbers:
            return [chars("1234567890"), chars("-/:;()€&@\""),
                    [KeyDef(kind: .page(.symbols), width: 1.4)] + chars(".,?!'") .map { var k = $0; k.width = 1.38; return k }
                        + [KeyDef(kind: .delete, width: 1.4)],
                    bottom]
        case .symbols:
            return [chars("[]{}#%^*+="), chars("_\\|~<>$£¥•"),
                    [KeyDef(kind: .page(.numbers), width: 1.4)] + chars(".,?!'").map { var k = $0; k.width = 1.38; return k }
                        + [KeyDef(kind: .delete, width: 1.4)],
                    bottom]
        }
    }

    /// Long-press alternatives, the accents of all three languages together (iOS order: most used first).
    static let variants: [String: [String]] = [
        "a": ["à", "á", "â", "ã", "ä", "å", "æ", "ª"],
        "e": ["è", "é", "ê", "ë", "ē", "€"],
        "i": ["ì", "í", "î", "ï"],
        "o": ["ò", "ó", "ô", "õ", "ö", "ø", "º"],
        "u": ["ù", "ú", "û", "ü"],
        "c": ["ç", "ć", "č"],
        "n": ["ñ", "ń"],
        "s": ["ß", "ś", "š"],
        "y": ["ÿ"],
        "z": ["ž", "ź", "ż"],
        "l": ["ł"],
        "0": ["°"],
        "-": ["–", "—", "•"],
        "/": ["\\"],
        "€": ["$", "£", "¥", "₩", "R$"],
        "$": ["€", "£", "¥", "R$"],
        "&": ["§"],
        "\"": ["“", "”", "„", "«", "»"],
        "'": ["‘", "’", "`"],
        ".": ["…"],
        "?": ["¿"],
        "!": ["¡"],
        "%": ["‰"],
    ]

    /// The letter key a character is typed with, for swipe paths: é → e.
    static func base(_ ch: Character) -> Character {
        let s = String(ch).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        if ch == "ß" { return "s" }
        if ch == "æ" { return "a" }
        if ch == "ø" { return "o" }
        return s.first ?? ch
    }
}
