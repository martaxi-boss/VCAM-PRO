#!/bin/sh
set -eu

BASE=ade6887fa6214ac1cd26b56f13e0d4f64e07e1d4
REFERENCE_SHA=a908bccbcddb4efc072bb1bc8fbeb6ee89b1af9d
PR19=2475bd51953b536c32d12e37475fd32eaf7c4a67
HOOK_BLOB=b3b5360757d17951b0c508ab455d7ea4ffb0d6fe
BUILD=build/legacy-hook-parity-audit-001
REF="$BUILD/IOS-15-USB"

rm -rf "$BUILD"
mkdir -p "$BUILD"

test "$(git merge-base "$BASE" HEAD)" = "$BASE"

changed="$(git diff --name-only "$BASE"..HEAD)"
printf '%s\n' "$changed" | while IFS= read -r path; do
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
git diff --quiet "$BASE"..HEAD -- product/hook_installation_readiness_gate
git diff --quiet "$BASE"..HEAD -- product/hook_reachability_gate
git diff --quiet "$BASE"..HEAD -- product/runtime_gate
git diff --quiet "$BASE"..HEAD -- proofs/mediaserverd_load_probe
git diff --quiet "$BASE"..HEAD -- product/roothide_integration
git diff --quiet "$BASE"..HEAD -- product/build_roothide_integration_input.sh
git diff --quiet "$BASE"..HEAD -- product/VCAMPro.RootHideIntegration.plist

test ! -e product/hook_provider_self_test_gate

test "$(git rev-parse "$BASE:src/product/ReferenceCameraHook.mm")" = "$HOOK_BLOB"
test "$(git hash-object src/product/ReferenceCameraHook.mm)" = "$HOOK_BLOB"

test "$(git ls-remote origin refs/pull/19/head | awk '{print $1}')" = "$PR19"
test "$(git ls-remote https://github.com/martaxi-boss/IOS-15-USB.git refs/heads/main | awk '{print $1}')" = "$REFERENCE_SHA"

git init -q "$REF"
git -C "$REF" remote add origin https://github.com/martaxi-boss/IOS-15-USB.git
git -C "$REF" fetch -q --depth 1 origin "$REFERENCE_SHA"
git -C "$REF" checkout -q --detach FETCH_HEAD
test "$(git -C "$REF" rev-parse HEAD)" = "$REFERENCE_SHA"

UNDEF="$REF/analysis/symbols/VCamRecovered.undefined-symbols.txt"
STRINGS="$REF/analysis/strings/VCamRecovered.strings.txt"
DISASM="$REF/analysis/disassembly/VCamRecovered.disassembly.txt"
PLIST="$REF/recovered/VCamRecovered.plist"
AUDIT="$REF/AUDIT.md"
LOAD="$REF/analysis/macho/VCamRecovered.otool-l.txt"
FILEINFO="$REF/analysis/macho/VCamRecovered.file.txt"

grep -Eq '[[:space:]]_MSHookFunction$' "$UNDEF"
grep -Eq '[[:space:]]_CMSampleBufferGetImageBuffer$' "$UNDEF"
! grep -Eq '[[:space:]]_dlsym$' "$UNDEF"
grep -Fq '[VCam] Hooking CMSampleBufferGetImageBuffer' "$STRINGS"
grep -Fq '"mediaserverd"' "$PLIST"
grep -Fq '"com.apple.mediaserverd"' "$PLIST"
grep -Fq 'Mach-O 64-bit arm64' "$FILEINFO"
grep -Fq 'minos 14.0' "$LOAD"
grep -Fq 'sdk 16.4' "$LOAD"
grep -Fq '__mod_init_func' "$LOAD"
grep -Fq '/var/jb/Library/MobileSubstrate/DynamicLibraries/VCamRecovered.dylib' "$AUDIT"
grep -Fq 'GET /vcam.mjpg HTTP/1.1' "$STRINGS"
grep -Fq 'OBS PC IP' "$STRINGS"
grep -Fq 'wifi_ip' "$STRINGS"

python3 - "$DISASM" <<'PY'
from pathlib import Path
import sys

lines = Path(sys.argv[1]).read_text(errors="replace").splitlines()

provider_calls = [
    i for i, line in enumerate(lines)
    if "symbol stub for: _MSHookFunction" in line
]
if len(provider_calls) != 2:
    raise SystemExit(f"Unexpected MSHookFunction call-site count: {len(provider_calls)}")

for i in provider_calls:
    window = "\n".join(lines[max(0, i - 16): i + 2])
    if "literal pool symbol address: _CMSampleBufferGetImageBuffer" not in window:
        raise SystemExit("Provider call not paired with CMSampleBufferGetImageBuffer")
    if "add\tx1, x1, #0x5d4" not in window:
        raise SystemExit("Legacy replacement-address pattern changed")
    if "add\tx2, x2, #0x500" not in window:
        raise SystemExit("Legacy original-storage address pattern changed")

