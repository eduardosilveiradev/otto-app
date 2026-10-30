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
    func demoTrail(through word: String) -> [CGPoint] {
        let centers = letterCenters
        var pts: [CGPoint] = []
        var seed: UInt64 = 7
        func jitter() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1; return CGFloat(Int(seed >> 33) % 9) - 4 }
        for ch in word { if let c = centers[ch] { pts.append(CGPoint(x: c.x + jitter(), y: c.y + jitter())) } }
        let path = Lexicon.densify(pts, step: 6)
        let b = UIBezierPath()
        b.move(to: path[0])
        path.dropFirst().forEach { b.addLine(to: $0) }
        showTrail(b.cgPath)
        return path
    }
}
#endif
