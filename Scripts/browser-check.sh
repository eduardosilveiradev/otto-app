#!/bin/bash
# The live browser tile's frame (otto-core's browsertile.ts) decodes as the server sends it: a numeric
# ts, a JPEG data URL or null, and {"done":true}. A picture that won't decode keeps the caption;
# anything else is no browser frame at all. Runs BrowserFrame from Backend.swift as a plain script.
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d)/check.swift
{ echo 'import Foundation'
  sed -n '/^struct BrowserTile:/,/^}/p' Otto/Backend.swift
  sed -n '/^enum BrowserFrame:/,/^}/p' Otto/Backend.swift
  cat <<'SWIFT'
func f(_ s: String) -> BrowserFrame? { BrowserFrame(json: Data(s.utf8)) }
// a tiny JPEG's first bytes, as the server would send them
let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
let full = f(#"{"type":"browser","image":"data:image/jpeg;base64,\#(jpeg.base64EncodedString())","caption":"example.com · clicks Generate","url":"https://example.com/studio","ts":1794500000000}"#)
assert(full?.tile == BrowserTile(image: jpeg, caption: "example.com · clicks Generate", url: "https://example.com/studio", ts: 1794500000000))
// no picture: caption only, nothing kept from before
let bare = f(#"{"type":"browser","image":null,"caption":"accounts.example.com · signing in","url":"https://accounts.example.com/login","ts":1}"#)?.tile
assert(bare?.image == nil && bare?.caption == "accounts.example.com · signing in")
// a broken or non-image data URL still shows the caption
assert(f(#"{"type":"browser","image":"data:image/jpeg;base64,!!!not base64","caption":"a · b","url":"","ts":2}"#)?.tile?.image == nil)
assert(f(#"{"type":"browser","image":"https://example.com/x.jpg","caption":"a · b","url":"","ts":2}"#)?.tile?.caption == "a · b")
assert(f(#"{"type":"browser","image":"data:image/jpeg;base64,\#(jpeg.base64EncodedString())","caption":"a · b"}"#)?.tile?.ts == 0)
// the end of the tile
assert(f(#"{"type":"browser","done":true}"#) == .done)
assert(f(#"{"type":"browser","done":true}"#)?.tile == nil)
// not a tile: another frame, no caption, garbage
assert(f(#"{"type":"todos","items":[]}"#) == nil)
assert(f(#"{"type":"browser","image":null,"ts":1}"#) == nil)
assert(f(#"{"type":"browser","caption":7}"#) == nil)
assert(f("garbage") == nil)
print("browser frame decode ok")
SWIFT
} > "$T"
swift "$T"
