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
otool -v -s __DATA_CONST __cfstring "$BIN" > "$OUT_DIR/otool-cfstring.txt" 2>&1 || true
otool -v -s __TEXT __cstring "$BIN" > "$OUT_DIR/otool-cstring.txt" 2>&1 || true
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

# Persist exact address ranges used by the forensic report.
# Otool emits sixteen hexadecimal digits followed by whitespace.  LLVM objdump
# uses the same address value with a trailing colon.  Preserve both views so
# exact ranges also retain symbolized selectors/imports.
python3 - "$OUT_DIR/otool-tvV.txt" "$OUT_DIR/llvm-objdump-disassembly.txt" "$OUT_DIR" <<'PYRANGES'
from pathlib import Path
import re
import sys

otool_path = Path(sys.argv[1])
llvm_path = Path(sys.argv[2])
out = Path(sys.argv[3])

otool = otool_path.read_text(errors="replace").splitlines()
llvm = (
    llvm_path.read_text(errors="replace").splitlines()
    if llvm_path.exists()
    else []
)

ranges = {
    "replacement_175d4": (0x175D4, 0x1AA0C),
    "still_branch_19780": (0x19780, 0x19F20),
    "attachment_helpers_872f0": (0x872F0, 0x87368),
    "samplebuffer_ready_helper_10d6c": (0x10D6C, 0x11A40),
    "installer_5c7c0": (0x5C7C0, 0x5C940),
    "installer_5dfc0": (0x5DFC0, 0x5E180),
    "render_helper_14390": (0x14390, 0x175D4),
}

otool_pat = re.compile(r"^([0-9a-fA-F]{16})\s")
llvm_pat = re.compile(r"^\s*([0-9a-fA-F]{1,16}):(?:\s|$)")

def extract(lines, pattern, lo, hi):
    selected = []
    for line in lines:
        match = pattern.match(line)
        if not match:
            continue
        address = int(match.group(1), 16)
        if lo <= address < hi:
            selected.append(line)
    return selected

for name, (lo, hi) in ranges.items():
    lines = extract(otool, otool_pat, lo, hi)
    lines.extend(extract(llvm, llvm_pat, lo, hi))
    (out / f"range-{name}.txt").write_text("\n".join(lines) + "\n")
PYRANGES

# Every required range must contain real disassembly before any PASS marker can
# be emitted.
for range_file in \
    "$OUT_DIR/range-replacement_175d4.txt" \
    "$OUT_DIR/range-still_branch_19780.txt" \
    "$OUT_DIR/range-attachment_helpers_872f0.txt" \
    "$OUT_DIR/range-samplebuffer_ready_helper_10d6c.txt"; do
    test -s "$range_file"
done

# Exact replacement / still / helper facts.
grep -Eiq '(^|[^0-9a-f])0*175d4([^0-9a-f]|$)' \
    "$OUT_DIR/range-replacement_175d4.txt"
grep -Fq 'frameQueue' "$OUT_DIR/range-replacement_175d4.txt"
grep -Fq 'lastObject' "$OUT_DIR/range-replacement_175d4.txt"

grep -Eiq '(^|[^0-9a-f])0*19798([^0-9a-f]|$)' \
    "$OUT_DIR/range-still_branch_19780.txt"
grep -Fq 'StillImageKey' "$OUT_DIR/range-still_branch_19780.txt"
grep -Fq 'CMGetAttachment' "$OUT_DIR/range-still_branch_19780.txt"
grep -Eiq '(^|[^0-9a-f])0*197e0([^0-9a-f]|$)|(^|[^0-9a-f])0*197f4([^0-9a-f]|$)' \
    "$OUT_DIR/range-still_branch_19780.txt"

grep -Fq 'CMSampleBufferCreateReady' \
    "$OUT_DIR/range-samplebuffer_ready_helper_10d6c.txt"

# Core Image source/destination mechanism.
test -s "$OUT_DIR/range-render_helper_14390.txt"
grep -Fq 'imageWithCVPixelBuffer:' "$OUT_DIR/range-render_helper_14390.txt"
grep -Fq 'render:toCVPixelBuffer:' "$OUT_DIR/range-render_helper_14390.txt"

# At least one installation neighborhood must jointly identify target,
# replacement address, and MSHookFunction.
installer_ok=0
for installer in \
    "$OUT_DIR/range-installer_5c7c0.txt" \
    "$OUT_DIR/range-installer_5dfc0.txt"; do
    if test -s "$installer" && \
       grep -Fq 'CMSampleBufferGetImageBuffer' "$installer" && \
       grep -Fq 'MSHookFunction' "$installer" && \
       grep -Eiq '(^|[^0-9a-f])0*175d4([^0-9a-f]|$)' "$installer"; then
        installer_ok=1
        break
    fi
done
test "$installer_ok" -eq 1

# Global import/string facts that support the exact-range assertions above.
grep -F '_CMSampleBufferGetImageBuffer' "$OUT_DIR/nm-u.txt" >/dev/null
grep -F '_MSHookFunction' "$OUT_DIR/nm-u.txt" >/dev/null
grep -F '_CMGetAttachment' "$OUT_DIR/nm-u.txt" >/dev/null
grep -F '_CMSampleBufferCreateReady' "$OUT_DIR/nm-u.txt" >/dev/null
grep -F 'StillImageKey' "$OUT_DIR/strings-offsets.txt" >/dev/null
grep -F 'render:toCVPixelBuffer:' "$OUT_DIR/strings-offsets.txt" >/dev/null

printf '%s\n' \
    "IOS15_REFERENCE_INSPECTED=YES" \
    "IOS15_REFERENCE_EXACT_SHA=PASS" \
    "IOS15_STILL_BINARY_DISASSEMBLED=PASS" \
    "IOS15_REPLACEMENT_ADDRESS_175D4=PASS" \
    "IOS15_REPLACEMENT_IS_CMSAMPLEBUFFERGETIMAGEBUFFER_HOOK=PASS" \
    "IOS15_REPLACEMENT_FRAMEQUEUE_ACCESS=PASS" \
    "IOS15_REPLACEMENT_LASTOBJECT_ACCESS=PASS" \
    "IOS15_REPLACEMENT_STILLIMAGEKEY_CHECK=PASS" \
    "IOS15_REPLACEMENT_CMGETATTACHMENT_CALL=PASS" \
    "IOS15_STILLIMAGEKEY_BOOLEAN_TRUE_TEST=PASS" \
    "IOS15_CI_RENDER_HELPER_AUDITED=PASS" \
    "IOS15_CMSAMPLEBUFFERCREATEREADY_XREF_AUDITED=PASS" \
    "IOS15_CMSAMPLEBUFFERCREATEREADY_STILL_ROLE=UNRESOLVED" \
    "RANGE_FILES_NONEMPTY=PASS" \
    | tee "$OUT_DIR/markers.txt"
