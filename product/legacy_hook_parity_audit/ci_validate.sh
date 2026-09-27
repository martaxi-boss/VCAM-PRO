#!/bin/sh
set -eu

BASE=ade6887fa6214ac1cd26b56f13e0d4f64e07e1d4
REFERENCE_SHA=a908bccbcddb4efc072bb1bc8fbeb6ee89b1af9d
PR19=2475bd51953b536c32d12e37475fd32eaf7c4a67
AUDIT_DIR=product/legacy_hook_parity_audit
BUILD=build/legacy-hook-parity-audit-001
REF="$BUILD/IOS-15-USB"

rm -rf "$BUILD"
mkdir -p "$BUILD"

test "$(git merge-base "$BASE" HEAD)" = "$BASE"

changed="$(git diff --name-only "$BASE"..HEAD)"
printf '%s
' "$changed" | while IFS= read -r path; do
    test -n "$path" || continue
    case "$path" in
        product/legacy_hook_parity_audit/*|.github/workflows/legacy-hook-structural-parity-audit-ci.yml)
            ;;
        *)
            echo "Unauthorized audit mutation: $path"
            exit 1
            ;;
    esac
done

git diff --quiet "$BASE"..HEAD -- src
git diff --quiet "$BASE"..HEAD -- src/product/ReferenceCameraHook.mm
git diff --quiet "$BASE"..HEAD -- src/product/MediaserverdRuntime.mm
git diff --quiet "$BASE"..HEAD -- src/product/VCAMProEntry.mm

test "$(git ls-remote origin refs/pull/19/head | awk '{print $1}')" = "$PR19"
test "$(git ls-remote https://github.com/martaxi-boss/IOS-15-USB.git refs/heads/main | awk '{print $1}')" = "$REFERENCE_SHA"

git clone --quiet https://github.com/martaxi-boss/IOS-15-USB.git "$REF"
git -C "$REF" checkout --quiet "$REFERENCE_SHA"
test "$(git -C "$REF" rev-parse HEAD)" = "$REFERENCE_SHA"

UNDEF="$REF/analysis/symbols/VCamRecovered.undefined-symbols.txt"
STRINGS="$REF/analysis/strings/VCamRecovered.strings.txt"
DISASM="$REF/analysis/disassembly/VCamRecovered.disassembly.txt"
PLIST="$REF/recovered/VCamRecovered.plist"
AUDIT="$REF/AUDIT.md"

grep -Eq '[[:space:]]_MSHookFunction$' "$UNDEF"
grep -Eq '[[:space:]]_CMSampleBufferGetImageBuffer$' "$UNDEF"
grep -Fq '[VCam] Hooking CMSampleBufferGetImageBuffer' "$STRINGS"
grep -Fq '"mediaserverd"' "$PLIST"
grep -Fq '"com.apple.mediaserverd"' "$PLIST"
! grep -Eq '[[:space:]]_dlsym$' "$UNDEF"

python3 - "$DISASM" <<'PY'
from pathlib import Path
import sys

lines = Path(sys.argv[1]).read_text(errors="replace").splitlines()
provider_calls = [
    i for i, line in enumerate(lines)
    if "symbol stub for: _MSHookFunction" in line
]
if len(provider_calls) < 1:
    raise SystemExit("No direct MSHookFunction call site found")

qualified = []
for i in provider_calls:
    window = "\n".join(lines[max(0, i - 12): i + 2])
    if "literal pool symbol address: _CMSampleBufferGetImageBuffer" in window:
        qualified.append(i)

if len(qualified) != len(provider_calls):
    raise SystemExit("A provider call was not statically paired with CMSampleBufferGetImageBuffer")

marker_sites = [
    i for i, line in enumerate(lines)
    if '[VCam] Hooking CMSampleBufferGetImageBuffer' in line
]
if not marker_sites:
    raise SystemExit("Legacy hook marker missing in disassembly")

# Both recovered call sites observed in the frozen binary use the same x1 code
# address and x2 writable-data address immediately before MSHookFunction.
# This supports structural inference only; stripped local semantic names remain unknown.
contexts = ["\n".join(lines[max(0, i - 8): i + 1]) for i in provider_calls]
for ctx in contexts:
    if "add	x1, x1, #0x5d4" not in ctx:
        raise SystemExit("Legacy replacement-address pattern changed")
    if "add	x2, x2, #0x500" not in ctx:
        raise SystemExit("Legacy original-storage address pattern changed")

print(f"LEGACY_MSHOOKFUNCTION_CALL_SITES={len(provider_calls)}")
print("LEGACY_PROVIDER_TARGET_RELATION=PROVEN")
print("LEGACY_REPLACEMENT_CONCEPT=INFERRED")
print("LEGACY_ORIGINAL_TRAMPOLINE_CONCEPT=INFERRED")
print("LEGACY_CONSTRUCTOR_CONTEXT=NOT_DETERMINABLE")
PY

grep -Fq 'thin **Mach-O 64-bit arm64 dynamically linked shared library**' "$AUDIT"
grep -Fq 'minimum OS: **14.0**' "$AUDIT"
grep -Fq '/var/jb/Library/MobileSubstrate/DynamicLibraries/VCamRecovered.dylib' "$AUDIT"
grep -Fq 'GET /vcam.mjpg HTTP/1.1' "$STRINGS"
grep -Fq 'OBS PC IP' "$STRINGS"

HOOK=src/product/ReferenceCameraHook.mm
ENTRY=src/product/VCAMProEntry.mm

for token in     'CMSampleBufferGetImageBuffer'     'HookedCMSampleBufferGetImageBuffer'     'gOriginalCMSampleBufferGetImageBuffer'     'extern "C" void MSHookFunction'     'MSHookFunction('     'gOriginalCMSampleBufferGetImageBuffer !='     'nullptr'; do
    grep -Fq "$token" "$HOOK"
done

grep -Fq 'ProcessIs("mediaserverd")' "$ENTRY"
grep -Fq 'runtime.start()' "$ENTRY"
grep -Fq 'InstallReferenceCameraHook()' "$ENTRY"

python3 - "$ENTRY" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
guard = text.index('ProcessIs("mediaserverd")')
start = text.index("runtime.start()", guard)
install = text.index("InstallReferenceCameraHook()", start)
if not (guard < start < install):
    raise SystemExit("VCAM-PRO mediaserverd startup/call relationship changed")
PY

SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
CXX="$(xcrun --sdk iphoneos -f clang++)"
COMMON="-std=c++17 -O0 -fno-lto -arch arm64 -isysroot $SDKROOT -miphoneos-version-min=15.0 -Wall -Wextra -Werror -Werror=unguarded-availability-new -pedantic"

"$CXX" $COMMON     -Isrc/frame_engine -Isrc/media_engine -Isrc/product     -c src/product/ReferenceCameraHook.mm     -o "$BUILD/ReferenceCameraHook.compile-only.o"

xcrun lipo -info "$BUILD/ReferenceCameraHook.compile-only.o" | tee "$BUILD/compile-arch.txt"
grep -q 'arm64' "$BUILD/compile-arch.txt"

xcrun otool -l "$BUILD/ReferenceCameraHook.compile-only.o" | tee "$BUILD/compile-load-commands.txt"
grep -q 'minos 15.0' "$BUILD/compile-load-commands.txt"

xcrun nm -u "$BUILD/ReferenceCameraHook.compile-only.o" | tee "$BUILD/compile-undefined.txt"
grep -q '_MSHookFunction' "$BUILD/compile-undefined.txt"
grep -q '_CMSampleBufferGetImageBuffer' "$BUILD/compile-undefined.txt"

cat > "$BUILD/parity-matrix.tsv" <<'EOF'
dimension	legacy_classification	vcampro_classification	assessment
mediaserverd_targeting	PROVEN	PROVEN	MATCH
MSHookFunction_usage	PROVEN_DIRECT_IMPORT	PROVEN_DIRECT_CALL	MATCH
CMSampleBufferGetImageBuffer_target	PROVEN	PROVEN	MATCH
replacement_function_concept	INFERRED	PROVEN	STRUCTURAL_MATCH
original_trampoline_concept	INFERRED	PROVEN	STRUCTURAL_MATCH
startup_load_topology	MEDIASERVERD_PROVEN_EXACT_CONSTRUCTOR_NOT_DETERMINABLE	PROVEN	COMPATIBLE
arm64_compatibility	PROVEN	PROVEN_COMPILE_ONLY	MATCH
rootless_layout	VAR_JB_MOBILESUBSTRATE	ROOTHIDE_TWEAKINJECT	ADAPTATION_NOT_HOOK_DIVERGENCE
ios15_compatibility	MIN_IOS_14_STATIC	MIN_IOS_15_COMPILE_ONLY	COMPATIBLE_STATIC
fail_open	NOT_DETERMINABLE	EXPLICIT_SOURCE_CONTRACT	VCAMPRO_MORE_EXPLICIT
media_source	EXTERNAL_MJPEG_OBS_PC_EVIDENCE	LOCAL_GALLERY	PLANNED_PRODUCT_ADAPTATION
EOF

cat > "$BUILD/evidence.txt" <<EOF
IOS15USB_REFERENCE_SHA=$REFERENCE_SHA
IOS15USB_REFERENCE_SHA_CONFIRMED=PASS
IOS15USB_MSHOOKFUNCTION_IMPORT_CONFIRMED=PASS
IOS15USB_CMSAMPLEBUFFER_TARGET_CONFIRMED=PASS
IOS15USB_HOOK_MARKER_CONFIRMED=PASS
IOS15USB_MEDIASERVERD_FILTER_CONFIRMED=PASS
LEGACY_PROVIDER_IMPORT_MODEL=PROVEN_DIRECT_IMPORT
LEGACY_PROVIDER_TARGET_RELATION=PROVEN
LEGACY_REPLACEMENT_FUNCTION_CONCEPT=INFERRED
LEGACY_ORIGINAL_TRAMPOLINE_CONCEPT=INFERRED
LEGACY_CONSTRUCTOR_STARTUP_CONTEXT=NOT_DETERMINABLE
VCAMPRO_REFERENCE_HOOK_SOURCE_UNCHANGED=PASS
VCAMPRO_MSHOOKFUNCTION_MODEL_CONFIRMED=PASS
VCAMPRO_CMSAMPLEBUFFER_TARGET_CONFIRMED=PASS
VCAMPRO_ORIGINAL_TRAMPOLINE_CONTRACT_CONFIRMED=PASS
VCAMPRO_MEDIASERVERD_CALL_PATH_CONFIRMED=PASS
REFERENCE_CAMERA_HOOK_COMPILE_ONLY=PASS
LEGACY_STRUCTURAL_PARITY=CONFIRMED
RUNTIME_HOOK_INSTALLATION=NOT_PERFORMED
CAMERA_INTERCEPTION=NOT_PERFORMED
FRAME_ACCESS=NOT_PERFORMED
FRAME_SUBSTITUTION=NOT_PERFORMED
DUMMY_SELFTEST_DEVELOPMENT=STOPPED
PR19_MODIFIED=NO
REFERENCE_REPOS_MODIFIED=NO
MERGE_PERFORMED=NO
RELEASE_PERFORMED=NO
DEPLOY_PERFORMED=NO
DEVICE_ACTION=NO
EOF

cat "$BUILD/evidence.txt"
cat "$BUILD/parity-matrix.tsv"
