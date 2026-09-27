#!/bin/sh
set -eu

BASE=710ed97c9957d3564c838c5feba479a5b59affb1
MAIN=d476caacc4f557843f9551533c2fcbe7c5d40baa
IOS15=a908bccbcddb4efc072bb1bc8fbeb6ee89b1af9d
MOTION=5ede3a1973a01cb13fe7f3ab562b47513feec1b1
IOS16=cc20d787070c67565173d4a46c218e2549cecc93
HOOK_BLOB=b3b5360757d17951b0c508ab455d7ea4ffb0d6fe
SCOPE=product/full_product_real_hook_001

test "$(git merge-base "$BASE" HEAD)" = "$BASE"

changed="$(git diff --name-only "$BASE"..HEAD)"
printf '%s\n' "$changed" | while IFS= read -r path; do
    test -n "$path" || continue
    case "$path" in
        "$SCOPE"/*|src/product/VCAMProEntry.mm|docs/CANONICAL_PROJECT_STATE.md|.github/workflows/full-product-real-hook-001-ci.yml)
            ;;
        *)
            echo "Unauthorized changed path: $path"
            exit 1
            ;;
    esac
done

test "$(git hash-object src/product/ReferenceCameraHook.mm)" = "$HOOK_BLOB"
git diff --quiet "$BASE"..HEAD -- src/product/ReferenceCameraHook.mm

required_sources='
src/media_engine/LocalVideoReader.mm
src/media_engine/LocalPhotoReader.mm
src/frame_engine/PreparedFrame.cpp
src/frame_engine/FrameEngineState.cpp
src/frame_engine/ReadyFrameQueue.cpp
src/frame_engine/FrameTimelineScheduler.cpp
src/frame_engine/MonotonicHostClock.cpp
src/media_engine/FrameNormalizer.cpp
src/media_engine/FrameTransformer.mm
src/media_engine/FramePipelinePump.cpp
src/media_engine/FramePipelinePumpTimed.cpp
src/media_engine/ProducerWakeupController.cpp
src/media_engine/ProducerWakeupDriver.mm
src/media_engine/InternalGalleryMediaSession.mm
src/control/InternalGalleryViewController.mm
src/product/ControlStateCache.cpp
src/product/CameraConsumerAdapter.cpp
src/product/SharedControlStore.mm
src/product/SharedMediaStager.mm
src/product/ProductControlOwner.mm
src/product/SpringBoardControlHost.mm
src/product/MediaserverdRuntime.mm
src/product/VCAMProEntry.mm
src/product/ReferenceCameraHook.mm
'
for source in $required_sources; do
    test -f "$source"
    grep -Fq "$source" "$SCOPE/build_full_product_real_hook_input.sh"
done

for forbidden in     ReferenceCameraHookInstallationReadinessStub.mm     ReferenceCameraHookReachabilityStub.mm     ReferenceCameraHookRuntimeGateStub.mm     MSHookFunctionStub; do
    test -z "$(grep -F "$forbidden" "$SCOPE/build_full_product_real_hook_input.sh" || true)"
done

python3 - <<'PY'
from pathlib import Path
import plistlib

scope = Path("product/full_product_real_hook_001")
entry = Path("src/product/VCAMProEntry.mm").read_text()
hook = Path("src/product/ReferenceCameraHook.mm").read_text()
proof = (scope / "FullProductRealHookProof.mm").read_text()
witness = (scope / "FullProductRealHookWitness.mm").read_text()
header = (scope / "FullProductRealHookProofState.h").read_text()
build = (scope / "build_full_product_real_hook_input.sh").read_text()
state = Path("src/product/ProductControlState.h").read_text()
adapter = Path("src/product/CameraConsumerAdapter.cpp").read_text()
host = Path("src/product/SpringBoardControlHost.mm").read_text()
gallery = Path("src/control/InternalGalleryViewController.mm").read_text()

if entry.count("InstallReferenceCameraHook()") != 1:
    raise SystemExit("REAL_HOOK_INSTALL_ATTEMPT_COUNT != ONE")
for token in (
    "ResetFullProductRealHookProofState()",
    "runtime.start()",
    "InstallReferenceCameraHook()",
    "PublishFullProductRealHookInstallProof()",
    "StartSpringBoardControlHost()",
):
    if token not in entry:
        raise SystemExit(f"Entry token missing: {token}")
if entry.index("ResetFullProductRealHookProofState()") > entry.index("runtime.start()"):
    raise SystemExit("Proof state is not cleared before runtime attempt")
if entry.index("runtime.start()") > entry.index("InstallReferenceCameraHook()"):
    raise SystemExit("Runtime start must precede hook install")
if entry.index("if (hookInstalled)") > entry.index("PublishFullProductRealHookInstallProof()"):
    raise SystemExit("Proof publication is not gated by hook success")

required_hook = (
    "CMSampleBufferGetImageBuffer",
    "HookedCMSampleBufferGetImageBuffer",
    "MSHookFunction",
    "gOriginalCMSampleBufferGetImageBuffer",
    "observeRealCameraBuffer",
    "decideCameraBuffer",
)
for token in required_hook:
    if token not in hook:
        raise SystemExit(f"Frozen hook token missing: {token}")
if "decision.pixelBuffer != nullptr" not in hook or ": original;" not in hook:
    raise SystemExit("Frozen hook fail-open return changed")

for body_name, body in (("proof", proof), ("witness", witness)):
    for forbidden in (
        "HookedCMSampleBufferGetImageBuffer(",
        "CMSampleBufferGetImageBuffer(",
        "MSHookFunction(",
    ):
        if forbidden in body:
            raise SystemExit(f"Synthetic/direct hook call in {body_name}: {forbidden}")

if '"com.vcampro.gate.full-product-real-hook.001"' not in header:
    raise SystemExit("Full-product notification identity missing")
if 'VCAM_FULL_PRODUCT_REAL_HOOK_VERSION "0.1.0+roothide8~fullrealhook1"' not in header:
    raise SystemExit("Full-product proof version missing")

matches = []
needle = "com.vcampro.gate.full-product-real-hook.001"
for path in Path("product").rglob("*"):
    if path.is_file() and path.suffix in {".h", ".mm", ".cpp", ".plist"}:
        try:
            body = path.read_text()
        except UnicodeDecodeError:
            continue
        if needle in body:
            matches.append(path.as_posix())
expected = ["product/full_product_real_hook_001/FullProductRealHookProofState.h"]
if matches != expected:
    raise SystemExit(f"Notification identity not unique: {matches}")

for token in (
    "VCAM REAL HOOK INSTALL PASS",
    "runtime.start=PASS",
    "real-reference-hook-install=PASS",
    "original-trampoline=NON_NULL",
    "callback=NOT_EXERCISED",
    "frame-substitution=INACTIVE",
):
    if token not in witness:
        raise SystemExit(f"Witness token missing: {token}")

with (scope / "VCAMPro.FullProductRealHook.plist").open("rb") as f:
    product_filter = plistlib.load(f)
with (scope / "VCAMProFullProductRealHookWitness.plist").open("rb") as f:
    witness_filter = plistlib.load(f)
if product_filter != {"Filter": {"Executables": ["SpringBoard", "mediaserverd"]}}:
    raise SystemExit(product_filter)
if witness_filter != {"Filter": {"Executables": ["SpringBoard"]}}:
    raise SystemExit(witness_filter)

if "bool enabled = false;" not in state:
    raise SystemExit("VCAM is not disabled by default")
if "decision.pixelBuffer = original;" not in adapter:
    raise SystemExit("Fail-open original buffer initialization missing")
if "if (!enabled_.load(" not in adapter:
    raise SystemExit("Disabled fail-open guard missing")

for token in (
    'setTitle:@"VCAM"',
    "colorWithWhite:0.1",
    "StartSpringBoardControlHost()",
):
    if token not in host:
        raise SystemExit(f"Black product control token missing: {token}")

for token in (
    "Select Media",
    "Change",
    "Clear",
    "Play",
    "Pause",
    "Resume",
    "Loop",
    "VCAM ON",
):
    if token not in gallery:
        raise SystemExit(f"Product UI control missing: {token}")

if "ReferenceCameraHookInstallationReadinessStub.mm" in build:
    raise SystemExit("Readiness stub linked")
if "src/product/ReferenceCameraHook.mm" not in build:
    raise SystemExit("Real ReferenceCameraHook not linked")

print("FULL_PRODUCT_COMPONENTS_PRESENT=PASS")
print("LOCAL_VIDEO_READER_PRESENT=PASS")
print("LOCAL_PHOTO_READER_PRESENT=PASS")
print("FRAME_ENGINE_A_F2_PRESENT=PASS")
print("INTERNAL_GALLERY_PRESENT=PASS")
print("SHARED_CONTROL_STORE_PRESENT=PASS")
print("SHARED_MEDIA_STAGER_PRESENT=PASS")
print("REAL_HOOK_INSTALL_ATTEMPT_COUNT=ONE")
print("SYNTHETIC_CALLBACK_TEST_ABSENT=PASS")
print("FRAME_SUBSTITUTION_INACTIVE_BY_DEFAULT=PASS")
print("FAIL_OPEN_BEHAVIOR_PRESERVED=PASS")
print("BLACK_VCAM_PRODUCT_CONTROL_PRESENT=PASS")
print("REFERENCE_CAMERA_HOOK_SOURCE_UNCHANGED=PASS")
print("VISIBLE_WITNESS_PRESENT=PASS")
print("VISIBLE_WITNESS_SPRINGBOARD_ONLY=PASS")
PY

test "$(git ls-remote origin refs/heads/main | awk '{print $1}')" = "$MAIN"
heads="$(git ls-remote --heads origin | awk '{print $2}' | sort)"
expected_heads="$(printf '%s\n' refs/heads/builder/canonical-hook-continuation-001 refs/heads/main | sort)"
test "$heads" = "$expected_heads"

test "$(git ls-remote https://github.com/martaxi-boss/IOS-15-USB.git refs/heads/main | awk '{print $1}')" = "$IOS15"
test "$(git ls-remote https://github.com/martaxi-boss/MotionCam-iOS.git refs/heads/main | awk '{print $1}')" = "$MOTION"
test "$(git ls-remote https://github.com/martaxi-boss/IOS-16-USB-4k.git refs/heads/main | awk '{print $1}')" = "$IOS16"

grep -Fq 'REAL_HOOK_INSTALLATION_DEVICE_PROOF=PASS' docs/CANONICAL_PROJECT_STATE.md
grep -Fq 'ORIGINAL_TRAMPOLINE_DEVICE_PROOF=PASS' docs/CANONICAL_PROJECT_STATE.md
grep -Fq 'REAL_HOOK_DEVICE_PROOF_PACKAGE=0.1.0+roothide7~realhookruntime2' docs/CANONICAL_PROJECT_STATE.md
grep -Fq 'FRAME_SUBSTITUTION_TESTED=NO' docs/CANONICAL_PROJECT_STATE.md
grep -Eq '^FULL_PRODUCT_REAL_HOOK_STATUS=(CI_PENDING|CI_PASS)$' docs/CANONICAL_PROJECT_STATE.md
grep -Fq 'NEXT_PHASE=FULL_PRODUCT_REAL_HOOK_DEVICE_PROOF' docs/CANONICAL_PROJECT_STATE.md

mkdir -p build/full-product-real-hook-001/evidence build/full-product-real-hook-001/tests

xcrun --sdk macosx clang++ -std=c++17 -Wall -Wextra -Werror -pedantic     -I"$SCOPE"     "$SCOPE/full_product_real_hook_state_tests.cpp"     -o build/full-product-real-hook-001/tests/proof-state
build/full-product-real-hook-001/tests/proof-state     | tee build/full-product-real-hook-001/evidence/proof-state-tests.txt

tools/run_frame_regressions.sh

xcrun --sdk macosx clang++     -std=c++17 -fobjc-arc -Wall -Wextra -Werror -pedantic     -Wno-deprecated-declarations     -Isrc/frame_engine -Isrc/media_engine -Isrc/control     src/frame_engine/PreparedFrame.cpp     src/frame_engine/FrameEngineState.cpp     src/frame_engine/ReadyFrameQueue.cpp     src/media_engine/LocalVideoReader.mm     src/media_engine/LocalPhotoReader.mm     src/media_engine/FrameNormalizer.cpp     src/media_engine/FrameTransformer.mm     src/media_engine/FramePipelinePump.cpp     tests/media_engine/internal_gallery_integration_tests.mm     -framework Accelerate     -framework Foundation     -framework AVFoundation     -framework CoreFoundation     -framework CoreGraphics     -framework CoreMedia     -framework CoreVideo     -framework ImageIO     -o build/full-product-real-hook-001/tests/internal-gallery
build/full-product-real-hook-001/tests/internal-gallery     | tee build/full-product-real-hook-001/evidence/internal-gallery-tests.txt
grep -q 'Internal gallery tests run: 20, failures: 0'     build/full-product-real-hook-001/evidence/internal-gallery-tests.txt

xcrun --sdk macosx clang++     -std=c++17 -Wall -Wextra -Werror -pedantic -pthread     -Isrc/frame_engine -Isrc/product     src/frame_engine/PreparedFrame.cpp     src/frame_engine/ReadyFrameQueue.cpp     src/product/ControlStateCache.cpp     src/product/CameraConsumerAdapter.cpp     tests/product/camera_consumer_adapter_tests.cpp     -framework CoreFoundation     -framework CoreMedia     -framework CoreVideo     -o build/full-product-real-hook-001/tests/camera-consumer
build/full-product-real-hook-001/tests/camera-consumer     | tee build/full-product-real-hook-001/evidence/camera-consumer-tests.txt
grep -q 'Camera consumer tests run: 13, failures: 0'     build/full-product-real-hook-001/evidence/camera-consumer-tests.txt

xcrun --sdk macosx clang++     -std=c++17 -fobjc-arc -Wall -Wextra -Werror -pedantic -pthread     -Wno-deprecated-declarations     -Isrc/frame_engine -Isrc/media_engine -Isrc/control -Isrc/product     src/frame_engine/PreparedFrame.cpp     src/frame_engine/FrameEngineState.cpp     src/frame_engine/ReadyFrameQueue.cpp     src/frame_engine/FrameTimelineScheduler.cpp     src/frame_engine/MonotonicHostClock.cpp     src/media_engine/LocalVideoReader.mm     src/media_engine/LocalPhotoReader.mm     src/media_engine/FrameNormalizer.cpp     src/media_engine/FrameTransformer.mm     src/media_engine/FramePipelinePump.cpp     src/media_engine/FramePipelinePumpTimed.cpp     src/media_engine/ProducerWakeupController.cpp     src/media_engine/ProducerWakeupDriver.mm     src/media_engine/InternalGalleryMediaSession.mm     src/product/ControlStateCache.cpp     src/product/CameraConsumerAdapter.cpp     src/product/SharedControlStore.mm     src/product/SharedMediaStager.mm     src/product/ProductControlOwner.mm     tests/product/full_product_integration_tests.mm     -framework Accelerate     -framework Foundation     -framework AVFoundation     -framework CoreFoundation     -framework CoreGraphics     -framework CoreMedia     -framework CoreVideo     -framework ImageIO     -o build/full-product-real-hook-001/tests/full-product
build/full-product-real-hook-001/tests/full-product     | tee build/full-product-real-hook-001/evidence/full-product-tests.txt
grep -q 'Product integration tests run: 8, failures: 0'     build/full-product-real-hook-001/evidence/full-product-tests.txt

echo "HOST_PRODUCT_TESTS=PASS"
echo "MAIN_UNCHANGED=PASS"
echo "READ_ONLY_REPOS_UNCHANGED=PASS"
echo "DEVICE_ACTION=NO"
