#!/bin/sh
set -eu

BASE=2895d40391a344dd5325affa05bda2cb0b1612bf
PR19=2475bd51953b536c32d12e37475fd32eaf7c4a67
IOS15=a908bccbcddb4efc072bb1bc8fbeb6ee89b1af9d
MOTION=5ede3a1973a01cb13fe7f3ab562b47513feec1b1
IOS16=cc20d787070c67565173d4a46c218e2549cecc93
PATCHER_SHA=80c16e08da33fecd27c0ff35777f37afd171868b

HOOK_BLOB=b3b5360757d17951b0c508ab455d7ea4ffb0d6fe
RUNTIME_BLOB=37c613ab2c0746b34a86b74e20ce8814dee0a7da
ENTRY_BLOB=0003e5e7b8d2b6973cb8feae699bd25e545e2658

ROOT="$PWD/build/legacy-real-hook-runtime-activation-gate-001"
GATE=product/legacy_real_hook_runtime_activation_gate
INPUT="$ROOT/input/com.vcampro.camera_0.1.0+roothide7~realhookruntime1_iphoneos-arm64.deb"
FINAL_DIR="$ROOT/final"
FINAL="$FINAL_DIR/VCAM-PRO-RootHide-Legacy-Real-Hook-Runtime-Activation-Gate-001.deb"
EXTRACT="$ROOT/extracted-final"
EVIDENCE="$ROOT/evidence"
DYLIB_REL="usr/lib/TweakInject/VCAMProRealHookRuntimeActivationGate.dylib"
PLIST_REL="usr/lib/TweakInject/VCAMProRealHookRuntimeActivationGate.plist"

test "$(git merge-base "$BASE" HEAD)" = "$BASE"

