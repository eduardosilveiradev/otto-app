#!/bin/bash
# The keyboard's tap zones (Layout.hit): every point of the board types a key, the nearest one; a touch well
# inside a drawn key is that key whatever the lean; the lean toward likely letters moves a boundary by at most
# half of Layout.zoneBias. Runs OttoKeyboard/Layout.swift as a plain Swift script (no simulator).
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d)/check.swift
{ cat OttoKeyboard/Layout.swift
  cat <<'SWIFT'
// The letters page on a 402pt-wide board, laid out the way KeyboardView.layoutSubviews does it.
let W: CGFloat = 402, H: CGFloat = 216, gap: CGFloat = 6, rowGap: CGFloat = 11, side: CGFloat = 3, top: CGFloat = 8
let defs = Layout.rows(.letters, showGlobe: false)
let rowH = (H - top - 4 - rowGap * CGFloat(defs.count - 1)) / CGFloat(defs.count)
let unit = (W - 2 * side - 9 * gap) / 10
func isChar(_ d: KeyDef) -> Bool { if case .char = d.kind { true } else { false } }
var rows: [[CGRect]] = []
for (r, row) in defs.enumerated() {
    let y = top + CGFloat(r) * (rowH + rowGap)
    let charW = row.filter(isChar).reduce(0) { $0 + $1.width * unit }
    let specials = row.filter { !isChar($0) }
    let free = W - 2 * side - gap * CGFloat(row.count - 1) - charW
    let specialUnits = specials.reduce(0) { $0 + $1.width }
    var x = specials.isEmpty ? (W - charW - gap * CGFloat(row.count - 1)) / 2 : side
    rows.append(row.map { d in
        let w = isChar(d) ? d.width * unit : free * d.width / specialUnits
        defer { x += w + gap }
        return CGRect(x: x, y: y, width: w, height: rowH).integral
    })
}
func name(_ h: (row: Int, key: Int)?) -> String {
    guard let h else { return "nil" }
    switch defs[h.row][h.key].kind { case .char(let s): return s; case .page: return "123"; case let k: return "\(k)" }
}
func at(_ x: CGFloat, _ y: CGFloat, _ likely: [[CGFloat]] = []) -> String { name(Layout.hit(CGPoint(x: x, y: y), rows: rows, likely: likely)) }
func lean(_ letters: [String: CGFloat]) -> [[CGFloat]] {
    defs.map { $0.map { if case .char(let s) = $0.kind { letters[s] ?? 0 } else { 0 } } }
}
func expect(_ got: String, _ want: String, _ why: String) { precondition(got == want, "\(why): got \(got), want \(want)") }

// Every point resolves, edges and the strips above and below included.
for y in stride(from: CGFloat(0), through: H, by: 1) { for x in stride(from: CGFloat(0), through: W, by: 1) {
    precondition(Layout.hit(CGPoint(x: x, y: y), rows: rows) != nil, "dead point \(x),\(y)")
} }

// Layer 1: the nearest key.
let q = rows[0][0], w = rows[0][1], a = rows[1][0], l = rows[1][8]
expect(at((q.maxX + w.minX) / 2 - 0.5, q.midY), "q", "the q|w gap splits at its middle (left half)")
expect(at((q.maxX + w.minX) / 2 + 0.5, q.midY), "w", "the q|w gap splits at its middle (right half)")
expect(at(0, q.midY), "q", "left screen edge")
expect(at(W, q.midY), "p", "right screen edge")
expect(at(1, a.midY), "a", "the a-l row's left margin belongs to a")
expect(at(W - 1, l.midY), "l", "the a-l row's right margin belongs to l")
expect(at(1, (q.maxY + a.minY) / 2 + 1), "a", "a's margin, just under the row boundary, is still a's")
expect(at(w.midX, 0), "w", "above the top row")
expect(at(W / 2, H), "space", "below the bottom row")
expect(at(1, rows[2][0].midY), "shift", "shift reaches the left edge")
expect(at(W - 1, rows[2].last!.midY), "delete", "delete reaches the right edge")
expect(at(0, H), "123", "123 reaches the bottom-left corner")
expect(at(W, H), "ret", "return reaches the bottom-right corner")
expect(at(w.midX, (w.maxY + rows[1][1].minY) / 2 - 0.5), "w", "the row gap splits at its middle (upper half)")

// Layer 2: the lean.
let toE = lean(["e": 1])
let we = (w.maxX + rows[0][2].minX) / 2
expect(at(we - 2, w.midY), "w", "no lean: left of the w|e middle is w")
expect(at(we - 2, w.midY, toE), "e", "a likely e takes the w|e gap past its middle")
expect(at(w.maxX - Layout.sureInset - 0.5, w.midY, toE), "w", "well inside w stays w, however likely e is")
// The bound: with any lean, the boundary moves at most zoneBias/2 from the gap's middle.
var seed: UInt64 = 1
func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 40) / CGFloat(1 << 24) }
for _ in 0..<200 {
    let likely = defs.map { $0.map { _ in rnd() } }
    for (r, row) in rows.enumerated() {
        for (k, f) in row.enumerated() {
            let p = CGPoint(x: f.midX + (rnd() - 0.5) * (f.width - 2 * Layout.sureInset), y: f.midY + (rnd() - 0.5) * (f.height - 2 * Layout.sureInset))
            precondition(Layout.hit(p, rows: rows, likely: likely)! == (r, k), "a point well inside a key moved")
            if k + 1 < row.count {
                let mid = (f.maxX + row[k + 1].minX) / 2, reach = Layout.zoneBias / 2 + 0.01
                precondition(Layout.hit(CGPoint(x: mid - reach, y: f.midY), rows: rows, likely: likely)! == (r, k), "lean moved a boundary too far")
                precondition(Layout.hit(CGPoint(x: mid + reach, y: f.midY), rows: rows, likely: likely)! == (r, k + 1), "lean moved a boundary too far")
            }
        }
    }
}
print("keyboard zones ok")
SWIFT
} > "$T"
swift "$T"
