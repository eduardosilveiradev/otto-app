import Combine
import SwiftUI
import UIKit

/// Clicks only play from an input view that says it wants them.
final class ClickingInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

final class KeyboardViewController: UIInputViewController, KeyboardViewDelegate {
    private let model = BoardModel()
    private let board = KeyboardView()
    private var bar: UIHostingController<TopBar>!
    private var panel: UIHostingController<AnyView>?
    private let backdrop = UIView()
    private let gradient = CAGradientLayer()
    private var height: NSLayoutConstraint!
    private var barHeight: NSLayoutConstraint!
    private var lexicon: Lexicon?
    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private var watch: AnyCancellable?
    private var panelMode: BoardModel.Mode = .keys

    /// Typed text that autocorrect replaced, so a backspace straight after puts it back.
    private var lastCorrection: (original: String, corrected: String)?
    /// The last swiped word and the decoder's other readings of it.
    private var lastSwipe: (word: String, others: [String])?
    /// A swiped word waits for its space until the next word starts, as on iOS.
    private var pendingSpace = false
    private var lastSpace: Date?
    /// What an Otto rewrite replaced, and what it put in, for Undo.
    private var ottoUndo: (removed: String, inserted: String)?

    private static let keysHeight: CGFloat = 216

    // Tells iOS this keyboard brings its own dictation, so it drops the mic from the strip under the keys.
    override var hasDictationKey: Bool { get { true } set {} }

    override func loadView() {
        inputView = ClickingInputView(frame: .zero, inputViewStyle: .keyboard)
        inputView?.allowsSelfSizing = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        backdrop.layer.addSublayer(gradient)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdrop)