changed="$(git diff --name-only "$BASE"..HEAD)"
printf '%s\n' "$changed" | while IFS= read -r path; do
    test -n "$path" || continue
    case "$path" in
        product/legacy_real_hook_runtime_activation_gate/*|.github/workflows/legacy-real-hook-runtime-activation-gate-ci.yml)
            ;;
        *)
            echo "Unauthorized mutation: $path"
            exit 1
            ;;
    esac
done

git diff --quiet "$BASE"..HEAD -- src
git diff --quiet "$BASE"..HEAD -- product/hook_installation_readiness_gate
git diff --quiet "$BASE"..HEAD -- product/legacy_real_hook_linkage_gate
git diff --quiet "$BASE"..HEAD -- product/roothide_integration
git diff --quiet "$BASE"..HEAD -- product/VCAMPro.RootHideIntegration.plist

test "$(git rev-parse "$BASE:src/product/ReferenceCameraHook.mm")" = "$HOOK_BLOB"
test "$(git hash-object src/product/ReferenceCameraHook.mm)" = "$HOOK_BLOB"
test "$(git rev-parse "$BASE:src/product/MediaserverdRuntime.mm")" = "$RUNTIME_BLOB"
test "$(git hash-object src/product/MediaserverdRuntime.mm)" = "$RUNTIME_BLOB"
test "$(git rev-parse "$BASE:src/product/VCAMProEntry.mm")" = "$ENTRY_BLOB"
test "$(git hash-object src/product/VCAMProEntry.mm)" = "$ENTRY_BLOB"

python3 - <<'PY'
from pathlib import Path

hook = Path("src/product/ReferenceCameraHook.mm").read_text()
entry = Path("product/legacy_real_hook_runtime_activation_gate/RealHookRuntimeActivationGateEntry.mm").read_text()

required_call = """    MSHookFunction(
        reinterpret_cast<void*>(
            &CMSampleBufferGetImageBuffer),
        reinterpret_cast<void*>(
            &HookedCMSampleBufferGetImageBuffer),
        reinterpret_cast<void**>(
            &gOriginalCMSampleBufferGetImageBuffer));"""
required_return = """    return
        gOriginalCMSampleBufferGetImageBuffer !=
        nullptr;"""

if required_call not in hook:
    raise SystemExit("Frozen real hook tuple changed")
if required_return not in hook:
    raise SystemExit("Frozen real hook success predicate changed")

body = hook.split("bool InstallReferenceCameraHook() {", 1)[1]
body = body.split("\n}\n\n}  // namespace vcam::product", 1)[0]
if body.count("MSHookFunction(") != 1:
    raise SystemExit("Unexpected provider invocation count in frozen installer")
if body.count("return") != 1:
    raise SystemExit("Unexpected return count in frozen installer")

if "gOriginalCMSampleBufferGetImageBuffer" in entry:
    raise SystemExit("Gate entry must not expose original storage")
if "MediaserverdRuntime::shared()" not in entry:
    raise SystemExit("Runtime shared instance missing")
if "runtime.start()" not in entry:
    raise SystemExit("runtime.start missing")
if "InstallReferenceCameraHook()" not in entry:
    raise SystemExit("real installer call missing")
if entry.index("runtime.start()") > entry.index("InstallReferenceCameraHook()"):
    raise SystemExit("Production ordering violated")
if 'if (!runtimeStarted)' not in entry:
    raise SystemExit("Hook call must be gated on runtime start")
if entry.count("InstallReferenceCameraHook()") != 1:
    raise SystemExit("Real hook installation must be attempted once")
for marker in (
    "RUNTIME_START",
    "REAL_REFERENCE_HOOK_INSTALL",
    "ORIGINAL_TRAMPOLINE_NON_NULL",
):
    if marker not in entry:
        raise SystemExit(f"Missing runtime marker: {marker}")
for forbidden in ("HookedCMSampleBufferGetImageBuffer(", "MSHookFunction(", "CMSampleBufferGetImageBuffer("):
    if forbidden in entry:
        raise SystemExit(f"Gate-local substitute/interposition forbidden: {forbidden}")

print("REAL_HOOK_SUCCESS_PREDICATE_STATIC_INVARIANT=PASS")
print("GATE_ENTRY_PRODUCTION_ORDERING=PASS")
PY

test "$(git ls-remote origin refs/pull/19/head | awk '{print $1}')" = "$PR19"
test "$(git ls-remote https://github.com/martaxi-boss/IOS-15-USB.git refs/heads/main | awk '{print $1}')" = "$IOS15"
test "$(git ls-remote https://github.com/martaxi-boss/MotionCam-iOS.git refs/heads/main | awk '{print $1}')" = "$MOTION"
test "$(git ls-remote https://github.com/martaxi-boss/IOS-16-USB-4k.git refs/heads/main | awk '{print $1}')" = "$IOS16"

if grep -REn 'hookselftest|self[-_ ]?test|dummy[[:space:]_-]*hook|ReferenceCameraHook.*Stub|MSHookFunctionStub' "$GATE"; then
    echo "Synthetic hook architecture found in gate scope"
    exit 1
fi

sh "$GATE/build_runtime_activation_gate_input.sh"

test -f "$INPUT"
test "$(dpkg-deb -f "$INPUT" Package)" = "com.vcampro.camera"
test "$(dpkg-deb -f "$INPUT" Version)" = "0.1.0+roothide7~realhookruntime1"
test "$(dpkg-deb -f "$INPUT" Architecture)" = "iphoneos-arm64"

mkdir -p "$EVIDENCE"
dpkg-deb -c "$INPUT" > "$EVIDENCE/input-inventory.txt"

git clone --quiet https://github.com/roothide/RootHidePatcher.git "$ROOT/RootHidePatcher"
git -C "$ROOT/RootHidePatcher" checkout --quiet "$PATCHER_SHA"
test "$(git -C "$ROOT/RootHidePatcher" rev-parse HEAD)" = "$PATCHER_SHA"

mkdir -p "$FINAL_DIR"
sudo env "PATH=$PATH" bash "$ROOT/RootHidePatcher/patch.sh" "$INPUT" "$FINAL"

test -f "$FINAL"
shasum -a 256 "$FINAL" | tee "$FINAL.sha256"

rm -rf "$EXTRACT"
mkdir -p "$EXTRACT"
dpkg-deb -R "$FINAL" "$EXTRACT"
dpkg-deb -f "$FINAL" > "$EVIDENCE/final-control.txt"
dpkg-deb -c "$FINAL" > "$EVIDENCE/final-inventory.txt"

test "$(dpkg-deb -f "$FINAL" Package)" = "com.vcampro.camera"
test "$(dpkg-deb -f "$FINAL" Version)" = "0.1.0+roothide7~realhookruntime1"
test "$(dpkg-deb -f "$FINAL" Architecture)" = "iphoneos-arm64e"
test ! -e "$EXTRACT/var/jb"

test -f "$EXTRACT/$DYLIB_REL"
test -f "$EXTRACT/$PLIST_REL"

data_files="$(find "$EXTRACT/usr/lib/TweakInject" -type f | sed "s#^$EXTRACT/##" | sort)"
expected_files="$(printf '%s\n%s\n' "$DYLIB_REL" "$PLIST_REL" | sort)"
test "$data_files" = "$expected_files"

python3 - <<'PY'
from pathlib import Path
import plistlib

root = Path("build/legacy-real-hook-runtime-activation-gate-001/extracted-final")
plist_path = root / "usr/lib/TweakInject/VCAMProRealHookRuntimeActivationGate.plist"
with plist_path.open("rb") as f:
    value = plistlib.load(f)

expected = {"Filter": {"Executables": ["mediaserverd"]}}
if value != expected:
    raise SystemExit(value)

expected_postinst = "#!/bin/sh\nset -e\n\nexit 0\n"
actual_postinst = (root / "DEBIAN/postinst").read_text()
if actual_postinst != expected_postinst:
    raise SystemExit("Maintainer script is not inert")

inventory = [
    p.relative_to(root).as_posix()
    for p in root.rglob("*")
    if p.is_file()
]
for forbidden in (
    "com.vcampro.control.plist",
    "selected-media",
    "SharedMedia",
    "SpringBoard",
    "WhatsApp",
    "FaceTime",
):
    if any(forbidden.lower() in p.lower() for p in inventory):
        raise SystemExit(f"Forbidden packaged payload: {forbidden}")

print("MEDIASERVERD_ONLY_FILTER=PASS")
print("INERT_MAINTAINER_SCRIPT=PASS")
print("NO_PACKAGED_CONTROL_OR_MEDIA_FILES=PASS")
PY

DYLIB="$EXTRACT/$DYLIB_REL"
xcrun lipo -info "$DYLIB" | tee "$EVIDENCE/dylib-arch.txt"
xcrun otool -l "$DYLIB" > "$EVIDENCE/dylib-load-commands.txt"
xcrun otool -D "$DYLIB" > "$EVIDENCE/dylib-install-name.txt"
xcrun otool -L "$DYLIB" > "$EVIDENCE/dylib-linked-libraries.txt"
xcrun nm -a "$DYLIB" | c++filt > "$EVIDENCE/dylib-symbols.txt" || true
xcrun nm -u "$DYLIB" > "$EVIDENCE/dylib-undefined.txt" || true
strings "$DYLIB" > "$EVIDENCE/dylib-strings.txt"
codesign --verify --verbose=2 "$DYLIB" 2> "$EVIDENCE/codesign-verify.txt"
ldid -e "$DYLIB" > "$EVIDENCE/dylib-entitlements.txt"

grep -q 'architecture: arm64' "$EVIDENCE/dylib-arch.txt"
test -z "$(grep 'arm64e' "$EVIDENCE/dylib-arch.txt" || true)"
grep -q 'minos 15.0' "$EVIDENCE/dylib-load-commands.txt"
grep -q '@loader_path/.jbroot/Library/Frameworks' "$EVIDENCE/dylib-load-commands.txt"
grep -q '@loader_path/.jbroot/usr/lib' "$EVIDENCE/dylib-load-commands.txt"
grep -q '@loader_path/VCAMProRealHookRuntimeActivationGate.dylib' "$EVIDENCE/dylib-install-name.txt"
grep -q 'LC_CODE_SIGNATURE' "$EVIDENCE/dylib-load-commands.txt"

grep -Fq 'vcam::product::InstallReferenceCameraHook()' "$EVIDENCE/dylib-symbols.txt"
grep -Fq 'HookedCMSampleBufferGetImageBuffer' "$EVIDENCE/dylib-symbols.txt"
grep -Fq 'gOriginalCMSampleBufferGetImageBuffer' "$EVIDENCE/dylib-symbols.txt"
grep -Fxq '_MSHookFunction' "$EVIDENCE/dylib-undefined.txt"
grep -Fxq '_CMSampleBufferGetImageBuffer' "$EVIDENCE/dylib-undefined.txt"
grep -Fq 'RUNTIME_START' "$EVIDENCE/dylib-strings.txt"
grep -Fq 'REAL_REFERENCE_HOOK_INSTALL' "$EVIDENCE/dylib-strings.txt"
grep -Fq 'ORIGINAL_TRAMPOLINE_NON_NULL' "$EVIDENCE/dylib-strings.txt"

test -z "$(grep -E 'ReferenceCameraHook.*Stub|hookselftest|MSHookFunctionStub' "$EVIDENCE/dylib-symbols.txt" "$EVIDENCE/dylib-strings.txt" || true)"
test -z "$(grep -E 'UIKit|PhotosUI' "$EVIDENCE/dylib-linked-libraries.txt" || true)"

{
    echo "TASK_ID=VCAM-PRO-LEGACY-EQUIVALENT-REAL-HOOK-RUNTIME-ACTIVATION-GATE-001"
    echo "BASE_SHA=$BASE"
    echo "REFERENCE_CAMERA_HOOK_SOURCE_BLOB=$HOOK_BLOB"
    echo "MEDIASERVERD_RUNTIME_SOURCE_BLOB=$RUNTIME_BLOB"
    echo "VCAMPRO_ENTRY_SOURCE_BLOB=$ENTRY_BLOB"
    echo "ROOT_HIDE_PATCHER_SHA=$PATCHER_SHA"
    echo "RUNTIME_EVIDENCE_PATH=/var/tmp/vcampro-legacy-real-hook-runtime-activation-gate-001.txt"
    echo "AUTHORITATIVE_BASE_CONFIRMED=PASS"
    echo "REFERENCE_CAMERA_HOOK_SOURCE_UNCHANGED=PASS"
    echo "MEDIASERVERD_RUNTIME_SOURCE_UNCHANGED=PASS"
    echo "VCAMPRO_ENTRY_SOURCE_UNCHANGED=PASS"
    echo "REAL_REFERENCE_HOOK_LINKED=PASS"
    echo "REAL_REPLACEMENT_SYMBOL_LINKED=PASS"
    echo "REAL_ORIGINAL_STORAGE_LINKED=PASS"
    echo "MSHOOKFUNCTION_REFERENCE_PRESENT=PASS"
    echo "CMSAMPLEBUFFER_TARGET_REFERENCE_PRESENT=PASS"
    echo "NO_HOOK_STUB_LINKED=PASS"
    echo "NO_SELFTEST_HOOK_PROVIDER_LINKED=PASS"
    echo "ARM64=PASS"
    echo "MINIMUM_IOS_15=PASS"
    echo "ROOTHIDE_RPATH_INSTALL_NAME=PASS"
    echo "VALID_CODE_SIGNATURE=PASS"
    echo "MEDIASERVERD_ONLY_FILTER=PASS"
    echo "NO_PACKAGED_CONTROL_PLIST=PASS"
    echo "NO_PACKAGED_SELECTED_MEDIA=PASS"
    echo "NO_GALLERY_UI_ACTIVATION=PASS"
    echo "NO_CAMERA_WHATSAPP_FACETIME_FILTER=PASS"
    echo "REAL_HOOK_SUCCESS_PREDICATE_STATIC_INVARIANT=PASS"
    echo "PR19_MODIFIED=NO"
    echo "REFERENCE_REPOS_MODIFIED=NO"
    echo "MERGE_PERFORMED=NO"
    echo "RELEASE_PERFORMED=NO"
    echo "DEPLOY_PERFORMED=NO"
    echo "DEVICE_ACTION=NO"
} | tee "$EVIDENCE/validation-report.txt"

cat "$FINAL.sha256"
