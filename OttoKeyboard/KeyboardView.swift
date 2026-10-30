import UIKit

/// What the board tells the controller. The board knows keys and fingers; the controller
/// knows the text.
protocol KeyboardViewDelegate: AnyObject {
    func typed(_ s: String)
    func tapped(_ kind: KeyKind)
    func deleteRepeat(words: Bool)
    /// False when no word fits the path; the board then types the key it started on.
    func swiped(_ path: [CGPoint]) -> Bool
    func moveCursor(_ by: Int)
    func shiftChanged()
    func keyDown()
}

enum ShiftState { case off, once, locked }

final class KeyboardView: UIView {
    weak var delegate: KeyboardViewDelegate?
    /// Popups draw here so a top-row balloon can rise over the suggestion bar.
    weak var popupHost: UIView?

    var style: KeyStyle = .system(dark: false) { didSet { rebuild() } }
    var page: Page = .letters { didSet { if page != oldValue { rebuild() } } }
    var shift: ShiftState = .off { didSet { if shift != oldValue { refreshLabels() } } }
    var showGlobe = true { didSet { if showGlobe != oldValue { rebuild() } } }
    var returnTitle = "return" { didSet { if returnTitle != oldValue { refreshLabels() } } }
    var returnIsAccent = false { didSet { if returnIsAccent != oldValue { refreshLabels() } } }
    var spaceTitle = "space" { didSet { if spaceTitle != oldValue { refreshLabels() } } }
    var extraKeys: [String] = [] { didSet { if extraKeys != oldValue { rebuild() } } }
    var swipeEnabled = true
    var popupsEnabled = true

    private var keys: [KeyView] = []
    private var rowFrames: [CGRect] = []
    private let trail = SwipeTrail()

    private let gap: CGFloat = 6, rowGap: CGFloat = 11, side: CGFloat = 3, top: CGFloat = 8

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        addSubview(trail)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: layout

    private func rebuild() {
        keys.forEach { $0.removeFromSuperview() }
        keys = Layout.rows(page, showGlobe: showGlobe, extra: page == .letters ? extraKeys : []).enumerated().flatMap { r, row in
            row.map { KeyView(def: $0, row: r) }
        }
        keys.forEach { addSubview($0) }
        bringSubviewToFront(trail)   // back on top of the new keys
        // iOS draws it in the key text colour, not a tint: white on dark boards, a soft ink on light ones.
        trail.color = style.text.ui.withAlphaComponent(style.text.r + style.text.g + style.text.b > 1.5 ? 0.85 : 0.45)
        refreshLabels()
        setNeedsLayout()
    }

