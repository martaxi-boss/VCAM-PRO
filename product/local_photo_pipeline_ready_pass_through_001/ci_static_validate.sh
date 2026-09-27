#!/bin/sh
set -eu

START=949b7af7725caf672ea4ddaea12df08485b0550f
MAIN=d476caacc4f557843f9551533c2fcbe7c5d40baa
SCOPE=product/local_photo_pipeline_ready_pass_through_001

check_blob() {
    path="$1"
    expected="$2"
    actual="$(git hash-object "$path")"
    test "$actual" = "$expected"
}

check_blob src/product/ReferenceCameraHook.mm b3b5360757d17951b0c508ab455d7ea4ffb0d6fe
check_blob src/product/CameraConsumerAdapter.cpp c49806ae6af94f65d3d8d4b9158dd9eb38b9eec8
check_blob src/product/CameraConsumerAdapter.h 3577bd2935c72a69529c855c8730d6c75054ab34
check_blob src/frame_engine/ReadyFrameQueue.cpp efa8583e9770807aae9b33affd927b3aa8c0d525
check_blob src/frame_engine/ReadyFrameQueue.h b7afe3ab62a63cfc580528ee2c92280797779f18
check_blob src/media_engine/LocalPhotoReader.mm 3746777d17fd95fa757c7161dfe683af449a0bc6
check_blob src/media_engine/LocalPhotoReader.h 44c1b3505f7bd630105f6c4a79d2d04bf6047293
check_blob src/media_engine/InternalGalleryMediaSession.mm a73891bb5080e3fafe9cdd98be13604e23584c59
check_blob src/media_engine/InternalGalleryMediaSession.h 8bb36177ca73f5e01ae1d9f6ff69bc022d1e8cdf
check_blob src/product/SharedMediaStager.mm d3c144d4ca2f522d438fd98266ac3e03bd50b38d
check_blob src/product/SharedMediaStager.h ad62421a1a2befbbe9a7461ed3927de1d75052ba
check_blob src/product/SharedControlStore.mm 0227cd19b48d6fcff9a97d0a28d6aa3283badadd
check_blob src/product/SharedControlStore.h 94aea4d22d3b934237c00d467b3dd1125eb12220
check_blob src/product/ProductControlOwner.mm 9e2909da17142127bbef2448891da02d8c95c516
check_blob src/product/ProductControlOwner.h 6b8b30f5e7dcf7db37d66eddada03f3e3c61fa90
check_blob src/product/MediaserverdRuntime.h 880143505c07450a2c47cb345722371fa820e2e9

test "$(git merge-base "$START" HEAD)" = "$START"

