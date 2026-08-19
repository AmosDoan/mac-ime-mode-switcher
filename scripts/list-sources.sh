#!/bin/bash
# Prints every keyboard input source with its ID, whether it is selectable,
# and whether it is currently enabled. Use this to find IDs for Config in main.swift.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
cat > "$TMP/list.swift" <<'EOF'
import Carbon
func s(_ src: TISInputSource, _ k: CFString) -> String {
  guard let p = TISGetInputSourceProperty(src, k) else { return "" }
  return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
}
func b(_ src: TISInputSource, _ k: CFString) -> Bool {
  guard let p = TISGetInputSourceProperty(src, k) else { return false }
  return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(p).takeUnretainedValue())
}
let list = TISCreateInputSourceList(nil, true)!.takeRetainedValue() as! [TISInputSource]
for src in list {
  guard s(src, kTISPropertyInputSourceCategory) == (kTISCategoryKeyboardInputSource as String) else { continue }
  let sel = b(src, kTISPropertyInputSourceIsSelectCapable)
  let en = b(src, kTISPropertyInputSourceIsEnabled)
  print("\(sel ? "SEL":"   ") \(en ? "ON ":"off") | \(s(src, kTISPropertyInputSourceID))")
}
EOF
swiftc "$TMP/list.swift" -o "$TMP/list"
"$TMP/list"
rm -rf "$TMP"