    private func refreshLabels() {
        for k in keys { k.apply(style: style, shift: shift, returnTitle: returnTitle, returnAccent: returnIsAccent, spaceTitle: spaceTitle) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        trail.frame = bounds
        let rows = Dictionary(grouping: keys, by: \.row).sorted { $0.key < $1.key }.map(\.value)
        guard !rows.isEmpty else { return }
        let rowH = (bounds.height - top - 4 - rowGap * CGFloat(rows.count - 1)) / CGFloat(rows.count)
        let unit = (bounds.width - 2 * side - 9 * gap) / 10
        rowFrames = []
        for (r, row) in rows.enumerated() {
            let y = top + CGFloat(r) * (rowH + rowGap)
            let charW = row.filter(\.isChar).reduce(0) { $0 + $1.def.width * unit }
            let specials = row.filter { !$0.isChar }
            let free = bounds.width - 2 * side - gap * CGFloat(row.count - 1) - charW
            let specialUnits = specials.reduce(0) { $0 + $1.def.width }
            var x = specials.isEmpty ? (bounds.width - charW - gap * CGFloat(row.count - 1)) / 2 : side
            for k in row {
                let w = k.isChar ? k.def.width * unit : free * k.def.width / specialUnits
                k.frame = CGRect(x: x, y: y, width: w, height: rowH).integral
                x += w + gap
            }
            rowFrames.append(CGRect(x: 0, y: y - rowGap / 2, width: bounds.width, height: rowH + rowGap))
        }
    }

    /// Letter key middles, for the swipe decoder.
    var letterCenters: [Character: CGPoint] {
        var out: [Character: CGPoint] = [:]
        for k in keys { if case .char(let s) = k.def.kind, let c = s.first, c.isLetter { out[c] = k.center } }
        return out
    }
    var unitWidth: CGFloat { keys.first(where: \.isChar)?.bounds.width ?? 32 }

    /// The key under a point: the row by height, then the nearest key in it, so the gaps type too.
    private func key(at p: CGPoint) -> KeyView? {
        let r: Int
        if let i = rowFrames.firstIndex(where: { p.y < $0.maxY }) { r = i } else { r = rowFrames.count - 1 }
        return keys.filter { $0.row == r }.min { abs($0.frame.midX - p.x) - $0.frame.width / 2 < abs($1.frame.midX - p.x) - $1.frame.width / 2 }
    }

    // MARK: touches

    private enum Mode { case tap, swipe, variants, trackpad, delete, done }
    private final class Track {
        var key: KeyView
        var mode: Mode = .tap
        var path: [CGPoint]
        var start: CGPoint
        var timer: Timer?
        var lastX: CGFloat
        var repeats = 0
        init(key: KeyView, at p: CGPoint) { self.key = key; path = [p]; start = p; lastX = p.x }
    }
    private var tracks: [UITouch: Track] = [:]
    private var popup: KeyPopup?
    private var lastShiftTap: Date?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // A new finger lands while another is still down: the earlier tap is meant, fire it now (rollover).
        for (t, tr) in tracks where tr.mode == .tap { fire(tr); tr.mode = .done; tracks[t] = tr }
        for t in touches {
            let p = t.location(in: self)
            guard let k = key(at: p) else { continue }
            let tr = Track(key: k, at: p)
            tracks[t] = tr
            delegate?.keyDown()
            k.pressed = true
            switch k.def.kind {
            case .char(let s):
                showPopup(for: k)
                if !variants(for: s).isEmpty {
                    tr.timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in self?.openVariants(tr) }
                }
            case .delete:
                tr.mode = .delete
                delegate?.tapped(.delete)
                tr.timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in self?.startRepeat(tr) }
            case .space:
                tr.timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
                    tr.mode = .trackpad
                    self?.keys.forEach { $0.dimmed = true }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            default: break
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            guard let tr = tracks[t] else { continue }
            let p = t.location(in: self)
            switch tr.mode {
            case .tap:
                tr.path.append(p)
                if swipeEnabled, page == .letters, tracks.count == 1, tr.key.isLetter,
                   p.distance(to: tr.start) > unitWidth * 0.9 {
                    tr.mode = .swipe
                    tr.path.forEach { trail.add($0) }
                    tr.timer?.invalidate()
                    hidePopup()
                    tr.key.pressed = false
                } else if tr.key.isChar, let k = key(at: p), k !== tr.key, k.isChar {
                    // Sliding a finger over to the right key, iOS style.
                    tr.key.pressed = false
                    tr.key = k
                    k.pressed = true
                    tr.timer?.invalidate()
                    showPopup(for: k)
                }
            case .swipe:
                tr.path.append(p)
                trail.add(p)
            case .variants:
                popup?.select(atX: t.location(in: popup).x)
            case .trackpad:
                let step: CGFloat = 9
                let d = Int((p.x - tr.lastX) / step)
                if d != 0 { delegate?.moveCursor(d); tr.lastX += CGFloat(d) * step }
            case .delete, .done: break
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            guard let tr = tracks.removeValue(forKey: t) else { continue }
            tr.timer?.invalidate()
            tr.key.pressed = false
            switch tr.mode {
            case .tap: fire(tr)
            case .swipe:
                // A hurried tap that slid reads as a swipe; with no word in it, it was a tap.
                if delegate?.swiped(tr.path) != true { fire(tr) }
                trail.end()
            case .variants:
                if let s = popup?.selected { delegate?.typed(s) }
            case .trackpad: keys.forEach { $0.dimmed = false }
            case .delete, .done: break
            }
            hidePopup()
        }
    }