marker_sites = [
    i for i, line in enumerate(lines)
    if '[VCam] Hooking CMSampleBufferGetImageBuffer' in line
]
if not marker_sites:
    raise SystemExit("Legacy hook marker missing in disassembly")

first = provider_calls[0]
if not any(abs(first - marker) < 40 for marker in marker_sites):
    raise SystemExit("Legacy hook marker not structurally adjacent to provider call")

if not any(line.lstrip().startswith("175d4:") for line in lines):
    raise SystemExit("Legacy replacement function entry 0x175d4 missing")

trampoline_calls = []
for i, line in enumerate(lines):
    if "ldr\tx8, [x8, #0x500]" not in line:
        continue
    window = "\n".join(lines[max(0, i - 3): min(len(lines), i + 5)])
    if "0xa9000" in window and "blr\tx8" in window:
        trampoline_calls.append(i)

if len(trampoline_calls) < 2:
    raise SystemExit("Legacy original trampoline storage/call pattern missing")

print("LEGACY_MSHOOKFUNCTION_CALL_SITES=2")
print("LEGACY_PROVIDER_TARGET_RELATION=PROVEN")
print("LEGACY_REPLACEMENT_FUNCTION_CONCEPT=PROVEN")
print("LEGACY_ORIGINAL_TRAMPOLINE_CONCEPT=PROVEN")
print("LEGACY_CONSTRUCTOR_STARTUP_CONTEXT=NOT_DETERMINABLE")
print("LEGACY_PROVIDER_IMPORT_MODEL=PROVEN_DIRECT_IMPORT")
print("LEGACY_PROVIDER_RUNTIME_DLSYM=NOT_OBSERVED")
PY

HOOK=src/product/ReferenceCameraHook.mm
ENTRY=src/product/VCAMProEntry.mm
ADAPTER=src/product/CameraConsumerAdapter.cpp
GALLERY=src/media_engine/InternalGalleryMediaSession.mm
READY_AUDIT=product/hook_installation_readiness_gate/ci_build_package_and_audit.sh

python3 - "$HOOK" "$ENTRY" "$ADAPTER" "$GALLERY" "$READY_AUDIT" <<'PY'
from pathlib import Path
import re
import sys

hook = Path(sys.argv[1]).read_text()
entry = Path(sys.argv[2]).read_text()
adapter = Path(sys.argv[3]).read_text()
gallery = Path(sys.argv[4]).read_text()
ready = Path(sys.argv[5]).read_text()

provider = re.search(
    r"MSHookFunction\s*\(\s*"
    r"reinterpret_cast<void\*>\s*\(\s*&CMSampleBufferGetImageBuffer\s*\)\s*,\s*"
    r"reinterpret_cast<void\*>\s*\(\s*&HookedCMSampleBufferGetImageBuffer\s*\)\s*,\s*"
    r"reinterpret_cast<void\*\*>\s*\(\s*&gOriginalCMSampleBufferGetImageBuffer\s*\)\s*\)",
    hook,
    re.S,
)
if provider is None:
    raise SystemExit("VCAM-PRO production hook provider structure changed")

if not re.search(
    r"return\s+gOriginalCMSampleBufferGetImageBuffer\s*!=\s*nullptr\s*;",
    hook,
    re.S,
):
    raise SystemExit("VCAM-PRO original trampoline success predicate changed")

for token in (
    "gOriginalCMSampleBufferGetImageBuffer(",
    "runtime.observeRealCameraBuffer(",
    "runtime.decideCameraBuffer(",
    "? decision.pixelBuffer",
    ": original;",
):
    if token not in hook:
        raise SystemExit(f"VCAM-PRO hook contract token missing: {token}")

guard = entry.index('ProcessIs("mediaserverd")')
start = entry.index("runtime.start()", guard)
install = entry.index("InstallReferenceCameraHook()", start)
if not (guard < start < install):
    raise SystemExit("VCAM-PRO mediaserverd startup/call relationship changed")

adapter_compact = re.sub(r"\s+", "", adapter)
for token in (
    "decision.pixelBuffer=original;",
    "CameraFailOpenReason::Disabled",
    "CameraFailOpenReason::ReconfigurationContended",
    "CameraFailOpenReason::ProducerUnavailable",
    "CameraFailOpenReason::EmptyOrNoEligibleFrame",
    "CameraFailOpenReason::InvalidLease",
    "CameraFailOpenReason::GeometryMismatch",
):
    if token not in adapter_compact:
        raise SystemExit(f"VCAM-PRO fail-open evidence missing: {token}")

for token in (
    "selectVideo(",
    "selectPhoto(",
    "LocalVideoReader",
    "LocalPhotoReader",
):
    if token not in gallery:
        raise SystemExit(f"VCAM-PRO local gallery evidence missing: {token}")

