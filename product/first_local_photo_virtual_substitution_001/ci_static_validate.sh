#!/bin/sh
set -eu

START=7ffcca077d7d38afcd25278b740d040f52ff0842
MAIN=d476caacc4f557843f9551533c2fcbe7c5d40baa
SCOPE=product/first_local_photo_virtual_substitution_001

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
check_blob src/media_engine/InternalGalleryMediaSession.mm a73891bb5080e3fafe9cdd98be13604e23584c59
check_blob src/product/SharedMediaStager.mm d3c144d4ca2f522d438fd98266ac3e03bd50b38d
check_blob src/product/SharedControlStore.mm 0227cd19b48d6fcff9a97d0a28d6aa3283badadd
check_blob src/product/ProductControlOwner.mm 9e2909da17142127bbef2448891da02d8c95c516
check_blob src/product/MediaserverdRuntime.h 880143505c07450a2c47cb345722371fa820e2e9

test "$(git merge-base "$START" HEAD)" = "$START"

changed="$(git diff --name-only "$START"..HEAD)"
printf '%s\n' "$changed" | while IFS= read -r item; do
    test -n "$item" || continue
    case "$item" in
        "$SCOPE"/*|src/product/MediaserverdRuntime.mm|docs/CANONICAL_PROJECT_STATE.md|.github/workflows/first-local-photo-virtual-substitution-001-ci.yml)
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

scope = Path("product/first_local_photo_virtual_substitution_001")
runtime = Path("src/product/MediaserverdRuntime.mm").read_text()
hook = Path("src/product/ReferenceCameraHook.mm").read_text()
adapter = Path("src/product/CameraConsumerAdapter.cpp").read_text()
adapter_h = Path("src/product/CameraConsumerAdapter.h").read_text()
ready = Path("src/frame_engine/ReadyFrameQueue.cpp").read_text()
session = Path("src/media_engine/InternalGalleryMediaSession.mm").read_text()
photo = Path("src/media_engine/LocalPhotoReader.mm").read_text()
owner = Path("src/product/ProductControlOwner.mm").read_text()
host = Path("src/product/SpringBoardControlHost.mm").read_text()
gallery = Path("src/control/InternalGalleryViewController.mm").read_text()
proof = (scope / "FirstLocalPhotoVirtualSubstitutionProof.mm").read_text()
proof_h = (scope / "FirstLocalPhotoVirtualSubstitutionProof.h").read_text()
proof_state = (scope / "FirstLocalPhotoVirtualSubstitutionProofState.h").read_text()
witness = (scope / "FirstLocalPhotoVirtualSubstitutionWitness.mm").read_text()
build = (scope / "build_first_local_photo_virtual_substitution_input.sh").read_text()
control = (scope / "control").read_text()

if "#if defined(VCAM_FIRST_LOCAL_PHOTO_VIRTUAL_SUBSTITUTION_PROOF)" not in runtime:
    raise SystemExit("First substitution proof not compile-time scoped")
if "-DVCAM_FIRST_LOCAL_PHOTO_VIRTUAL_SUBSTITUTION_PROOF=1" not in build:
    raise SystemExit("First substitution build define missing")
if "VCAM_LOCAL_PHOTO_PIPELINE_READY_PROOF" in build or "LocalPhotoPipelineReadyProof" in build:
    raise SystemExit("Old photoready2 proof compiled into substitution package")

compact_hook = "".join(hook.split())
for token in (
    "gOriginalCMSampleBufferGetImageBuffer(sampleBuffer)",
    "runtime.observeRealCameraBuffer(original)",
    "runtime.decideCameraBuffer(original)",
    "return decision.pixelBuffer != nullptr?decision.pixelBuffer:original",
):
    compact = "".join(token.split())
    if compact not in compact_hook:
        raise SystemExit(f"Real ReferenceCameraHook callback path missing: {token}")

for token in (
    "queue_->tryAcquire(context_)",
    "acquired.lease->valid()",
    "lease->pixelBuffer()",
    "matchesOriginalGeometry(",
    "pin(std::move(*acquired.lease))",
    "virtualDecisionCount_.fetch_add(",
    "CameraDecisionKind::Virtual",
    "CameraFailOpenReason::None",
    "decision.pixelBuffer = selected",
):
    if token not in adapter:
        raise SystemExit(f"Existing virtual decision path missing: {token}")

if adapter.count("virtualDecisionCount_.fetch_add") != 1:
    raise SystemExit("Virtual decision counter has unexpected increments")
if "decision.pixelBuffer = original;" not in adapter:
    raise SystemExit("Fail-open original buffer default missing")
for reason in (
    "CameraFailOpenReason::Disabled",
    "ReconfigurationContended",
    "ProducerUnavailable",
    "EmptyOrNoEligibleFrame",
    "InvalidLease",
    "GeometryMismatch",
):
    if reason not in adapter:
        raise SystemExit(f"Fail-open reason missing: {reason}")

if "kPinnedLeaseCapacity = 4" not in adapter_h:
    raise SystemExit("Pinned lease bound changed")

if "std::make_unique<LocalPhotoReader>" not in session or "reader->open(" not in session:
    raise SystemExit("LocalPhotoReader path missing")
for token in ("FramePipelinePump", "ProducerWakeupDriver", "readyQueue()"):
    if token not in session:
        raise SystemExit(f"Local photo pipeline component missing: {token}")
if "stageAndValidate" not in owner:
    raise SystemExit("SharedMediaStager product selection path missing")

# READY prerequisite is computed outside callback and observes queue non-destructively.
for token in (
    "beginFirstPhotoSubstitutionReadyCheck",
    "checkFirstPhotoSubstitutionReady",
    "firstPhotoSubstitutionReadyGeneration_.store(",
    "selected.valid",
    "SelectedMediaKind::Photo",
    "selected.localPath ==",
    "PlaybackState::Playing",
    "firstPhotoSubstitutionProducerHealthy_",
    "session_->readyQueue().size() > 0",
):
    if token not in runtime:
        raise SystemExit(f"Media READY prerequisite missing: {token}")

if runtime.count("session_->readyQueue().size() > 0") != 1:
    raise SystemExit("Unexpected READY queue inspection count")
ready_check_start = runtime.index("    void checkFirstPhotoSubstitutionReady(")
ready_check_end = runtime.index("#endif", ready_check_start)
ready_check = runtime[ready_check_start:ready_check_end]
if "tryAcquire(" in ready_check:
    raise SystemExit("Proof READY check consumes a frame")
for forbidden in ("publish(", "purgeGeneration(", "purgeEpoch(", "purgeStale("):
    if forbidden in ready_check:
        raise SystemExit(f"Proof READY check mutates queue: {forbidden}")

# Callback proof must only wrap the normal adapter decision with lightweight facts.
decide_start = runtime.index("    CameraDecision decide(")
decide_end = runtime.index("    void applyCachedState(", decide_start)
decide = runtime[decide_start:decide_end]
if decide.count("adapter_.decide(") < 1:
    raise SystemExit("Normal CameraConsumerAdapter decision missing")
for required in (
    "firstPhotoSubstitutionReadyGeneration_.load(",
    "adapter_.decisionCount()",
    "adapter_.virtualDecisionCount()",
    "CameraDecisionKind::Virtual",
    "CameraFailOpenReason::None",
    "decision.pixelBuffer != original",
    "CVPixelBufferGetWidth(original)",
    "CVPixelBufferGetWidth(",
    "CVPixelBufferGetHeight(original)",
    "CVPixelBufferGetPixelFormatType(original)",
    "virtualDecisionCountAfter ==",
    "virtualDecisionCountBefore + 1U",
    "decisionCountAfter ==",
    "decisionCountBefore + 1U",
    "ObserveFirstLocalPhotoVirtualSubstitution",
):
    if required not in decide:
        raise SystemExit(f"Callback proof predicate missing: {required}")

for forbidden in (
    "readyQueue().size()",
    "tryAcquire(",
    "stageAndValidate",
    "isExistingOwnedMediaPath",
    "SharedControlStore",
    "notify_",
    "fopen(",
    "stat(",
    "sleep(",
    "usleep(",
    "nanosleep(",
    "dispatch_sync(",
    "AVAsset",
    "decode",
    "FrameNormalizer",
    "FrameTransformer",
    "UIKit",
):
    if forbidden in decide:
        raise SystemExit(f"Heavy/forbidden callback work present: {forbidden}")

proof_code = proof + "\n" + proof_h + "\n" + witness
for forbidden in (
    "CMSampleBufferGetImageBuffer(",
    "HookedCMSampleBufferGetImageBuffer(",
    "MSHookFunction(",
    "InstallReferenceCameraHook(",
    "decideCameraBuffer(",
    "CameraConsumerAdapter::decide",
    "adapter_.decide(",
):
    if forbidden in proof_code:
        raise SystemExit(f"Direct hook/adapter invocation from proof: {forbidden}")

for token in (
    "facts.originalNonNull",
    "facts.vcamEnabled",
    "facts.photoSelected",
    "facts.mediaReady",
    "facts.cameraGeometryObserved",
    "facts.callbackExercised",
    "facts.decisionVirtual",
    "facts.decisionReasonNone",
    "facts.virtualBufferNonNull",
    "facts.virtualBufferDifferentFromOriginal",
    "facts.geometryMatch",
    "facts.decisionCountIncremented",
    "facts.virtualDecisionCountIncremented",
    "facts.virtualDecisionCountAfter > 0",
    "dispatch_async(",
):
    if token not in proof:
        raise SystemExit(f"Proof publication predicate missing: {token}")

if '"com.vcampro.gate.first-local-photo-virtual-substitution.001"' not in proof_state:
    raise SystemExit("Fresh substitution proof identity missing")

for token in (
    "VCAM LOCAL PHOTO VIRTUAL SUBSTITUTION PASS",
    "vcam-enabled=YES",
    "media-kind=PHOTO",
    "media-ready=YES",
    "camera-geometry-observed=YES",
    "camera-callback=EXERCISED",
    "decision=VIRTUAL",
    "virtual-buffer-non-null=YES",
    "virtual-buffer-different-from-original=YES",
    "geometry-match=YES",
    "virtual-decision-count=>0",
    "frame-substitution=ACTIVE",
):
    if token not in witness:
        raise SystemExit(f"Visible substitution witness token missing: {token}")

with (scope / "VCAMPro.FirstLocalPhotoVirtualSubstitution.plist").open("rb") as f:
    product_filter = plistlib.load(f)
with (scope / "VCAMProFirstLocalPhotoVirtualSubstitutionWitness.plist").open("rb") as f:
    witness_filter = plistlib.load(f)
if product_filter != {"Filter": {"Executables": ["SpringBoard", "mediaserverd"]}}:
    raise SystemExit(product_filter)
if witness_filter != {"Filter": {"Executables": ["SpringBoard"]}}:
    raise SystemExit(witness_filter)

if "std::lock_guard<std::mutex>" not in ready or "entries_.size()" not in ready:
    raise SystemExit("ReadyFrameQueue size implementation changed")

for token in ("StartSpringBoardControlHost", "ProductControlOwner", "colorWithWhite:0.1"):
    if token not in host:
        raise SystemExit(f"Black Product Control marker missing: {token}")
for token in ("Select Media", "Change", "Clear", "Play", "Pause", "Resume", "Loop", "VCAM ON"):
    if token not in gallery:
        raise SystemExit(f"Product UI marker missing: {token}")

required_sources = (
    "LocalVideoReader.mm", "LocalPhotoReader.mm", "PreparedFrame.cpp",
    "FrameEngineState.cpp", "ReadyFrameQueue.cpp", "FrameTimelineScheduler.cpp",
    "MonotonicHostClock.cpp", "FrameNormalizer.cpp", "FrameTransformer.mm",
    "FramePipelinePump.cpp", "FramePipelinePumpTimed.cpp",
    "ProducerWakeupController.cpp", "ProducerWakeupDriver.mm",
    "InternalGalleryMediaSession.mm", "InternalGalleryViewController.mm",
    "SharedControlStore.mm", "SharedMediaStager.mm", "ProductControlOwner.mm",
    "SpringBoardControlHost.mm", "MediaserverdRuntime.mm",
    "CameraConsumerAdapter.cpp", "ReferenceCameraHook.mm", "VCAMProEntry.mm",
    "FirstLocalPhotoVirtualSubstitutionProof.mm",
)
for token in required_sources:
    if token not in build:
        raise SystemExit(f"Full product build source missing: {token}")

for forbidden in (
    "ReferenceCameraHookInstallationReadinessStub",
    "ReferenceCameraHookReachabilityStub",
    "ReferenceCameraHookRuntimeGateStub",
    "MSHookFunctionStub",
    "dummy hook provider",
    "synthetic callback provider",
):
    if forbidden in build or forbidden in proof_code:
        raise SystemExit(f"Forbidden stub/provider present: {forbidden}")

if "0.1.0+roothide11~photosub1" not in build or "0.1.0+roothide11~photosub1" not in control:
    raise SystemExit("photosub1 version missing")

print("FULL_PRODUCT_COMPONENTS_PRESENT=PASS")
print("LOCAL_PHOTO_PATH_PRESENT=PASS")
print("REAL_REFERENCE_HOOK_PRESENT=PASS")
print("READY_QUEUE_CONSUMER_PATH_PRESENT=PASS")
print("CAMERA_CONSUMER_ADAPTER_VIRTUAL_PATH_PRESENT=PASS")
print("VIRTUAL_DECISION_COUNTER_PATH_PRESENT=PASS")
print("PINNED_LEASE_PATH_PRESENT=PASS")
print("GEOMETRY_MATCH_GUARD_PRESENT=PASS")
print("FIRST_PHOTO_SUBSTITUTION_PROOF_COMPILE_TIME_SCOPED=PASS")
print("GENUINE_CALLBACK_REQUIRED=PASS")
print("MEDIA_READY_REQUIRED=PASS")
print("VCAM_ENABLED_REQUIRED=PASS")
print("PHOTO_MEDIA_KIND_REQUIRED=PASS")
print("DECISION_VIRTUAL_REQUIRED=PASS")
print("VIRTUAL_BUFFER_NON_NULL_REQUIRED=PASS")
print("VIRTUAL_BUFFER_DIFFERENT_FROM_ORIGINAL_REQUIRED=PASS")
print("GEOMETRY_MATCH_REQUIRED=PASS")
print("VIRTUAL_DECISION_INCREMENT_REQUIRED=PASS")
print("NO_SYNTHETIC_CALLBACK=PASS")
print("NO_DIRECT_HOOK_INVOCATION_FROM_PROOF=PASS")
print("NO_DIRECT_ADAPTER_DECIDE_FROM_PROOF=PASS")
print("NO_HEAVY_CAMERA_CALLBACK_WORK=PASS")
print("NO_CAMERA_CALLBACK_FILE_IO=PASS")
print("NO_CAMERA_CALLBACK_DECODE=PASS")
print("NO_CAMERA_CALLBACK_BLOCKING_WAIT=PASS")
print("FAIL_OPEN_PRESERVED=PASS")
print("VISIBLE_SUBSTITUTION_WITNESS_PRESENT=PASS")
print("VISIBLE_SUBSTITUTION_WITNESS_SPRINGBOARD_ONLY=PASS")
PY

mkdir -p build/first-photo-substitution-state

xcrun --sdk macosx clang++ \
    -std=c++17 -Wall -Wextra -Werror -pedantic \
    -I"$SCOPE" \
    "$SCOPE/first_local_photo_virtual_substitution_state_tests.cpp" \
    -o build/first-photo-substitution-state/tests

build/first-photo-substitution-state/tests \
    | tee build/first-photo-substitution-state/results.txt

for marker in \
    REQUIRED_FLAGS_ACCEPTED=PASS \
    INCOMPLETE_FLAGS_REJECTED=PASS \
    SELECTION_GENERATION_REQUIRED=PASS \
    FRESHNESS_ENFORCED=PASS \
    FUTURE_SKEW_LIMIT_ENFORCED=PASS \
    NONZERO_PID_REQUIRED=PASS; do
    grep -q "$marker" build/first-photo-substitution-state/results.txt
done

test "$(git ls-remote origin refs/heads/main | awk '{print $1}')" = "$MAIN"

echo "MAIN_UNCHANGED=PASS"
echo "DEVICE_ACTION=NO"
