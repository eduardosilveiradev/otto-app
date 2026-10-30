import Foundation

/// The emoji picker's pages, built from Unicode blocks at launch. Only scalars that draw as
/// emoji by default are kept, so nothing shows up as a text glyph or a box.
enum Emoji {
    struct Category { let icon: String; let items: [String] }

    static let categories: [Category] = [
        Category(icon: "face.smiling", items: scan([0x1F600...0x1F64F, 0x1F910...0x1F92F, 0x1F970...0x1F97A, 0x1FAE0...0x1FAE8,
                                                    0x1F440...0x1F450, 0x1F466...0x1F487, 0x1F574...0x1F575, 0x1F645...0x1F64F, 0x1F930...0x1F939,
                                                    0x1F9D0...0x1F9DF, 0x1FAF0...0x1FAF8])),
        Category(icon: "pawprint", items: scan([0x1F400...0x1F43F, 0x1F980...0x1F9AE, 0x1FAB0...0x1FABD, 0x1F330...0x1F344,
                                                0x1F490...0x1F490, 0x1F338...0x1F33F, 0x1FAB4...0x1FAB7, 0x1F300...0x1F31F])),
        Category(icon: "fork.knife", items: scan([0x1F345...0x1F37F, 0x1F950...0x1F96F, 0x1F9C0...0x1F9CB, 0x1FAD0...0x1FADB])),
        Category(icon: "soccerball", items: scan([0x26BD...0x26BE, 0x1F3BE...0x1F3CA, 0x1F93A...0x1F94F, 0x1F380...0x1F393,
                                                  0x1F3A0...0x1F3BD, 0x1F6F7...0x1F6F9, 0x1FA80...0x1FA8A])),
        Category(icon: "car", items: scan([0x1F680...0x1F6C5, 0x1F6D0...0x1F6FC, 0x1F3D4...0x1F3F0, 0x26F0...0x26FD, 0x1F5FB...0x1F5FF])),
        Category(icon: "lightbulb", items: scan([0x1F4A0...0x1F4FF, 0x1F500...0x1F53D, 0x1F9E0...0x1F9FF, 0x1FA90...0x1FAAF,
                                                 0x231A...0x231B, 0x23F0...0x23F3, 0x1F550...0x1F567])),
        Category(icon: "heart", items: scan([0x2764...0x2764, 0x1F493...0x1F49F, 0x1F9E1...0x1F9E1, 0x1F5A4...0x1F5A4, 0x1F90D...0x1F90F,
                                             0x2600...0x27BF, 0x1F191...0x1F19A, 0x1F7E0...0x1F7EB])),
        Category(icon: "flag", items: flags(["IT", "BR", "PT", "US", "GB", "ES", "FR", "DE", "NL", "CH", "IE", "AR", "MX", "CA",
                                             "JP", "KR", "CN", "IN", "AU", "NZ", "ZA", "AO", "MZ", "CV", "SE", "NO", "DK", "FI",
                                             "AT", "BE", "GR", "PL", "CZ", "HR", "TR", "UA", "IL", "AE", "EG", "MA", "CL", "CO",
                                             "PE", "UY", "PY", "VE", "CU", "TH", "VN", "SG", "PH", "ID", "EU", "UN"])
                 + ["🏳️", "🏴", "🏁", "🚩", "🏳️‍🌈", "🏴‍☠️"]),
    ]

    private static func scan(_ ranges: [ClosedRange<UInt32>]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for r in ranges {
            for v in r {
                guard let s = Unicode.Scalar(v), s.properties.isEmojiPresentation else { continue }
                let e = String(Character(s))
                if seen.insert(e).inserted { out.append(e) }
            }
        }
        return out
    }

    private static func flags(_ codes: [String]) -> [String] {
        codes.map { code in
            String(String.UnicodeScalarView(code.unicodeScalars.compactMap { Unicode.Scalar(0x1F1E6 + $0.value - 65) }))
        }
    }
}