changed="$(git diff --name-only "$START"..HEAD)"
printf '%s\n' "$changed" | while IFS= read -r item; do
    test -n "$item" || continue
    case "$item" in
        "$SCOPE"/*|src/product/MediaserverdRuntime.mm|docs/CANONICAL_PROJECT_STATE.md|.github/workflows/local-photo-pipeline-ready-pass-through-001-ci.yml)
            ;;
        *)
            echo "Unauthorized mutation: $item"
            exit 1
            ;;
    esac
done

src_changed="$(git diff --name-only "$START"..HEAD -- src)"
test "$src_changed" = "src/product/MediaserverdRuntime.mm"

python3 - <<'PY'
from pathlib import Path
import plistlib

scope = Path("product/local_photo_pipeline_ready_pass_through_001")
runtime = Path("src/product/MediaserverdRuntime.mm").read_text()
hook = Path("src/product/ReferenceCameraHook.mm").read_text()
adapter = Path("src/product/CameraConsumerAdapter.cpp").read_text()
adapter_h = Path("src/product/CameraConsumerAdapter.h").read_text()
ready = Path("src/frame_engine/ReadyFrameQueue.cpp").read_text()
photo = Path("src/media_engine/LocalPhotoReader.mm").read_text()
session = Path("src/media_engine/InternalGalleryMediaSession.mm").read_text()
stager = Path("src/product/SharedMediaStager.mm").read_text()
store = Path("src/product/SharedControlStore.mm").read_text()
owner = Path("src/product/ProductControlOwner.mm").read_text()
state = Path("src/product/ProductControlState.h").read_text()
host = Path("src/product/SpringBoardControlHost.mm").read_text()
gallery = Path("src/control/InternalGalleryViewController.mm").read_text()
proof = (scope / "LocalPhotoPipelineReadyProof.mm").read_text()
proof_h = (scope / "LocalPhotoPipelineReadyProof.h").read_text()
proof_state = (scope / "LocalPhotoPipelineReadyProofState.h").read_text()
witness = (scope / "LocalPhotoPipelineReadyWitness.mm").read_text()
build = (scope / "build_local_photo_pipeline_ready_input.sh").read_text()

if "#if defined(VCAM_LOCAL_PHOTO_PIPELINE_READY_PROOF)" not in runtime:
    raise SystemExit("Photo proof integration is not compile-time scoped")
if "-DVCAM_LOCAL_PHOTO_PIPELINE_READY_PROOF=1" not in build:
    raise SystemExit("Photo proof build define missing")

compact_hook = "".join(hook.split())
for token in (
    "gOriginalCMSampleBufferGetImageBuffer(sampleBuffer)",
    "runtime.observeRealCameraBuffer(original)",
    "runtime.decideCameraBuffer(original)",
):
    if compact_hook.count("".join(token.split())) != 1:
        raise SystemExit(f"Frozen real callback path changed: {token}")

proof_code = proof + "\n" + proof_h + "\n" + witness
for forbidden in (
    "CMSampleBufferGetImageBuffer(",
    "HookedCMSampleBufferGetImageBuffer(",
    "MSHookFunction(",
    "InstallReferenceCameraHook(",
    "decideCameraBuffer(",
    "CameraConsumerAdapter::decide",
    "tryAcquire(",
):
    if forbidden in proof_code:
        raise SystemExit(f"Forbidden proof invocation: {forbidden}")

photo_runtime_markers = (
    "BeginLocalPhotoPipelineSelection",
    "ObserveLocalPhotoCallbackPhase",
    "ObserveLocalPhotoReadyPhase",
    "proofObservedControlGeneration_",
    "observedGeometry_",
    "proofStager_",
    "isExistingOwnedMediaPath",
    "selectedMedia()",
    "SelectedMediaKind::Photo",
    "playbackState()",
    "PlaybackState::Playing",
    "readyQueue().size()",
    "virtualDecisionCount()",
    "kPhotoReadyMaxAttempts = 40",
    "kPhotoReadyRetryNanoseconds",
    "dispatch_after",
)
for token in photo_runtime_markers:
    if token not in runtime:
        raise SystemExit(f"Photo proof runtime marker missing: {token}")

if "readyQueue().tryAcquire" in runtime:
    raise SystemExit("Proof runtime consumes ReadyFrameQueue")
if runtime.count("readyQueue().size()") != 1:
    raise SystemExit("Expected exactly one non-consuming READY existence check")

for token in (
    "snapshot.enabled ||",
    "ProductMediaKind::Photo",
    "snapshot.playbackIntent !=",
    "ProductPlaybackIntent::Playing",
    "facts.readyFrameCount > 0",
    "facts.virtualDecisionCount == 0",
    "decision.kind ==",
    "CameraDecisionKind::Original",
    "decision.reason ==",
    "CameraFailOpenReason::Disabled",
    "decision.pixelBuffer == original",
):
    if token not in runtime:
        raise SystemExit(f"Required proof predicate missing: {token}")

if "gActiveGeneration" not in proof or    "gCallbackGeneration" not in proof or    "gReadyGeneration" not in proof:
    raise SystemExit("Two-phase generation binding missing")
if "active != callback" not in proof or "active != ready" not in proof:
    raise SystemExit("Phase generations are not bound before publication")

if '"com.vcampro.gate.local-photo-pipeline-ready.001"' not in proof_state:
    raise SystemExit("Fresh photo proof identity missing")
for old_identity in (
    "com.vcampro.gate.full-product-real-hook.001",
    "com.vcampro.gate.real-camera-callback-pass-through.001",
):
    if old_identity in proof_state:
        raise SystemExit("Historical proof identity reused")

for token in (
    "VCAM LOCAL PHOTO PIPELINE READY PASS",
    "vcam-enabled=NO",
    "media-kind=PHOTO",
    "media-staged=YES",
    "control-state-observed=YES",
    "camera-geometry-observed=YES",
    "producer-ready=YES",
    "ready-frame-count=>0",
    "camera-callback=EXERCISED",
    "decision=ORIGINAL",
    "original-buffer-returned=YES",
    "frame-substitution=INACTIVE",
    "virtual-decision-count=0",
):
    if token not in witness:
        raise SystemExit(f"Photo witness token missing: {token}")

with (scope / "VCAMPro.LocalPhotoPipelineReady.plist").open("rb") as f:
    product_filter = plistlib.load(f)
with (scope / "VCAMProLocalPhotoPipelineReadyWitness.plist").open("rb") as f:
    witness_filter = plistlib.load(f)
if product_filter != {"Filter": {"Executables": ["SpringBoard", "mediaserverd"]}}:
    raise SystemExit(product_filter)
if witness_filter != {"Filter": {"Executables": ["SpringBoard"]}}:
    raise SystemExit(witness_filter)

for token in (
    "stager_.stageAndValidate(",
    "next.mediaKind = kind;",
    "next.mediaPath = stagedPath;",
    "next.selectionGeneration =",
    "next.loopEnabled = false;",
    "ProductPlaybackIntent::Playing",
):
    if token not in owner:
        raise SystemExit(f"ProductControlOwner staging contract missing: {token}")

for token in (
    "startObserving(",
    "cache_.replace(snapshot)",
    "applyCachedState(",
):
    if token not in runtime:
        raise SystemExit(f"Control propagation marker missing: {token}")

for token in (
    "std::make_unique<LocalPhotoReader>",
    "reader->open(",
):
    if token not in session:
        raise SystemExit(f"Local photo reader path missing: {token}")

for token in (
    "FramePipelinePump",
    "ProducerWakeupDriver",
    "installPipelineForActiveSource",
    "queue_",
):
    if token not in session:
        raise SystemExit(f"Photo pipeline path missing: {token}")

if "std::lock_guard<std::mutex>" not in ready or "entries_.size()" not in ready:
    raise SystemExit("ReadyFrameQueue::size thread-safe implementation missing")

if "isExistingOwnedMediaPath" not in stager:
    raise SystemExit("Owned staged-media validation missing")
if "notify_register_dispatch" not in store:
    raise SystemExit("SharedControlStore observer path missing")

if "bool enabled = false;" not in state:
    raise SystemExit("VCAM disabled default changed")
if "decision.pixelBuffer = original;" not in adapter:
    raise SystemExit("Original buffer fail-open initialization missing")
if adapter.count("virtualDecisionCount_.fetch_add") != 1:
    raise SystemExit("Virtual decision counter semantics changed")

for token in (
    "StartSpringBoardControlHost",
    "ProductControlOwner",
    "colorWithWhite:0.1",
):
    if token not in host:
        raise SystemExit(f"Black Product Control marker missing: {token}")
for token in ("Select Media", "Change", "Clear", "Play", "Pause", "Resume", "Loop", "VCAM ON"):
    if token not in gallery:
        raise SystemExit(f"Product UI marker missing: {token}")

required_build_sources = (
    "LocalVideoReader.mm",
    "LocalPhotoReader.mm",
    "PreparedFrame.cpp",
    "FrameEngineState.cpp",
    "ReadyFrameQueue.cpp",
    "FrameTimelineScheduler.cpp",
    "MonotonicHostClock.cpp",
    "FrameNormalizer.cpp",
    "FrameTransformer.mm",
    "FramePipelinePump.cpp",
    "FramePipelinePumpTimed.cpp",
    "ProducerWakeupController.cpp",
    "ProducerWakeupDriver.mm",
    "InternalGalleryMediaSession.mm",
    "InternalGalleryViewController.mm",
    "SharedControlStore.mm",
    "SharedMediaStager.mm",
    "ProductControlOwner.mm",
    "SpringBoardControlHost.mm",
    "MediaserverdRuntime.mm",
    "CameraConsumerAdapter.cpp",
    "ReferenceCameraHook.mm",
    "VCAMProEntry.mm",
    "LocalPhotoPipelineReadyProof.mm",
)
for token in required_build_sources:
    if token not in build:
        raise SystemExit(f"Full product build source missing: {token}")

for forbidden in (
    "ReferenceCameraHookInstallationReadinessStub",
    "ReferenceCameraHookReachabilityStub",
    "ReferenceCameraHookRuntimeGateStub",
    "MSHookFunctionStub",
    "synthetic callback provider",
    "dummy hook provider",
):
    if forbidden in build or forbidden in proof_code:
        raise SystemExit(f"Forbidden stub/provider present: {forbidden}")

print("FULL_PRODUCT_COMPONENTS_PRESENT=PASS")
print("REFERENCE_CAMERA_HOOK_SOURCE_UNCHANGED=PASS")
print("CAMERA_CONSUMER_ADAPTER_SOURCE_UNCHANGED=PASS")
print("READY_FRAME_QUEUE_SOURCE_UNCHANGED=PASS")
print("LOCAL_PHOTO_READER_SOURCE_UNCHANGED=PASS")
print("INTERNAL_GALLERY_SESSION_SOURCE_UNCHANGED=PASS")
print("SHARED_MEDIA_STAGER_SOURCE_UNCHANGED=PASS")
print("SHARED_CONTROL_STORE_SOURCE_UNCHANGED=PASS")
print("PRODUCT_CONTROL_OWNER_SOURCE_UNCHANGED=PASS")
print("PHOTO_PROOF_COMPILE_TIME_SCOPED=PASS")
print("SYNTHETIC_CALLBACK_TEST_ABSENT=PASS")
print("DIRECT_HOOK_INVOCATION_FROM_PROOF_ABSENT=PASS")
print("DIRECT_CAMERA_TARGET_INVOCATION_FROM_PROOF_ABSENT=PASS")
print("MEDIA_STAGING_PATH_PRESENT=PASS")
print("CONTROL_PROPAGATION_PATH_PRESENT=PASS")
print("PHOTO_READER_PATH_PRESENT=PASS")
print("FRAME_PIPELINE_PATH_PRESENT=PASS")
print("PRODUCER_WAKEUP_PATH_PRESENT=PASS")
print("READY_FRAME_QUEUE_PATH_PRESENT=PASS")
print("READY_FRAME_EXISTENCE_CHECK_NON_CONSUMING=PASS")
print("READY_QUEUE_ACQUIRE_FROM_PROOF_ABSENT=PASS")
print("VCAM_DISABLED_DURING_PROOF_REQUIRED=PASS")
print("PHOTO_MEDIA_KIND_REQUIRED=PASS")
print("CAMERA_GEOMETRY_REQUIRED=PASS")
print("PRODUCER_PLAYING_REQUIRED=PASS")
print("READY_FRAME_COUNT_GREATER_THAN_ZERO_REQUIRED=PASS")
print("CALLBACK_EXERCISED_REQUIRED=PASS")
print("ORIGINAL_DECISION_REQUIRED=PASS")
print("ORIGINAL_PIXEL_BUFFER_REQUIRED=PASS")
print("VIRTUAL_DECISION_COUNT_ZERO_REQUIRED=PASS")
print("FRAME_SUBSTITUTION_INACTIVE=PASS")
print("FAIL_OPEN_BEHAVIOR_PRESERVED=PASS")
print("BLACK_VCAM_PRODUCT_CONTROL_PRESENT=PASS")
print("PHOTO_WITNESS_PRESENT=PASS")
print("PHOTO_WITNESS_SPRINGBOARD_ONLY=PASS")
PY

mkdir -p build/local-photo-proof-state

xcrun --sdk macosx clang++ \
    -std=c++17 -Wall -Wextra -Werror -pedantic \
    -I"$SCOPE" \
    "$SCOPE/local_photo_pipeline_ready_state_tests.cpp" \
    -o build/local-photo-proof-state/tests

build/local-photo-proof-state/tests \
    | tee build/local-photo-proof-state/results.txt

grep -q 'REQUIRED_FLAGS_ACCEPTED=PASS' build/local-photo-proof-state/results.txt
grep -q 'SELECTION_GENERATION_IDENTITY=PASS' build/local-photo-proof-state/results.txt
grep -q 'INCOMPLETE_FLAGS_REJECTED=PASS' build/local-photo-proof-state/results.txt
grep -q 'STALE_STATE_REJECTED=PASS' build/local-photo-proof-state/results.txt
grep -q 'FUTURE_SKEW_LIMIT_ENFORCED=PASS' build/local-photo-proof-state/results.txt
grep -q 'NONZERO_PID_REQUIRED=PASS' build/local-photo-proof-state/results.txt

test "$(git ls-remote origin refs/heads/main | awk '{print $1}')" = "$MAIN"

echo "FRESH_PROOF_REQUIRED=PASS"
echo "NONZERO_PID_REQUIRED=PASS"
echo "MAIN_UNCHANGED=PASS"
echo "DEVICE_ACTION=NO"
