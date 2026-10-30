import UIKit

/// The words of the active languages, by frequency. Each list is the top 30k of the
/// OpenSubtitles 2018 counts (hermitdave/FrequencyWords, CC BY-SA 4.0), so rank stands in
/// for probability. Two languages at once is the bilingual board: every lookup searches
/// both, and a word belongs to whichever ranks it higher.
final class Lexicon {
    struct Entry {
        let word: String
        let rank: Int          // 0 = most common, across the languages it appears in
        let keys: [Character]  // the letter keys a swipe passes, repeats collapsed: "hello" → h e l o
    }

    let langs: [Lang]
    private(set) var byWord: [String: Entry] = [:]          // folded form ("dont", "perche") → entry
    private var byEnds: [String: [Entry]] = [:]             // first+last key → entries, for swipes
    private var sorted: [String] = []                       // every word, for prefix completions
    private var exact = Set<String>()                       // every word as spelled, marks included
    private let checker = UITextChecker()

    init(langs: [Lang]) {
        self.langs = langs
        for lang in langs {
            guard let url = Bundle.main.url(forResource: "words-\(lang.rawValue)", withExtension: "txt"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var rank = 0
            for line in text.split(separator: "\n") {
                let w = String(line)
                let key = Self.fold(w)
                exact.insert(w)
                if let old = byWord[key], old.rank <= rank { rank += 1; continue }
                byWord[key] = Entry(word: w, rank: rank, keys: Self.keys(w))
                rank += 1
            }
        }
        for e in byWord.values where e.keys.count >= 2 {
            byEnds[String([e.keys.first!, e.keys.last!]), default: []].append(e)
        }
        sorted = byWord.values.map(\.word).sorted()
    }

    /// Lowercased, apostrophes dropped: what a word looks like typed without them.
    static func fold(_ w: String) -> String { w.lowercased().replacingOccurrences(of: "'", with: "") }

    static func keys(_ w: String) -> [Character] {
        var out: [Character] = []
        for ch in w.lowercased() where ch != "'" {
            let b = Layout.base(ch)
            if out.last != b { out.append(b) }
        }
        return out
    }

    func isKnown(_ word: String) -> Bool {
        let lower = word.lowercased()
        if exact.contains(lower) { return true }
        return langs.contains { lang in
            checker.rangeOfMisspelledWord(in: lower, range: NSRange(location: 0, length: (lower as NSString).length),
                                          startingAt: 0, wrap: false, language: lang.checker).location == NSNotFound
        }
    }

    /// Up to `limit` common words starting with `prefix`.
    func completions(_ prefix: String, limit: Int = 3) -> [String] {
        let p = prefix.lowercased()
        guard !p.isEmpty else { return [] }
        var lo = 0, hi = sorted.count
        while lo < hi { let mid = (lo + hi) / 2; if sorted[mid] < p { lo = mid + 1 } else { hi = mid } }
        var found: [Entry] = []
        var i = lo
        while i < sorted.count, sorted[i].hasPrefix(p), found.count < 400 {
            if sorted[i] != p, let e = byWord[Self.fold(sorted[i])] { found.append(e) }
            i += 1
        }
        return found.sorted { $0.rank < $1.rank }.prefix(limit).map(\.word)
    }

    /// The word they most likely meant, or nil when what they typed is fine.
    /// Conservative on purpose: a wrong autocorrect costs more than a missed one.
    func correction(for typed: String) -> String? {
        let lower = typed.lowercased()
        guard lower.count >= 1, lower.allSatisfy({ $0.isLetter || $0 == "'" }) else { return nil }
        if langs.contains(.en), lower == "i" { return "I" }
        // "dont" → "don't", "perche" → "perché": the same letters, only marks missing.
        if let e = byWord[Self.fold(lower)], e.word != lower, !exact.contains(lower) { return e.word }
        if isKnown(lower) || lower.count < 2 { return nil }
        var best: Entry?
        for cand in edits(lower) {
            if let e = byWord[cand], e.rank < 20_000, best == nil || e.rank < best!.rank { best = e }
        }
        if best == nil {
            for lang in langs {
                let guesses = checker.guesses(forWordRange: NSRange(location: 0, length: (lower as NSString).length),
                                              in: lower, language: lang.checker) ?? []
                if let g = guesses.first(where: { !$0.contains(" ") }), let e = byWord[Self.fold(g)], e.rank < 10_000 {
                    if best == nil || e.rank < best!.rank { best = e }
                }
            }
        }
        // A word cut short: "tonig" means "tonight" more than one edit's "toni".
        if lower.count >= 4, let done = completions(lower, limit: 1).first, let e = byWord[Self.fold(done)],
           e.rank < 5_000, best == nil || e.rank < best!.rank { best = e }
        return best?.word
    }

    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyzàáâãçèéêìíîòóôõùúü")

    /// Everything one edit away (delete, swap, replace, insert), folded.
    private func edits(_ w: String) -> Set<String> {
        let c = Array(w)
        var out = Set<String>()
        for i in 0...c.count {
            if i < c.count { out.insert(String(c[..<i] + c[(i + 1)...])) }
            if i + 1 < c.count { var s = c; s.swapAt(i, i + 1); out.insert(String(s)) }
            for a in Self.alphabet {
                if i < c.count, a != c[i] { var s = c; s[i] = a; out.insert(String(s)) }
                var s = c; s.insert(a, at: i); out.insert(String(s))
            }
        }
        return Set(out.map(Self.fold))
    }

    // MARK: swipe

    /// Words for a swipe across the board, best first. `centers` maps each letter key to its
    /// middle; `unit` is a key's width. A simplified SHARK²: candidates must start and end
    /// near the path's ends and pass each of their letters in order, then rank on how far the
    /// path strays from the ideal line through their keys, plus how rare they are.
    func decode(path raw: [CGPoint], centers: [Character: CGPoint], unit: CGFloat) -> [String] {
        guard raw.count >= 2, unit > 0 else { return [] }
        let path = Self.densify(raw, step: unit / 4)
        let near = unit * 1.15
        func around(_ p: CGPoint) -> [Character] {
            centers.filter { $0.value.distance(to: p) < unit * 1.3 }.sorted { $0.value.distance(to: p) < $1.value.distance(to: p) }
                .prefix(3).map(\.key)
        }
        let starts = around(path.first!), ends = around(path.last!)
        var scored: [(String, CGFloat)] = []
        let userShape = Self.resample(path, n: 32)
        for s in starts {
            for e in ends {
                for cand in byEnds[String([s, e])] ?? [] {
                    let pts = cand.keys.compactMap { centers[$0] }
                    guard pts.count == cand.keys.count, Self.passes(path, pts, within: near) else { continue }
                    let ideal = Self.resample(pts, n: 32)
                    var d: CGFloat = 0
                    for i in 0..<32 { d += userShape[i].distance(to: ideal[i]) }
                    let shape = d / 32 / unit
                    let freq = log10(CGFloat(cand.rank) + 10)
                    scored.append((cand.word, shape * 2.2 + freq * 0.45))
                }
            }
        }
        return scored.sorted { $0.1 < $1.1 }.prefix(4).map(\.0)
    }

    /// Every key visited in order, each within `r` of some later point of the path.
    private static func passes(_ path: [CGPoint], _ keys: [CGPoint], within r: CGFloat) -> Bool {
        var j = 0
        for k in keys {
            while j < path.count, path[j].distance(to: k) > r { j += 1 }
            if j == path.count { return false }
        }
        return true
    }

    static func densify(_ pts: [CGPoint], step: CGFloat) -> [CGPoint] {
        var out = [pts[0]]
        for p in pts.dropFirst() {
            let a = out.last!, d = a.distance(to: p)
            if d > step {
                let n = Int(d / step)
                for i in 1...n { out.append(a.lerp(p, CGFloat(i) / CGFloat(n + 1))) }
            }
            out.append(p)
        }
        return out
    }

    /// `n` points evenly spaced along the polyline.
    static func resample(_ pts: [CGPoint], n: Int) -> [CGPoint] {
        if pts.count == 1 { return Array(repeating: pts[0], count: n) }
        var lengths: [CGFloat] = [0]
        for i in 1..<pts.count { lengths.append(lengths[i - 1] + pts[i - 1].distance(to: pts[i])) }
        let total = lengths.last!
        guard total > 0 else { return Array(repeating: pts[0], count: n) }
        var out: [CGPoint] = []
        var seg = 1
        for i in 0..<n {
            let t = total * CGFloat(i) / CGFloat(n - 1)
            while seg < pts.count - 1, lengths[seg] < t { seg += 1 }
            let span = lengths[seg] - lengths[seg - 1]
            out.append(pts[seg - 1].lerp(pts[seg], span > 0 ? (t - lengths[seg - 1]) / span : 0))
        }
        return out
    }
}

extension CGPoint {
    func distance(to p: CGPoint) -> CGFloat { hypot(x - p.x, y - p.y) }
    func lerp(_ p: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: x + (p.x - x) * t, y: y + (p.y - y) * t) }
}
