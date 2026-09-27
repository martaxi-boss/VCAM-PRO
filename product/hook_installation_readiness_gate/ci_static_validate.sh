#!/bin/sh
set -eu

BASE=829f6d7581619c491308b0288af97d42bfb6955d
RUNTIME_GATE=eb463efd7a01e9160b5acb0e3541f3e016f47015
LOAD_PROBE=78b88bb36094ae1d0b4f6369e4d6ff03e9df9e67
PR19=2475bd51953b536c32d12e37475fd32eaf7c4a67
GATE=product/hook_installation_readiness_gate

test "$(git merge-base "$BASE" HEAD)" = "$BASE"

changed="$(git diff --name-only "$BASE"..HEAD)"
printf '%s\n' "$changed" | while IFS= read -r path; do
    test -n "$path" || continue
    case "$path" in
        product/hook_installation_readiness_gate/*|.github/workflows/reference-camera-hook-installation-readiness-gate-ci.yml)
            ;;
        *)
            echo "Unauthorized changed file: $path"
            exit 1
            ;;
    esac
done

git diff --quiet "$BASE"..HEAD -- src
git diff --quiet "$BASE"..HEAD -- product/hook_reachability_gate
git diff --quiet "$BASE"..HEAD -- product/runtime_gate
git diff --quiet "$BASE"..HEAD -- proofs/mediaserverd_load_probe
git diff --quiet "$BASE"..HEAD -- product/roothide_integration
git diff --quiet "$BASE"..HEAD -- product/build_roothide_integration_input.sh
git diff --quiet "$BASE"..HEAD -- product/VCAMPro.RootHideIntegration.plist

test "$(git ls-remote origin refs/heads/builder/reference-camera-hook-reachability-gate-001 | awk '{print $1}')" = "$BASE"
test "$(git ls-remote origin refs/heads/builder/roothide-mediaserverd-runtime-gate-001 | awk '{print $1}')" = "$RUNTIME_GATE"
test "$(git ls-remote origin refs/heads/builder/roothide-mediaserverd-load-proof-002 | awk '{print $1}')" = "$LOAD_PROBE"
test "$(git ls-remote origin refs/pull/19/head | awk '{print $1}')" = "$PR19"

test "$(git ls-remote https://github.com/martaxi-boss/MotionCam-iOS.git refs/heads/main | awk '{print $1}')" = "5ede3a1973a01cb13fe7f3ab562b47513feec1b1"
test "$(git ls-remote https://github.com/martaxi-boss/IOS-15-USB.git refs/heads/main | awk '{print $1}')" = "a908bccbcddb4efc072bb1bc8fbeb6ee89b1af9d"
test "$(git ls-remote https://github.com/martaxi-boss/IOS-16-USB-4k.git refs/heads/main | awk '{print $1}')" = "cc20d787070c67565173d4a46c218e2549cecc93"

python3 - <<'PY'
from pathlib import Path
import plistlib

hook = Path("src/product/ReferenceCameraHook.mm").read_text()
for token in (
    "CMSampleBufferGetImageBuffer",
    "MSHookFunction",
    "HookedCMSampleBufferGetImageBuffer",
    "observeRealCameraBuffer",
    "decideCameraBuffer",
):
    if token not in hook:
        raise SystemExit(f"Frozen production hook token missing: {token}")

build = Path("product/hook_installation_readiness_gate/build_hook_installation_readiness_gate_input.sh").read_text()
if "src/product/ReferenceCameraHook.mm" in build:
    raise SystemExit("Real production hook must not enter device artifact")
for token in ("src/product/VCAMProEntry.mm", "src/product/MediaserverdRuntime.mm", "ReferenceCameraHookInstallationReadinessStub.mm"):
    if token not in build:
        raise SystemExit(f"Gate build token missing: {token}")

gate = Path("product/hook_installation_readiness_gate")
stub = (gate / "ReferenceCameraHookInstallationReadinessStub.mm").read_text()
for token in (
    "dlsym(", "RTLD_DEFAULT", '"CMSampleBufferGetImageBuffer"', '"MSHookFunction"',
    '"mediaserverd"', "target-symbol=RESOLVED", "hook-provider=RESOLVED",
    "hook-install=NOT_EXECUTED", "frame-access=INACTIVE",
    "frame-substitution=INACTIVE", "return false;",
):
    if token not in stub:
        raise SystemExit(f"Readiness probe missing: {token}")
for token in (
    "HookedCMSampleBufferGetImageBuffer", "observeRealCameraBuffer",
    "decideCameraBuffer", "CMSampleBufferRef", "CVPixelBufferRef",
    "CMSampleBufferGetImageBuffer(", "MSHookFunction(", "dlopen(",
    "reinterpret_cast",
):
    if token in stub:
        raise SystemExit(f"Active hook/frame token found: {token}")
if stub.count("dlsym(") != 1 or stub.count("SymbolIsResolvable(") != 3:
    raise SystemExit("Unexpected observational symbol-resolution shape")

with (gate / "VCAMPro.HookInstallationReadinessGate.plist").open("rb") as f:
    product_filter = plistlib.load(f)
with (gate / "VCAMProHookInstallationReadinessWitness.plist").open("rb") as f:
    witness_filter = plistlib.load(f)
if product_filter != {"Filter": {"Executables": ["SpringBoard", "mediaserverd"]}}:
    raise SystemExit(product_filter)
if witness_filter != {"Filter": {"Executables": ["SpringBoard"]}}:
    raise SystemExit(witness_filter)

witness = (gate / "HookInstallationReadinessWitness.mm").read_text()
for token in (
    "VCAM REFERENCE HOOK INSTALLATION READINESS PASS",
    "runtime.start=PASS", "hook-call-path=REACHED",
    "target-symbol=RESOLVED", "hook-provider=RESOLVED",
    "hook-install=NOT_EXECUTED", "frame-substitution=INACTIVE",
):
    if token not in witness:
        raise SystemExit(f"Witness token missing: {token}")
PY

mkdir -p build/hook-installation-readiness-state
xcrun --sdk macosx clang++ -std=c++17 -Wall -Wextra -Werror -pedantic     -I"$GATE"     "$GATE/hook_installation_readiness_state_tests.cpp"     -o build/hook-installation-readiness-state/tests
build/hook-installation-readiness-state/tests | tee build/hook-installation-readiness-state/results.txt

mkdir -p build/reference-hook-compile-only
SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
CXX="$(xcrun --sdk iphoneos -f clang++)"
"$CXX" -std=c++17 -arch arm64 -isysroot "$SDKROOT" -miphoneos-version-min=15.0     -Wall -Wextra -Werror -Werror=unguarded-availability-new -pedantic     -Isrc/frame_engine -Isrc/media_engine -Isrc/product     -c src/product/ReferenceCameraHook.mm     -o build/reference-hook-compile-only/ReferenceCameraHook.compile-only.o
xcrun lipo -info build/reference-hook-compile-only/ReferenceCameraHook.compile-only.o | tee build/reference-hook-compile-only/arch.txt
grep -q 'arm64' build/reference-hook-compile-only/arch.txt
xcrun otool -l build/reference-hook-compile-only/ReferenceCameraHook.compile-only.o | tee build/reference-hook-compile-only/load-commands.txt
grep -q 'minos 15.0' build/reference-hook-compile-only/load-commands.txt
xcrun nm -u build/reference-hook-compile-only/ReferenceCameraHook.compile-only.o | tee build/reference-hook-compile-only/undefined.txt
grep -q '_MSHookFunction' build/reference-hook-compile-only/undefined.txt
grep -q '_CMSampleBufferGetImageBuffer' build/reference-hook-compile-only/undefined.txt
xcrun nm build/reference-hook-compile-only/ReferenceCameraHook.compile-only.o | c++filt | tee build/reference-hook-compile-only/symbols.txt
grep -Fq 'HookedCMSampleBufferGetImageBuffer' build/reference-hook-compile-only/symbols.txt

sh product/runtime_gate/run_runtime_gate_regressions.sh

echo "PRODUCTION_MEDIASERVERD_RUNTIME_COMPILED=PASS"
echo "PRODUCTION_VCAM_ENTRY_COMPILED=PASS"
echo "REFERENCE_CAMERA_HOOK_SOURCE_UNCHANGED=PASS"
echo "REFERENCE_CAMERA_HOOK_COMPILE_ONLY=PASS"
echo "HOOK_CALL_PATH_REACHABILITY_PROOF=PASS"
echo "TARGET_SYMBOL_RESOLUTION_PROBE=PASS"
echo "HOOK_PROVIDER_RESOLUTION_PROBE=PASS"
echo "TARGET_SYMBOL_NOT_INVOKED=PASS"
echo "HOOK_PROVIDER_NOT_INVOKED=PASS"
echo "HOOK_INSTALLATION_NOT_EXECUTED=PASS"
echo "CAMERA_INTERCEPTION_INACTIVE=PASS"
echo "FRAME_CALLBACK_PATH_INACTIVE=PASS"
echo "FRAME_ACCESS_INACTIVE=PASS"
echo "FRAME_SUBSTITUTION_INACTIVE=PASS"
echo "ROOT_HIDE_PACKAGING_UNCHANGED=PASS"
echo "SPRINGBOARD_CONTROL_UNCHANGED=PASS"
echo "FLOATING_CONTROL_UNCHANGED=PASS"
echo "MEDIASERVERD_RUNTIME_UNCHANGED=PASS"
echo "FRAME_ENGINE_UNCHANGED=PASS"
echo "LOCAL_GALLERY_UNCHANGED=PASS"
echo "SHARED_CONTROL_UNCHANGED=PASS"
echo "SHARED_MEDIA_UNCHANGED=PASS"
echo "FAIL_OPEN_UNCHANGED=PASS"
echo "PR19_MODIFIED=NO"
echo "PREVIOUS_GATES_MODIFIED=NO"
echo "REFERENCE_REPOS_MODIFIED=NO"