for token in (
    'Architecture)" = "iphoneos-arm64e"',
    '/usr/lib/TweakInject',
    '@loader_path/.jbroot/Library/Frameworks',
    '@loader_path/.jbroot/usr/lib',
    'IOS_MIN_VERSION=15.0',
):
    if token not in ready:
        raise SystemExit(f"VCAM-PRO RootHide evidence missing: {token}")
PY

SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
CXX="$(xcrun --sdk iphoneos -f clang++)"
COMMON="-std=c++17 -O0 -fno-lto -arch arm64 -isysroot $SDKROOT -miphoneos-version-min=15.0 -Wall -Wextra -Werror -Werror=unguarded-availability-new -pedantic"
OBJ="$BUILD/ReferenceCameraHook.compile-only.o"

"$CXX" $COMMON     -Isrc/frame_engine -Isrc/media_engine -Isrc/product     -c src/product/ReferenceCameraHook.mm     -o "$OBJ"

xcrun lipo -info "$OBJ" | tee "$BUILD/compile-arch.txt"
grep -q 'arm64' "$BUILD/compile-arch.txt"

xcrun otool -l "$OBJ" | tee "$BUILD/compile-load-commands.txt"
grep -q 'minos 15.0' "$BUILD/compile-load-commands.txt"

xcrun nm -u "$OBJ" | tee "$BUILD/compile-undefined.txt"
grep -q '_MSHookFunction' "$BUILD/compile-undefined.txt"
grep -q '_CMSampleBufferGetImageBuffer' "$BUILD/compile-undefined.txt"

xcrun nm "$OBJ" | c++filt | tee "$BUILD/compile-symbols.txt"
grep -Fq 'HookedCMSampleBufferGetImageBuffer' "$BUILD/compile-symbols.txt"
grep -Fq 'gOriginalCMSampleBufferGetImageBuffer' "$BUILD/compile-symbols.txt"

cat > "$BUILD/parity-matrix.tsv" <<'EOF'
dimension	legacy_classification	vcampro_classification	assessment
mediaserverd_targeting	PROVEN	PROVEN	MATCH
MSHookFunction_usage	PROVEN_DIRECT_IMPORT	PROVEN_DIRECT_CALL	MATCH
CMSampleBufferGetImageBuffer_target	PROVEN	PROVEN	MATCH
replacement_function_concept	PROVEN	PROVEN	MATCH
original_trampoline_concept	PROVEN	PROVEN	MATCH
startup_load_topology	MEDIASERVERD_PROVEN_EXACT_CONSTRUCTOR_NOT_DETERMINABLE	PROVEN	COMPATIBLE_LEGACY_TIMING_UNKNOWN
arm64_compatibility	PROVEN	PROVEN_COMPILE_ONLY	MATCH
rootless_layout	VAR_JB_MOBILESUBSTRATE	ROOTHIDE_TWEAKINJECT	ADAPTATION_NOT_HOOK_DIVERGENCE
ios15_compatibility	MIN_IOS_14_STATIC_RUNTIME_15_8_8_NOT_PROVEN	MIN_IOS_15_COMPILE_ONLY_PLUS_FROZEN_DEVICE_FACTS	COMPATIBLE_WITH_CAVEAT
fail_open	NOT_DETERMINABLE	PROVEN_EXPLICIT_ORIGINAL_BUFFER_FALLBACK	VCAMPRO_STRONGER_EVIDENCE
media_source	EXTERNAL_MJPEG_OBS_PC_EMBEDDED_EVIDENCE	LOCAL_GALLERY	PLANNED_PRODUCT_ADAPTATION
provider_resolution_model	PROVEN_DIRECT_IMPORT_NO_DLSYM_IMPORT	PROVEN_DIRECT_EXTERN_CALL	MATCH
hook_success_contract	TRAMPOLINE_STORAGE_AND_CALL_PROVEN_INSTALLER_RETURN_NOT_DETERMINABLE	ORIGINAL_TRAMPOLINE_NONNULL	COMPATIBLE
EOF

cat > "$BUILD/evidence.txt" <<EOF
IOS15USB_REFERENCE_SHA=$REFERENCE_SHA
IOS15USB_REFERENCE_SHA_CONFIRMED=PASS
IOS15USB_MSHOOKFUNCTION_IMPORT_CONFIRMED=PASS
IOS15USB_CMSAMPLEBUFFER_TARGET_CONFIRMED=PASS
IOS15USB_HOOK_MARKER_CONFIRMED=PASS
IOS15USB_MEDIASERVERD_FILTER_CONFIRMED=PASS
LEGACY_PROVIDER_IMPORT_MODEL=PROVEN_DIRECT_IMPORT
LEGACY_PROVIDER_RUNTIME_DLSYM=NOT_OBSERVED
LEGACY_MSHOOKFUNCTION_CALL_SITES=0x5c8c4,0x5e0d0
LEGACY_REPLACEMENT_FUNCTION_CONCEPT=PROVEN
LEGACY_ORIGINAL_TRAMPOLINE_CONCEPT=PROVEN
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