    /// iOS cancels a touch when its edge gestures look at it (keys by the screen's sides
    /// and bottom). The finger still pressed the key, so finish it like a lift.
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    private func fire(_ tr: Track) {
        switch tr.key.def.kind {
        case .char(let s): delegate?.typed(shift == .off ? s : s.uppercased())
        case .shift:
            let now = Date()
            if let last = lastShiftTap, now.timeIntervalSince(last) < 0.3 { shift = .locked; lastShiftTap = nil }
            else { shift = shift == .off ? .once : .off; lastShiftTap = now }
            delegate?.shiftChanged()
        case .delete: break
        case let kind: delegate?.tapped(kind)
        }
    }

    private func startRepeat(_ tr: Track) {
        tr.timer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
            tr.repeats += 1
            // Past a second of holding, iOS goes word by word.
            self?.delegate?.deleteRepeat(words: tr.repeats > 12)
        }
    }

    // MARK: popups

    func showPopup(for k: KeyView) {
        hidePopup()
        guard popupsEnabled, let host = popupHost, case .char(let s) = k.def.kind else { return }
        let p = KeyPopup(text: shift == .off ? s : s.uppercased(), style: style, keyFrame: convert(k.frame, to: host), hostWidth: host.bounds.width)
        host.addSubview(p)
        popup = p
    }

    private func openVariants(_ tr: Track) {
        guard tr.mode == .tap, let host = popupHost, case .char(let s) = tr.key.def.kind else { return }
        let vs = variants(for: s)
        guard !vs.isEmpty else { return }
        hidePopup()
        tr.mode = .variants
        let up = shift != .off
        let p = KeyPopup(variants: vs.map { up ? $0.uppercased() : $0 }, style: style,
                         keyFrame: convert(tr.key.frame, to: host), hostWidth: host.bounds.width)
        host.addSubview(p)
        popup = p
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Long-press choices: the top row's digit first when the style shows hints, then the accents.
    private func variants(for s: String) -> [String] {
        let low = s.lowercased()
        let digit = style.numberHints && page == .letters ? Layout.digits[low].map { [$0] } ?? [] : []
        return digit + (Layout.variants[low] ?? [])
    }

    private func hidePopup() { popup?.removeFromSuperview(); popup = nil }

    /// Draws a trail that stays, for screenshots.
    func showTrail(_ path: [CGPoint]) { trail.freeze(path) }
}

// MARK: - keys

final class KeyView: UIView {
    let def: KeyDef
    let row: Int
    private let label = UILabel()
    private let hint = UILabel()
    private let icon = UIImageView()
    private var style: KeyStyle = .system(dark: false)
    private var shift: ShiftState = .off
    private var returnAccent = false

    var isChar: Bool { if case .char = def.kind { true } else { false } }
    var isLetter: Bool { if case .char(let s) = def.kind { s.first?.isLetter == true } else { false } }
    var pressed = false { didSet { paint() } }
    var dimmed = false { didSet { UIView.animate(withDuration: 0.15) { self.label.alpha = self.dimmed ? 0 : 1; self.icon.alpha = self.dimmed ? 0 : 1 } } }

