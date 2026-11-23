#if DEBUG
import UIKit

/// Screenshot hooks, DEBUG only. The simulator can't be tapped from a script, so the app's
/// `-kbdDemo "#kbd emoji"` puts a command in the field and the keyboard acts it out:
/// `emoji`, `settings`, `otto`, `ottodone`, `style:<Preset>`, `lang:en,it`, `swipe:<word>`,
/// `dark`, separated by spaces. The command text is cleared from the field afterwards.
extension KeyboardViewController {
    func runPreviewCommands() -> Bool {
        let ctx = textDocumentProxy.documentContextBeforeInput ?? ""
        guard let r = ctx.range(of: "#kbd ") else { return false }
        let cmds = ctx[r.upperBound...].split(separator: " ").map(String.init)
        for _ in ctx { textDocumentProxy.deleteBackward() }
        let keep = String(ctx[..<r.lowerBound])
        textDocumentProxy.insertText(keep)
        var swipeWord: String?
        for c in cmds {
            if c == "emoji" { previewModel.mode = .emoji }
            if c == "settings" { previewModel.mode = .settings }
            if c == "clipboard" {
                ["see you at 8 by the station", "IT60 X054 2811 1010 0000 0123 456", "https://maps.apple.com/?q=Bar+Basso"].reversed().forEach { previewModel.remember(clip: $0) }
                previewModel.mode = .clipboard
            }
            if c == "otto" { previewModel.otto = .composing; previewModel.prompt = "tell her I'll be 10 min late" }
            if c == "dictating" { previewModel.dictation = .listening; previewModel.dictLevel = 0.6 }
            if c == "ottodone" { previewModel.otto = .done("Rewritten") }
            if c.hasPrefix("style:"), let p = KeyStyle.presets.first(where: { $0.name == c.dropFirst(6) }) { previewModel.settings.style = p }
            if c.hasPrefix("lang:") { previewModel.settings.languages = c.dropFirst(5).split(separator: ",").compactMap { Lang(rawValue: String($0)) } }
            if c.hasPrefix("swipe:") { swipeWord = String(c.dropFirst(6)) }
            if c.hasPrefix("type:") {
                // Fast typing, 60 ms a key, through the same calls a tap makes; `_` is the space bar.
                for (i, ch) in c.dropFirst(5).enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 + Double(i) * 0.06) { [self] in
                        ch == "_" ? tapped(.space) : typed(String(ch))
                    }
                }
            }
            if c == "zones" {
                // The tap zones as text, after the lexicon and the lean have landed.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in previewZones() }
            }
            if c.hasPrefix("press:") {
                let ch = String(c.dropFirst(6))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in previewPress(ch) }
            }
        }
        previewApplySettings()
        if let w = swipeWord {
            // Wait for the lexicon and layout, then trace the word through its keys with a little wobble.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in previewSwipe(w) }
        }
        return true
    }
}

extension KeyboardView {
    /// The key every point types, one character per 8×6pt cell across the whole board, without and with the lean
    /// toward likely letters, and the cells the lean changed. Written to the keyboard's tmp/kbd-zones.txt.
    func zoneMaps() -> String {
        func glyph(_ k: KeyView?) -> String {
            switch k?.def.kind {
            case .char(let s)?: s
            case .shift?: "^"; case .delete?: "<"; case .space?: "_"; case .ret?: ">"; case .page?: "#"
            case .globe?: "@"; case .emoji?: ":"; case .otto?: "*"; case nil: "?"
            }
        }
        func map(_ biased: Bool) -> [[String]] {
            stride(from: CGFloat(3), to: bounds.height, by: 6).map { y in
                stride(from: CGFloat(4), to: bounds.width, by: 8).map { x in glyph(key(at: CGPoint(x: x, y: y), biased: biased)) }
            }
        }
        let plain = map(false), lean = map(true)
        let diff = zip(plain, lean).map { zip($0, $1).map { $0 == $1 ? "." : $1 } }
        let likely = self.likely.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key) \(String(format: "%.2f", $0.value))" }
        return "board \(Int(bounds.width))x\(Int(bounds.height))pt, one cell = 8x6pt\n\nno lean:\n" + plain.map { $0.joined() }.joined(separator: "\n")
            + "\n\nlean (likeliest: \(likely.joined(separator: ", "))):\n" + lean.map { $0.joined() }.joined(separator: "\n")
            + "\n\ncells the lean moved:\n" + diff.map { $0.joined() }.joined(separator: "\n") + "\n"
    }

    func demoPress(_ ch: String) {
        guard let k = subviews.compactMap({ $0 as? KeyView }).first(where: { $0.def.kind == .char(ch) }) else { return }
        showPopup(for: k)
    }

    func demoTrail(through word: String) -> [CGPoint] {
        let centers = letterCenters
        var pts: [CGPoint] = []
        var seed: UInt64 = 7
        func jitter() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1; return CGFloat(Int(seed >> 33) % 9) - 4 }
        for ch in word { if let c = centers[ch] { pts.append(CGPoint(x: c.x + jitter(), y: c.y + jitter())) } }
        let path = Lexicon.densify(pts, step: 6)
        showTrail(path)
        return path
    }
}
#endif
