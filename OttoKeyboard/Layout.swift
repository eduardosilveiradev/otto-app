import CoreGraphics
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
    /// `extra`: keys beside space for the field's kind, "." for a URL or search, "@" and "." for an email.
    static func rows(_ page: Page, showGlobe: Bool, extra: [String] = []) -> [[KeyDef]] {
        let bottomLeft: [KeyDef] = [KeyDef(kind: .page(page == .letters ? .numbers : .letters), width: 1.25)]
            + (showGlobe ? [KeyDef(kind: .globe, width: 1.25)] : [])
            + [KeyDef(kind: .emoji, width: 1.25)]
        let spaceW = (showGlobe ? 4.75 : 6) - CGFloat(extra.count) * 1.1
        let bottom = bottomLeft + [KeyDef(kind: .space, width: spaceW)]
            + extra.map { KeyDef(kind: .char($0), width: 1.1) } + [KeyDef(kind: .ret, width: 2.25)]
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

    /// Top-row digits, for styles with number hints.
    static let digits: [String: String] = Dictionary(uniqueKeysWithValues: zip("qwertyuiop".map(String.init), "1234567890".map(String.init)))

    /// The letter key a character is typed with, for swipe paths: é → e.
    static func base(_ ch: Character) -> Character {
        let s = String(ch).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        if ch == "ß" { return "s" }
        if ch == "æ" { return "a" }
        if ch == "ø" { return "o" }
        return s.first ?? ch
    }
}

// MARK: - tap zones

extension Layout {
    /// How far, in points, a likely next letter grows its key into the gap, at most. Two neighbours split the gap at its
    /// middle, moved half the difference of their growth: at 12 that is 6pt, 3pt past the gap into the less likely key.
    static let zoneBias: CGFloat = 12
    /// A touch this far inside a key's drawn edge is that key, whatever the bias, so unusual words aren't fought.
    static let sureInset: CGFloat = 3

    /// The key a touch at `p` means, as (row, key) indexes. Every point resolves: the row is the nearest by height (the
    /// gaps between rows split at the middle, above the top row is the top row, below the bottom one the bottom), then
    /// the nearest key in it by width (the gaps split at the middle, the margins go to the edge keys).
    /// `rows`: each row's drawn key frames, left to right. `likely`: per key, 0...1, how likely it is to come next;
    /// a key grows by `zoneBias` times that, so near a boundary the likelier key wins.
    static func hit(_ p: CGPoint, rows: [[CGRect]], likely: [[CGFloat]] = []) -> (row: Int, key: Int)? {
        for (r, row) in rows.enumerated() {
            if let k = row.firstIndex(where: { $0.insetBy(dx: sureInset, dy: sureInset).contains(p) }) { return (r, k) }
        }
        func grow(_ r: Int, _ k: Int) -> CGFloat {
            r < likely.count && k < likely[r].count ? min(max(likely[r][k], 0), 1) * zoneBias : 0
        }
        // How far outside the span the value is; inside, minus how deep.
        func outside(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { max(lo - v, v - hi) }
        var best: (row: Int, key: Int, d: CGFloat)?
        for (r, row) in rows.enumerated() {
            guard let k = row.indices.min(by: {
                outside(p.x, row[$0].minX, row[$0].maxX) - grow(r, $0) < outside(p.x, row[$1].minX, row[$1].maxX) - grow(r, $1)
            }) else { continue }
            let d = outside(p.y, row[k].minY, row[k].maxY) - grow(r, k)
            if best == nil || d < best!.d { best = (r, k, d) }
        }
        return best.map { ($0.row, $0.key) }
    }
}