    init(def: KeyDef, row: Int) {
        self.def = def
        self.row = row
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        icon.contentMode = .center
        addSubview(label)
        addSubview(hint)
        addSubview(icon)
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowRadius = 0
        layer.shadowOpacity = 1
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 4, dy: 0)
        hint.frame = CGRect(x: bounds.width - 12, y: 2, width: 10, height: 12)
        icon.frame = bounds
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: style.corner).cgPath
    }

    var isSpecial: Bool {
        switch def.kind {
        case .char, .space: false
        case .ret: !returnAccent
        default: true
        }
    }

    func apply(style: KeyStyle, shift: ShiftState, returnTitle: String, returnAccent: Bool, spaceTitle: String) {
        self.style = style
        self.shift = shift
        self.returnAccent = returnAccent
        label.text = nil
        hint.text = nil
        icon.image = nil
        let sym = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        func setIcon(_ name: String) { icon.image = UIImage(systemName: name, withConfiguration: sym) }
        switch def.kind {
        case .char(let s):
            label.text = shift == .off ? s : s.uppercased()
            label.font = style.uiFont(s.first!.isLetter ? 25 : 23)
            if style.numberHints, row == 0, let d = Layout.digits[s] {
                hint.text = d
                hint.font = style.uiFont(10)
                hint.textColor = style.text.ui.withAlphaComponent(0.55)
            }
        case .shift: setIcon(shift == .locked ? "capslock.fill" : shift == .once ? "shift.fill" : "shift")
        case .delete: setIcon("delete.left")
        case .globe: setIcon("globe")
        case .emoji: setIcon("face.smiling")
        case .otto: setIcon("sparkles")
        case .space: label.text = spaceTitle; label.font = style.uiFont(14); label.alpha = 0.55
        case .ret:
            switch returnTitle {
            case "return": setIcon("return.left")
            case "search": setIcon("magnifyingglass")
            case "go": setIcon("arrow.right")
            case "send": setIcon("arrow.up")
            default: label.text = returnTitle; label.font = style.uiFont(15, weight: .medium)
            }
        case .page(let p): label.text = p == .letters ? "ABC" : p == .numbers ? "123" : "#+="; label.font = style.uiFont(17)
        }
        let textColor = returnAccent && def.kind == .ret ? UIColor.white : style.text.ui
        label.textColor = textColor
        icon.tintColor = shift == .locked && def.kind == .shift ? style.accent.ui : textColor
        paint()
        setNeedsLayout()
    }

    private func paint() {
        let base: UIColor
        if def.kind == .ret, returnAccent { base = style.accent.ui }
        else if def.kind == .shift, shift != .off { base = style.key.ui }
        else { base = isSpecial ? style.specialKey.ui : style.key.ui }
        // Pressed: letters lighten (the popup carries them), specials swap to the key colour, like iOS.
        backgroundColor = pressed ? (isSpecial ? style.key.ui : base.withAlphaComponent(max(0.5, style.key.a * 0.7))) : base
        layer.cornerRadius = style.corner
        layer.shadowColor = style.shadow.ui.cgColor
        layer.borderWidth = style.keyBorder
        layer.borderColor = style.text.ui.withAlphaComponent(0.25).cgColor
    }
}

/// The balloon above a pressed key, or the strip of accents a long press opens.
final class KeyPopup: UIView {
    private var cells: [UILabel] = []
    private(set) var selected: String?
    private let style: KeyStyle

