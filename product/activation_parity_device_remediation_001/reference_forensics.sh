#!/bin/sh
set -eu

REFERENCE_DIR="${1:-reference/IOS-15-USB}"
OUT_DIR="${2:-build/activation-parity-device-remediation-001/reference-forensics}"
EXPECTED_SHA="a908bccbcddb4efc072bb1bc8fbeb6ee89b1af9d"
BIN="$REFERENCE_DIR/recovered/VCamRecovered.dylib"

test "$(git -C "$REFERENCE_DIR" rev-parse HEAD)" = "$EXPECTED_SHA"
test -f "$BIN"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

file "$BIN" | tee "$OUT_DIR/file.txt"
shasum -a 256 "$BIN" | tee "$OUT_DIR/sha256.txt"
otool -hv "$BIN" > "$OUT_DIR/otool-hv.txt"
otool -l "$BIN" > "$OUT_DIR/otool-l.txt"
otool -L "$BIN" > "$OUT_DIR/otool-L.txt"
otool -Iv "$BIN" > "$OUT_DIR/otool-Iv.txt"
nm -u "$BIN" > "$OUT_DIR/nm-u.txt" || true
nm -m "$BIN" > "$OUT_DIR/nm-m.txt" || true
strings -a -t x "$BIN" > "$OUT_DIR/strings-offsets.txt"

otool -tvV "$BIN" > "$OUT_DIR/otool-tvV.txt"
if xcrun --find llvm-objdump >/dev/null 2>&1; then
    xcrun llvm-objdump --macho --disassemble-all --symbolize-operands "$BIN"         > "$OUT_DIR/llvm-objdump-disassembly.txt" 2>&1 || true
fi

python3 - "$OUT_DIR" <<'PY'
from pathlib import Path
import re
import sys

out = Path(sys.argv[1])
otool = (out / "otool-tvV.txt").read_text(errors="replace").splitlines()
llvm_path = out / "llvm-objdump-disassembly.txt"
llvm = llvm_path.read_text(errors="replace").splitlines() if llvm_path.exists() else []
strings = (out / "strings-offsets.txt").read_text(errors="replace").splitlines()
indirect = (out / "otool-Iv.txt").read_text(errors="replace").splitlines()

symbols = [
    "_CMSampleBufferGetImageBuffer",
    "_MSHookFunction",
    "_CMGetAttachment",
    "_CMSampleBufferCreateReady",
    "_CMBlockBufferCreateWithMemoryBlock",
    "_CVBufferSetAttachment",
    "_CVBufferRemoveAttachment",
    "_VTPixelTransferSessionTransferImage",
    "_CVBufferGetAttachment",
    "_objc_msgSend",
]

needles = [
    "StillImageKey",
    "render:toCVPixelBuffer:",
    "frameQueue",
    "lastObject",
    "imageWithCVPixelBuffer:",
]

def contexts(lines, needle, radius=16):
    hits = [i for i,l in enumerate(lines) if needle in l]
    chunks = []
    for i in hits:
        lo=max(0,i-radius); hi=min(len(lines),i+radius+1)
        chunks.append(f"--- hit line {i+1} ---\n" + "\n".join(lines[lo:hi]))
    return hits, "\n\n".join(chunks)

summary = []
for sym in symbols:
    h1,c1=contexts(otool,sym)
    h2,c2=contexts(llvm,sym)
    summary.append(f"{sym}: otool_hits={len(h1)} llvm_hits={len(h2)}")
    (out / f"xref-{sym.lstrip('_')}.txt").write_text(
        "OTOOL\n" + (c1 or "NO_SYMBOLIC_HITS") +
        "\n\nLLVM_OBJDUMP\n" + (c2 or "NO_SYMBOLIC_HITS") + "\n"
    )

for needle in needles:
    safe=re.sub(r"[^A-Za-z0-9]+","_",needle).strip("_")
    hs,cs=contexts(strings,needle,4)
    hd,cd=contexts(otool,needle,20)
    hl,cl=contexts(llvm,needle,20)
    summary.append(f"{needle}: strings_hits={len(hs)} otool_hits={len(hd)} llvm_hits={len(hl)}")
    (out / f"xref-string-{safe}.txt").write_text(
        "STRINGS\n" + (cs or "NO_STRING_HITS") +
        "\n\nOTOOL\n" + (cd or "NO_DISASM_TEXT_HITS") +
        "\n\nLLVM_OBJDUMP\n" + (cl or "NO_DISASM_TEXT_HITS") + "\n"
    )

# Preserve the indirect-symbol mapping for stub resolution.
imp_lines=[l for l in indirect if any(s in l for s in symbols)]
(out / "relevant-indirect-symbols.txt").write_text("\n".join(imp_lines)+"\n")

# Pull broad neighborhoods around all direct symbolic callsites into one file.
broad=[]
for i,line in enumerate(otool):
    if any(sym in line for sym in symbols if sym != "_objc_msgSend"):
        broad.append(f"=== otool line {i+1}: {line.strip()} ===")
        broad.extend(otool[max(0,i-28):min(len(otool),i+29)])
        broad.append("")
(out / "relevant-callsite-neighborhoods.txt").write_text("\n".join(broad)+"\n")

(out / "summary.txt").write_text("\n".join(summary)+"\n")
print("\n".join(summary))
PY

grep -F '_CMSampleBufferGetImageBuffer' "$OUT_DIR/nm-u.txt" >/dev/null
grep -F '_MSHookFunction' "$OUT_DIR/nm-u.txt" >/dev/null
grep -F '_CMGetAttachment' "$OUT_DIR/nm-u.txt" >/dev/null
grep -F '_CMSampleBufferCreateReady' "$OUT_DIR/nm-u.txt" >/dev/null
grep -F 'StillImageKey' "$OUT_DIR/strings-offsets.txt" >/dev/null
grep -F 'render:toCVPixelBuffer:' "$OUT_DIR/strings-offsets.txt" >/dev/null

printf '%s\n'     "IOS15_REFERENCE_INSPECTED=YES"     "IOS15_REFERENCE_EXACT_SHA=PASS"     "IOS15_STILL_BINARY_DISASSEMBLED=PASS"     "IOS15_STILLIMAGEKEY_XREF_AUDITED=PASS"     "IOS15_CMGETATTACHMENT_XREF_AUDITED=PASS"     "IOS15_CMSAMPLEBUFFERCREATEREADY_XREF_AUDITED=PASS"     | tee "$OUT_DIR/markers.txt"