        bar = UIHostingController(rootView: TopBar(m: model))
        bar.view.backgroundColor = .clear
        addChild(bar)
        bar.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar.view)
        bar.didMove(toParent: self)

        board.translatesAutoresizingMaskIntoConstraints = false
        board.delegate = self
        board.popupHost = view
        view.addSubview(board)

        barHeight = bar.view.heightAnchor.constraint(equalToConstant: 44)
        height = view.heightAnchor.constraint(equalToConstant: 44 + Self.keysHeight)
        height.priority = .init(999)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor), backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor), backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.view.topAnchor.constraint(equalTo: view.topAnchor), barHeight,
            bar.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), bar.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            board.topAnchor.constraint(equalTo: bar.view.bottomAnchor), board.heightAnchor.constraint(equalToConstant: Self.keysHeight),
            board.leadingAnchor.constraint(equalTo: view.leadingAnchor), board.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            height,
        ])

        model.pick = { [weak self] in self?.pick($0) }
        model.ask = { [weak self] in self?.askOtto($0) }
        model.undoOtto = { [weak self] in self?.undoOtto() }
        model.typeEmoji = { [weak self] in self?.insert($0) }
        model.deleteBackward = { [weak self] in self?.textDocumentProxy.deleteBackward() }
        model.settingsChanged = { [weak self] in self?.applySettings() }
        model.pasteCurrent = { [weak self] in self?.pasteCurrent() }
        model.copyField = { [weak self] in self?.copyField() }
        model.toggleDictation = { [weak self] in self?.toggleDictation() }
        DictationBridge.observe(DictationBridge.toKeyboard) { [weak self] in self?.dictationChanged() }
        // SwiftUI changes the mode and the Otto state; the UIKit side follows once they've landed.
        watch = model.$mode.combineLatest(model.$otto).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.layoutForModel(); self?.refreshContext() }
        applySettings()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshContext()
        // Back from the app, possibly in a fresh process: pick up a dictation that finished meanwhile.
        dictationChanged()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        gradient.frame = backdrop.bounds
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        applySettings()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        refreshContext()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG
        _ = runPreviewCommands()
        #endif
    }

    #if DEBUG
    var previewModel: BoardModel { model }
    func previewApplySettings() { applySettings() }
    func previewSwipe(_ word: String) { swiped(board.demoTrail(through: word)) }
    #endif

    // MARK: settings and look

    private func applySettings() {
        let s = model.settings
        model.dark = traitCollection.userInterfaceStyle == .dark || textDocumentProxy.keyboardAppearance == .dark
        let style = model.style
        if lexicon?.langs != s.languages {
            let langs = s.languages
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let lex = Lexicon(langs: langs)
                DispatchQueue.main.async { self?.lexicon = lex; self?.refreshSuggestions() }
            }
        }
        board.style = style
        board.swipeEnabled = s.swipe
        board.popupsEnabled = s.keyPopups
        board.spaceTitle = s.languages.count > 1 ? s.languages.map(\.label).joined(separator: " · ") : s.languages[0].spaceLabel
        if !style.seeThrough { gradient.colors = (style.background.count > 1 ? style.background : style.background + style.background).map { $0.ui.cgColor } }
        // The system's own blur shows through the default style, as on iOS.
        backdrop.isHidden = style.followsSystem || style.seeThrough
        layoutForModel()
    }

    private func layoutForModel() {
        barHeight.constant = model.barHeight
        height.constant = model.barHeight + Self.keysHeight
        guard model.mode != panelMode || (panel == nil) != (model.mode == .keys) else { return }
        panelMode = model.mode
        let want: AnyView? = switch model.mode {
        case .keys: nil
        case .emoji: AnyView(EmojiPanel(m: model))
        case .settings: AnyView(SettingsPanel(m: model))
        case .clipboard: AnyView(ClipboardPanel(m: model))
        }
        panel?.willMove(toParent: nil)
        panel?.view.removeFromSuperview()
        panel?.removeFromParent()
        panel = nil
        board.isHidden = want != nil
        guard let want else { return }
        let host = UIHostingController(rootView: want)
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        // Settings take the whole keyboard; emoji keep the bar.
        let topAnchor = model.mode == .settings ? view.topAnchor : bar.view.bottomAnchor
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: topAnchor), host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
        panel = host
    }

    // MARK: context

    private var before: String { textDocumentProxy.documentContextBeforeInput ?? "" }

    /// The word being typed: letters and apostrophes right before the cursor.
    private var currentWord: String {
        String(before.reversed().prefix { $0.isLetter || $0 == "'" }.reversed())
    }

    private func refreshContext() {
        board.showGlobe = needsInputModeSwitchKey
        board.returnTitle = switch textDocumentProxy.returnKeyType {
        case .go: "go"; case .google, .yahoo, .search: "search"; case .join: "join"; case .next: "next"
        case .route: "route"; case .send: "send"; case .done: "done"; case .continue: "continue"; case .emergencyCall: "SOS"
        default: "return"
        }
        board.returnIsAccent = board.returnTitle != "return"
        board.extraKeys = switch textDocumentProxy.keyboardType {
        case .emailAddress: ["@", "."]
        case .URL, .webSearch: ["."]
        default: board.returnTitle == "search" || board.returnTitle == "go" ? ["."] : []
        }
        refreshClipboard()
        updateShift()
        refreshSuggestions()
    }

    private func updateShift() {
        guard board.shift != .locked else { return }
        let type = textDocumentProxy.autocapitalizationType ?? .sentences
        guard model.settings.autoCapitalize, type != UITextAutocapitalizationType.none, model.otto == .closed else {
            if model.otto != .closed { board.shift = model.prompt.isEmpty ? .once : .off }
            else { board.shift = .off }
            return
        }
        if type == .allCharacters { board.shift = .once; return }
        let ctx = before
        let trimmed = ctx.trimmingCharacters(in: .whitespaces)
        let sentenceStart = trimmed.isEmpty || ctx.hasSuffix("\n") || (ctx.last == " " && ".!?".contains(trimmed.last!))
        let wordStart = type == .words && (ctx.isEmpty || ctx.last == " ")
        board.shift = sentenceStart || wordStart ? .once : .off
    }

    private func refreshSuggestions() {
        guard model.otto == .closed, let lex = lexicon else { model.suggestions = []; return }
        if let swipe = lastSwipe, before.hasSuffix(swipe.word) {
            model.suggestions = swipe.others.prefix(3).map { .init(text: $0) }
            return
        }
        let w = currentWord
        guard !w.isEmpty else { model.suggestions = []; return }
        var out: [BoardModel.Suggestion] = [.init(text: w, literal: true)]
        if model.settings.autocorrect, let fix = lex.correction(for: w) {
            out.append(.init(text: matchCase(fix, w), primary: true))
        }
        for c in lex.completions(w, limit: 3) where !out.contains(where: { $0.text.lowercased() == c }) {
            out.append(.init(text: matchCase(c, w)))
        }
        model.suggestions = Array(out.prefix(3))
    }

    private func matchCase(_ word: String, _ typed: String) -> String {
        if typed.count > 1, typed == typed.uppercased() { return word.uppercased() }
        if typed.first?.isUppercase == true { return word.prefix(1).uppercased() + word.dropFirst() }
        return word
    }

    // MARK: typing

    private func insert(_ s: String) {
        textDocumentProxy.insertText(s)
        lastCorrection = nil
        lastSwipe = nil
        refreshContext()
    }

    /// Autocorrects the word just finished, before a space, return or punctuation.
    private func finishWord() {
        guard model.settings.autocorrect, let lex = lexicon else { return }
        let w = currentWord
        guard !w.isEmpty, let fix = lex.correction(for: w) else { return }
        let fixed = matchCase(fix, w)
        for _ in w { textDocumentProxy.deleteBackward() }
        textDocumentProxy.insertText(fixed)
        lastCorrection = (w, fixed)
    }

    func typed(_ s: String) {
        if model.otto == .composing { model.prompt += s; updateShift(); return }
        guard model.otto == .closed || isOttoAfterglow else { return }
        clearOttoAfterglow()
        if pendingSpace, s.first?.isLetter == true || s.first?.isNumber == true { textDocumentProxy.insertText(" ") }
        pendingSpace = false
        let punct = ".,!?;:".contains(s)
        if punct {
            finishWord()
            // "word ." from a swipe's waiting space: tuck the punctuation onto the word.
        }
        let kept = lastCorrection
        insert(s)
        if punct { lastCorrection = kept }
        if board.shift == .once { board.shift = .off }
        updateShift()
    }

    func tapped(_ kind: KeyKind) {
        switch kind {
        case .space: space()
        case .ret:
            if model.otto == .composing { if !model.prompt.isEmpty { askOtto(model.prompt) }; return }
            finishWord()
            pendingSpace = false
            insert("\n")
        case .delete: delete()
        case .globe: advanceToNextInputMode()
        case .emoji: model.mode = .emoji
        case .page(let p): board.page = p
        case .otto: model.otto = .composing
        default: break
        }
    }

    private func space() {
        if model.otto == .composing { model.prompt += " "; return }
        clearOttoAfterglow()
        if pendingSpace { pendingSpace = false; textDocumentProxy.insertText(" "); lastSwipe = nil; refreshContext(); return }
        let now = Date()
        let ctx = before
        if model.settings.doubleSpacePeriod, let last = lastSpace, now.timeIntervalSince(last) < 0.45, ctx.hasSuffix(" "),
           let prev = ctx.dropLast().last, prev.isLetter || prev.isNumber {
            textDocumentProxy.deleteBackward()
            insert(". ")
            lastSpace = nil
            return
        }
        lastSpace = now
        finishWord()
        let kept = lastCorrection
        insert(" ")
        lastCorrection = kept
        if board.page != .letters { board.page = .letters }
    }

    private func delete() {
        if model.otto == .composing { if !model.prompt.isEmpty { model.prompt.removeLast() }; updateShift(); return }
        clearOttoAfterglow()
        if pendingSpace { pendingSpace = false; deleteSwipedWord(); return }
        // Backspace right after an autocorrect: put back what they typed, as iOS does.
        if let c = lastCorrection, before.hasSuffix(c.corrected + " ") || before.hasSuffix(c.corrected) {
            let trailing = before.hasSuffix(" ") ? 1 : 0
            for _ in 0..<(c.corrected.count + trailing) { textDocumentProxy.deleteBackward() }
            insert(c.original)
            return
        }
        textDocumentProxy.deleteBackward()
        lastCorrection = nil
        refreshContext()
    }

    /// Backspace after a swipe takes the whole word, as on iOS.
    private func deleteSwipedWord() {
        if let w = lastSwipe?.word, before.hasSuffix(w) { for _ in w { textDocumentProxy.deleteBackward() } }
        else { textDocumentProxy.deleteBackward() }
        lastSwipe = nil
        refreshContext()
    }

    func deleteRepeat(words: Bool) {
        if model.otto == .composing { delete(); return }
        guard words else { delete(); return }
        let ctx = before
        let trailingSpaces = ctx.reversed().prefix { $0 == " " }.count
        let word = ctx.dropLast(trailingSpaces).reversed().prefix { !$0.isWhitespace }.count
        for _ in 0..<max(1, trailingSpaces + word) { textDocumentProxy.deleteBackward() }
        lastCorrection = nil
        refreshContext()
    }

    func swiped(_ path: [CGPoint]) {
        guard let lex = lexicon else { return }
        let words = lex.decode(path: path, centers: board.letterCenters, unit: board.unitWidth)
        guard var word = words.first else { return }
        let capitalize = board.shift != .off
        func cased(_ w: String) -> String { board.shift == .locked ? w.uppercased() : capitalize ? w.prefix(1).uppercased() + w.dropFirst() : w }
        word = cased(word)
        if model.otto == .composing {
            if let last = model.prompt.last, last != " " { model.prompt += " " }
            model.prompt += word
            updateShift()
            return
        }
        clearOttoAfterglow()
        let ctx = before
        if pendingSpace || (ctx.last.map { !$0.isWhitespace && $0 != "(" && $0 != "\"" } ?? false) { textDocumentProxy.insertText(" ") }
        textDocumentProxy.insertText(word)
        lastCorrection = nil
        lastSwipe = (word, words.dropFirst().map(cased))
        pendingSpace = true
        if board.shift == .once { board.shift = .off }
        refreshSuggestions()
    }

    func moveCursor(_ by: Int) {
        textDocumentProxy.adjustTextPosition(byCharacterOffset: by)
        pendingSpace = false
    }

    func shiftChanged() {}

    func keyDown() {
        if model.settings.haptics { haptic.impactOccurred(intensity: 0.6) }
        if model.settings.clicks { UIDevice.current.playInputClick() }
    }

    private func pick(_ s: BoardModel.Suggestion) {
        if let swipe = lastSwipe, before.hasSuffix(swipe.word) {
            for _ in swipe.word { textDocumentProxy.deleteBackward() }
            textDocumentProxy.insertText(s.text)
            lastSwipe = (s.text, swipe.others.filter { $0 != s.text } + [swipe.word])
            refreshSuggestions()
            return
        }
        for _ in currentWord { textDocumentProxy.deleteBackward() }
        insert(s.text + " ")
        pendingSpace = false
    }

    // MARK: clipboard

    private static let seenKey = "clipSeenChangeCount"

    /// changeCount and hasStrings don't read the clipboard, so iOS shows no paste banner for them.
    private func refreshClipboard() {
        let pb = UIPasteboard.general
        model.pasteReady = hasFullAccess && pb.hasStrings && pb.changeCount != UserDefaults.standard.integer(forKey: Self.seenKey)
    }

    private func pasteCurrent() {
        guard hasFullAccess else { model.flash = "Needs Allow Full Access"; return }
        let pb = UIPasteboard.general
        UserDefaults.standard.set(pb.changeCount, forKey: Self.seenKey)
        guard let s = pb.string, !s.isEmpty else { refreshClipboard(); return }
        model.remember(clip: s)
        if model.mode == .clipboard { model.mode = .keys }
        insert(s)
    }

    /// Copies everything in the field (or what's selected), and keeps it in the history.
    private func copyField() {
        guard hasFullAccess else { model.flash = "Needs Allow Full Access"; return }
        let p = textDocumentProxy
        let text = p.selectedText?.isEmpty == false ? p.selectedText! : (p.documentContextBeforeInput ?? "") + (p.documentContextAfterInput ?? "")
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        UserDefaults.standard.set(UIPasteboard.general.changeCount, forKey: Self.seenKey)
        model.remember(clip: text)
        model.flash = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.model.flash = nil }
    }

    // MARK: dictation

    /// The dictation this keyboard asked for. On disk: iOS often ends the keyboard's
    /// process while they're in the app starting it.
    private var dictationID: String? {
        get { UserDefaults.standard.string(forKey: "dictationID") }
        set { UserDefaults.standard.set(newValue, forKey: "dictationID") }
    }

    private func toggleDictation() {
        guard hasFullAccess else { model.flash = "Needs Allow Full Access"; return }
        if model.dictation == .listening, let id = dictationID {
            DictationBridge.write(.init(action: .stop, id: id))
            DictationBridge.post(DictationBridge.toApp)
            return
        }
        let id = UUID().uuidString
        dictationID = id
        DictationBridge.write(.init(action: .start, id: id, preceding: String(before.suffix(200)),
                                    langs: model.settings.languages.map(\.rawValue)))
        if DictationBridge.readState().appIsWarm {
            DictationBridge.post(DictationBridge.toApp)
        } else {
            // iOS won't let a backgrounded app turn the mic on: open it, as Raycast's keyboard does.
            openContainingApp(DictationBridge.openURL)
        }
    }

    private func dictationChanged() {
        guard let id = dictationID else { return }
        let s = DictationBridge.readState()
        guard s.id == id else { return }
        model.dictLevel = s.level
        switch s.phase {
        case .done:
            dictationID = nil
            model.dictation = .idle
            if let t = s.text, !t.isEmpty {
                let ctx = before
                let joined = ctx.isEmpty || ctx.last!.isWhitespace || t.first.map { $0 == " " || $0.isPunctuation } == true
                insert((joined ? "" : " ") + t)
            }
        case .failed:
            dictationID = nil
            model.dictation = .idle
            model.flash = s.text
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.model.flash = nil }
        default:
            model.dictation = s.phase
        }
    }

    /// Keyboards aren't given `open(_:)`, but the UIApplication at the end of the responder
    /// chain still answers it; this is how other keyboards hand off to their app.
    private func openContainingApp(_ url: URL) {
        let sel = NSSelectorFromString("openURL:options:completionHandler:")
        var r: UIResponder? = self
        while let cur = r {
            if cur is UIApplication, cur.responds(to: sel) {
                typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
                unsafeBitCast(cur.method(for: sel), to: Open.self)(cur, sel, url as NSURL, [:], nil)
                return
            }
            r = cur.next
        }
        model.flash = "Open Otto to dictate"
    }

    // MARK: Otto

    private var isOttoAfterglow: Bool { if case .done = model.otto { true } else if case .failed = model.otto { true } else { false } }

    /// Typing after Otto answered closes the bar; the answer stays.
    private func clearOttoAfterglow() {
        if isOttoAfterglow { model.otto = .closed; ottoUndo = nil }
    }

    private func askOtto(_ instruction: String) {
        guard hasFullAccess else {
            model.otto = .failed("Turn on Allow Full Access: Settings › General › Keyboard › Keyboards › Otto.")
            return
        }
        guard let (base, token) = ShareDirect.load() else {
            model.otto = .failed("Open the Otto app once, so the keyboard knows where to reach it.")
            return
        }
        let field = before
        let rewrite = instruction.hasPrefix("Rewrite") && !field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        model.otto = .thinking
        var req = URLRequest(url: base.appending(path: "app/ask"), timeoutInterval: 40)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString, "text": instruction, "via": "keyboard", "field": field,
        ])
        Task { @MainActor in
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let reply = json["reply"] as? [String: Any], let text = reply["text"] as? String, !text.isEmpty
                else { model.otto = .failed("Otto didn't answer in time. It'll be in the app."); return }
                apply(text, replacing: rewrite ? field : nil)
            } catch {
                model.otto = .failed("Couldn't reach Otto.")
            }
        }
    }

    private func apply(_ text: String, replacing old: String?) {
        if let old, before.hasSuffix(old) {
            for _ in old { textDocumentProxy.deleteBackward() }
            textDocumentProxy.insertText(text)
            ottoUndo = (old, text)
            model.otto = .done("Rewritten")
        } else {
            let ctx = before
            let lead = ctx.isEmpty || ctx.last?.isWhitespace == true ? "" : " "
            textDocumentProxy.insertText(lead + text)
            ottoUndo = ("", lead + text)
            model.otto = .done("Added")
        }
        model.prompt = ""
        refreshContext()
    }

    private func undoOtto() {
        guard let u = ottoUndo, before.hasSuffix(u.inserted) else { model.otto = .closed; return }
        for _ in u.inserted { textDocumentProxy.deleteBackward() }
        textDocumentProxy.insertText(u.removed)
        ottoUndo = nil
        model.otto = .closed
        refreshContext()
    }
}