    /// The iOS balloon: a wider head above the key, flowing down into the key itself.
    init(text: String, style: KeyStyle, keyFrame: CGRect, hostWidth: CGFloat = .greatestFiniteMagnitude) {
        self.style = style
        // Nothing can draw above the keyboard's own view, so the top row's head gets the room there is.
        let headW = keyFrame.width * 1.55, headH = min(keyFrame.height * 1.15, max(30, keyFrame.minY - 7)), r = max(style.corner, 8)
        // Edge keys lean their head inward so it stays on screen, as iOS does.
        let headX = min(max(2, keyFrame.midX - headW / 2), hostWidth - headW - 2)
        let frame = CGRect(x: min(headX, keyFrame.minX), y: keyFrame.minY - headH - 6,
                           width: max(headX + headW, keyFrame.maxX) - min(headX, keyFrame.minX), height: headH + 6 + keyFrame.height)
        super.init(frame: frame)
        isUserInteractionEnabled = false
        let head = CGRect(x: headX - frame.minX, y: 0, width: headW, height: headH)
        let key = CGRect(x: keyFrame.minX - frame.minX, y: headH + 6, width: keyFrame.width, height: keyFrame.height)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: head.minX + r, y: head.minY))
        path.addLine(to: CGPoint(x: head.maxX - r, y: head.minY))
        path.addQuadCurve(to: CGPoint(x: head.maxX, y: head.minY + r), controlPoint: CGPoint(x: head.maxX, y: head.minY))
        path.addLine(to: CGPoint(x: head.maxX, y: head.maxY - r))
        // The neck: curve in from the head's side to the key's.
        path.addCurve(to: CGPoint(x: key.maxX, y: key.minY + 2), controlPoint1: CGPoint(x: head.maxX, y: head.maxY + 2),
                      controlPoint2: CGPoint(x: key.maxX, y: head.maxY))
        path.addLine(to: CGPoint(x: key.maxX, y: key.maxY - style.corner))
        path.addQuadCurve(to: CGPoint(x: key.maxX - style.corner, y: key.maxY), controlPoint: CGPoint(x: key.maxX, y: key.maxY))
        path.addLine(to: CGPoint(x: key.minX + style.corner, y: key.maxY))
        path.addQuadCurve(to: CGPoint(x: key.minX, y: key.maxY - style.corner), controlPoint: CGPoint(x: key.minX, y: key.maxY))
        path.addLine(to: CGPoint(x: key.minX, y: key.minY + 2))
        path.addCurve(to: CGPoint(x: head.minX, y: head.maxY - r), controlPoint1: CGPoint(x: key.minX, y: head.maxY),
                      controlPoint2: CGPoint(x: head.minX, y: head.maxY + 2))
        path.addLine(to: CGPoint(x: head.minX, y: head.minY + r))
        path.addQuadCurve(to: CGPoint(x: head.minX + r, y: head.minY), controlPoint: CGPoint(x: head.minX, y: head.minY))
        path.close()
        let shape = CAShapeLayer()
        shape.path = path.cgPath
        shape.fillColor = (style.key.a < 1 ? UIColor(white: 0.3, alpha: 0.97) : style.key.ui).cgColor
        shape.shadowColor = UIColor.black.cgColor
        shape.shadowOpacity = 0.22
        shape.shadowRadius = 5
        shape.shadowOffset = CGSize(width: 0, height: 1)
        shape.shadowPath = path.cgPath
        layer.addSublayer(shape)
        let l = UILabel(frame: head.offsetBy(dx: 0, dy: -2))
        l.text = text
        l.textAlignment = .center
        l.font = style.uiFont(min(36, headH * 0.75))
        l.textColor = style.text.ui
        addSubview(l)
    }

    init(variants: [String], style: KeyStyle, keyFrame: CGRect, hostWidth: CGFloat) {
        self.style = style
        let cw = keyFrame.width + 4, h = keyFrame.height + 10
        let w = cw * CGFloat(variants.count) + 8
        let x = min(max(4, keyFrame.midX - cw / 2 - 4), hostWidth - w - 4)
        super.init(frame: CGRect(x: x, y: keyFrame.minY - h - 6, width: w, height: h))
        decorate()
        for (i, v) in variants.enumerated() {
            let l = UILabel(frame: CGRect(x: 4 + CGFloat(i) * cw, y: 4, width: cw, height: h - 8))
            l.text = v
            l.textAlignment = .center
            l.font = style.uiFont(24)
            l.textColor = style.text.ui
            l.layer.cornerRadius = 6
            l.clipsToBounds = true
            addSubview(l)
            cells.append(l)
        }
        // The finger starts over the key, which sits under the first cell's side.
        select(atX: keyFrame.midX - x)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func decorate() {
        isUserInteractionEnabled = false
        // A see-through key would show the board through its balloon.
        backgroundColor = style.key.a < 1 ? UIColor(white: 0.3, alpha: 0.95) : style.key.ui
        layer.cornerRadius = style.corner + 4
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.28
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)
    }

    func select(atX x: CGFloat) {
        guard !cells.isEmpty else { return }
        let i = cells.firstIndex { x < $0.frame.maxX } ?? cells.count - 1
        for (j, c) in cells.enumerated() {
            c.backgroundColor = j == i ? style.accent.ui : .clear
            c.textColor = j == i ? .white : style.text.ui
        }
        selected = cells[i].text
    }
}
