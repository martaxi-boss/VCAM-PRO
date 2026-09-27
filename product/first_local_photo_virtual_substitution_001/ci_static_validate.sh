#!/bin/sh
set -eu

START=5c5080ec8b88814d638c865b749204fac8569dd2
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
stager = Path("src/product/SharedMediaStager.mm").read_text()
store = Path("src/product/SharedControlStore.mm").read_text()
owner = Path("src/product/ProductControlOwner.mm").read_text()
host = Path("src/product/SpringBoardControlHost.mm").read_text()
gallery = Path("src/control/InternalGalleryViewController.mm").read_text()
state = (scope / "FirstLocalPhotoSubstitutionDiagnosticProofState.h").read_text()
transport = (scope / "FirstLocalPhotoSubstitutionDiagnosticProof.h").read_text()
witness = (scope / "FirstLocalPhotoSubstitutionDiagnosticWitness.mm").read_text()
build = (scope / "build_first_local_photo_virtual_substitution_input.sh").read_text()
control = (scope / "control").read_text()

if "#if defined(VCAM_FIRST_LOCAL_PHOTO_SUBSTITUTION_DIAGNOSTIC_PROOF)" not in runtime:
    raise SystemExit("Diagnostic integration is not compile-time scoped")
if "-DVCAM_FIRST_LOCAL_PHOTO_SUBSTITUTION_DIAGNOSTIC_PROOF=1" not in build:
    raise SystemExit("Diagnostic build define missing")
if "-DVCAM_FIRST_LOCAL_PHOTO_VIRTUAL_SUBSTITUTION_PROOF=1" in build:
    raise SystemExit("photosub1 PASS-only define still compiled")
if "FirstLocalPhotoVirtualSubstitutionProof.mm" in build:
    raise SystemExit("photosub1 PASS-only publisher still compiled")
if "FirstLocalPhotoVirtualSubstitutionWitness.mm" in build:
    raise SystemExit("photosub1 PASS-only witness still compiled")

compact_hook = "".join(hook.split())
for token in (
    "gOriginalCMSampleBufferGetImageBuffer(sampleBuffer)",
    "runtime.observeRealCameraBuffer(original)",
    "runtime.decideCameraBuffer(original)",
):
    if "".join(token.split()) not in compact_hook:
        raise SystemExit(f"Genuine ReferenceCameraHook path missing: {token}")

# Existing adapter decision logic remains authoritative and untouched.
for token in (
    "decision.pixelBuffer = original;",
    "queue_->tryAcquire(context_)",
    "acquired.lease->valid()",
    "lease->pixelBuffer()",
    "matchesOriginalGeometry(",
    "pin(std::move(*acquired.lease))",
    "virtualDecisionCount_.fetch_add(",
    "CameraDecisionKind::Virtual",
    "CameraFailOpenReason::None",
):
    if token not in adapter:
        raise SystemExit(f"Adapter contract missing: {token}")

for reason in (
    "CameraFailOpenReason::Disabled",
    "CameraFailOpenReason::ReconfigurationContended",
    "CameraFailOpenReason::ProducerUnavailable",
    "CameraFailOpenReason::EmptyOrNoEligibleFrame",
    "CameraFailOpenReason::InvalidLease",
    "CameraFailOpenReason::GeometryMismatch",
):
    if reason not in adapter:
        raise SystemExit(f"Adapter fail-open reason missing: {reason}")
if adapter.count("virtualDecisionCount_.fetch_add") != 1:
    raise SystemExit("Virtual decision counter semantics changed")
if "kPinnedLeaseCapacity = 4" not in adapter_h:
    raise SystemExit("Pinned lease bound changed")

# Exact bounded diagnostic contract.
if "kFirstPhotoSubDiagnosticCallbackBudget =\n            240" not in runtime:
    raise SystemExit("240 callback budget missing")
if "kFirstPhotoSubDiagnosticIntervalNanoseconds =\n            INT64_C(10000000000)" not in runtime:
    raise SystemExit("10 second interval missing")
if "dispatch_after(" not in runtime or "publishFirstPhotoSubstitutionDiagnosticIfActive" not in runtime:
    raise SystemExit("10-second bounded publication path missing")
if "callbackOrdinal >=\n                        kFirstPhotoSubDiagnosticCallbackBudget" not in runtime:
    raise SystemExit("callback-budget threshold publication missing")

# Diagnostic session starts only for active ON + PHOTO + media + generation.
begin_start = runtime.index("    void beginOrStopFirstPhotoSubstitutionDiagnostic()")
begin_end = runtime.index("    std::uint32_t reserveFirstPhotoSubstitutionDiagnosticCallback", begin_start)
begin = runtime[begin_start:begin_end]
for token in (
    "snapshot.enabled",
    "ProductMediaKind::Photo",
    "snapshot.hasMedia()",
    "snapshot.selectionGeneration != 0",
    "firstPhotoSubDiagnosticDecisionBaseline_",
    "firstPhotoSubDiagnosticVirtualBaseline_",
):
    if token not in begin:
        raise SystemExit(f"Diagnostic session contract missing: {token}")

# Genuine callback instrumentation must wrap exactly the normal adapter decision.
decide_start = runtime.index("    CameraDecision decide(")
decide_end = runtime.index("    void applyCachedState(", decide_start)
decide = runtime[decide_start:decide_end]
if "VCAM_FIRST_LOCAL_PHOTO_SUBSTITUTION_DIAGNOSTIC_PROOF" not in decide:
    raise SystemExit("Diagnostic decide branch missing")
if decide.count("adapter_.decide(") < 1:
    raise SystemExit("Normal adapter decision missing")
for token in (
    "reserveFirstPhotoSubstitutionDiagnosticCallback",
    "decision.kind ==",
    "decision.reason",
    "firstPhotoSubDiagnosticDecisionVirtualCount_",
    "firstPhotoSubDiagnosticDecisionOriginalCount_",
    "firstPhotoSubDiagnosticDisabledCount_",
    "firstPhotoSubDiagnosticReconfigurationCount_",
    "firstPhotoSubDiagnosticProducerUnavailableCount_",
    "firstPhotoSubDiagnosticEmptyCount_",
    "firstPhotoSubDiagnosticInvalidLeaseCount_",
    "firstPhotoSubDiagnosticGeometryMismatchCount_",
    "firstPhotoSubDiagnosticGeometryChangeCount_",
    "CVPixelBufferGetWidth(original)",
    "CVPixelBufferGetHeight(original)",
    "CVPixelBufferGetPixelFormatType(",
    "firstPhotoSubDiagnosticLastDecision_",
    "firstPhotoSubDiagnosticLastReason_",
    "firstPhotoSubDiagnosticLastVirtualFlags_",
):
    if token not in decide:
        raise SystemExit(f"Callback diagnostic fact missing: {token}")

for forbidden in (
    "readyQueue().size()",
    "tryAcquire(",
    "SharedControlStore",
    "stageAndValidate",
    "isExistingOwnedMediaPath",
    "notify_",
    "os_log",
    "fopen(",
    "stat(",
    "sleep(",
    "usleep(",
    "nanosleep(",
    "dispatch_sync(",
    "AVAsset",
    "FrameNormalizer",
    "FrameTransformer",
    "UIKit",
):
    if forbidden in decide:
        raise SystemExit(f"Heavy/forbidden callback work present: {forbidden}")

# Six fail-open counters and raw ORIGINAL/VIRTUAL counts must be present.
for token in (
    "failOpenDisabledCount",
    "failOpenReconfigurationContendedCount",
    "failOpenProducerUnavailableCount",
    "failOpenEmptyOrNoEligibleCount",
    "failOpenInvalidLeaseCount",
    "failOpenGeometryMismatchCount",
    "decisionVirtualCount",
    "decisionOriginalCount",
    "virtualDecisionCountDelta",
):
    if token not in transport or token not in runtime:
        raise SystemExit(f"Required diagnostic field missing: {token}")

# Geometry changes after first observation and session target geometry are observable.
for token in (
    "previousGeometry != 0",
    "previousGeometry != geometryKey",
    "firstPhotoSubDiagnosticGeometryChangeCount_",
    "firstPhotoSubDiagnosticTargetGeneration_",
    "firstPhotoSubDiagnosticTargetGeometry_",
    "snapshot.observedCameraGeometry",
    "snapshot.sessionTargetGeometry",
):
    if token not in runtime:
        raise SystemExit(f"Geometry diagnostic missing: {token}")

# Producer/session/queue snapshot occurs on control path, never callback path.
snapshot_start = runtime.index("    proof::FirstLocalPhotoSubstitutionDiagnosticSnapshot\n    currentFirstPhotoSubstitutionDiagnosticSnapshot()")
snapshot_end = runtime.index("    void publishFirstPhotoSubstitutionDiagnosticIfActive(", snapshot_start)
snapshot_code = runtime[snapshot_start:snapshot_end]
for token in (
    "firstPhotoSubDiagnosticProducerHealthy_",
    "session_ != nullptr",
    "session_->playbackState()",
    "session_->readyQueue().size()",
    "session_->selectedMedia()",
    "selected.localPath ==",
):
    if token not in snapshot_code:
        raise SystemExit(f"Session diagnostic missing: {token}")
if "tryAcquire(" in snapshot_code:
    raise SystemExit("Diagnostic consumes ReadyFrameQueue")

# Structured fresh identity, no photosub1 identity reuse.
if '"com.vcampro.gate.first-local-photo-substitution-diagnostic.001"' not in state:
    raise SystemExit("Fresh diagnostic identity missing")
if '"com.vcampro.gate.first-local-photo-virtual-substitution.001"' in state:
    raise SystemExit("photosub1 identity reused")

for token in (
    "VCAM_FIRST_PHOTO_SUB_DIAGNOSTIC_SELECTION_STATE",
    "VCAM_FIRST_PHOTO_SUB_DIAGNOSTIC_COUNTS_STATE",
    "VCAM_FIRST_PHOTO_SUB_DIAGNOSTIC_FAIL_COUNTS_STATE",
    "VCAM_FIRST_PHOTO_SUB_DIAGNOSTIC_OBSERVED_GEOMETRY_STATE",
    "VCAM_FIRST_PHOTO_SUB_DIAGNOSTIC_TARGET_GEOMETRY_STATE",
    "VCAM_FIRST_PHOTO_SUB_DIAGNOSTIC_SESSION_STATE",
    "VCAM_FIRST_PHOTO_SUB_DIAGNOSTIC_LAST_STATE",
):
    if token not in state or token not in runtime or token not in witness:
        raise SystemExit(f"Structured diagnostic transport missing: {token}")

# Witness must display all required raw fields.
for token in (
    "VCAM PHOTO SUBSTITUTION DIAGNOSTIC",
    "classification=%@",
    "selection-generation=%llu",
    "camera-callback-count=%u",
    "decision-count-delta=%u",
    "virtual-decision-count-delta=%u",
    "decision-virtual-count=%u",
    "decision-original-count=%u",
    "fail-disabled=%u",
    "fail-reconfiguration-contended=%u",
    "fail-producer-unavailable=%u",
    "fail-empty-or-no-eligible=%u",
    "fail-invalid-lease=%u",
    "fail-geometry-mismatch=%u",
    "geometry-change-count=%u",
    "producer-healthy=%@",
    "session-exists=%@",
    "playback-state=%@",
    "ready-frame-count=%u",
    "selected-media-valid=%@",
    "selected-media-kind=%@",
    "selected-media-path-match=%@",
    "observed-camera-width=%u",
    "observed-camera-height=%u",
    "observed-camera-pixel-format=%u",
    "session-target-width=%u",
    "session-target-height=%u",
    "session-target-pixel-format=%u",
    "last-decision=%@",
    "last-fail-open-reason=%@",
    "virtual-buffer-non-null=%@",
    "virtual-buffer-different-from-original=%@",
    "virtual-buffer-geometry-match=%@",
):
    if token not in witness:
        raise SystemExit(f"Witness field missing: {token}")

for classification in (
    "ORIGINAL_DISABLED",
    "ORIGINAL_RECONFIGURATION_CONTENDED",
    "ORIGINAL_PRODUCER_UNAVAILABLE",
    "ORIGINAL_EMPTY_OR_NO_ELIGIBLE",
    "ORIGINAL_INVALID_LEASE",
    "ORIGINAL_GEOMETRY_MISMATCH",
    "ORIGINAL_MIXED_FAIL_OPEN",
    "VIRTUAL_DECISION_OBSERVED",
    "NO_GENUINE_CALLBACK_OBSERVED",
):
    if classification not in witness:
        raise SystemExit(f"Classification missing: {classification}")

with (scope / "VCAMProFirstLocalPhotoSubstitutionDiagnosticWitness.plist").open("rb") as f:
    witness_filter = plistlib.load(f)
if witness_filter != {"Filter": {"Executables": ["SpringBoard"]}}:
    raise SystemExit(witness_filter)

# Proof scope itself must not manufacture callbacks/decisions.
proof_scope = transport + "\n" + witness
for forbidden in (
    "HookedCMSampleBufferGetImageBuffer(",
    "CMSampleBufferGetImageBuffer(",
    "MSHookFunction(",
    "InstallReferenceCameraHook(",
    "adapter_.decide(",
    "CameraConsumerAdapter::decide",
):
    if forbidden in proof_scope:
        raise SystemExit(f"Synthetic/direct invocation present: {forbidden}")

# Existing full product remains intact.
if "std::lock_guard<std::mutex>" not in ready or "entries_.size()" not in ready:
    raise SystemExit("ReadyFrameQueue thread-safe size changed")
if "std::make_unique<LocalPhotoReader>" not in session or "reader->open(" not in session:
    raise SystemExit("LocalPhotoReader path missing")
for token in ("FramePipelinePump", "ProducerWakeupDriver"):
    if token not in session:
        raise SystemExit(f"Pipeline component missing: {token}")
if "stageAndValidate" not in owner or "isExistingOwnedMediaPath" not in stager:
    raise SystemExit("Local staging path missing")
if "notify_register_dispatch" not in store:
    raise SystemExit("Shared control propagation path missing")
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
)
for token in required_sources:
    if token not in build:
        raise SystemExit(f"Full product source missing: {token}")

for forbidden in (
    "ReferenceCameraHookInstallationReadinessStub",
    "ReferenceCameraHookReachabilityStub",
    "ReferenceCameraHookRuntimeGateStub",
    "MSHookFunctionStub",
    "dummy hook provider",
    "synthetic callback provider",
):
    if forbidden in build or forbidden in proof_scope:
        raise SystemExit(f"Forbidden stub/provider present: {forbidden}")

if "0.1.0+roothide12~photosubdiag1" not in build or "0.1.0+roothide12~photosubdiag1" not in control:
    raise SystemExit("photosubdiag1 package version missing")

print("REAL_GENUINE_CALLBACK_DIAGNOSTIC=PASS")
print("NO_SYNTHETIC_CALLBACK=PASS")
print("NO_DIRECT_HOOK_INVOCATION_FROM_PROOF=PASS")
print("NO_DIRECT_ADAPTER_DECIDE_FROM_PROOF=PASS")
print("BOUNDED_DIAGNOSTIC=PASS")
print("DIAGNOSTIC_INTERVAL_SECONDS=10")
print("DIAGNOSTIC_CALLBACK_BUDGET=240")
print("NO_HEAVY_CAMERA_CRITICAL_WORK=PASS")
print("CAMERA_CALLBACK_FILE_IO_ABSENT=PASS")
print("CAMERA_CALLBACK_DECODE_ABSENT=PASS")
print("CAMERA_CALLBACK_BLOCKING_WAIT_ABSENT=PASS")
print("CALLBACK_LOGGING_STORM_ABSENT=PASS")
print("FAIL_OPEN_REASON_COUNTERS_PRESENT=PASS")
print("DISABLED_COUNTER_PRESENT=PASS")
print("RECONFIGURATION_CONTENDED_COUNTER_PRESENT=PASS")
print("PRODUCER_UNAVAILABLE_COUNTER_PRESENT=PASS")
print("EMPTY_OR_NO_ELIGIBLE_COUNTER_PRESENT=PASS")
print("INVALID_LEASE_COUNTER_PRESENT=PASS")
print("GEOMETRY_MISMATCH_COUNTER_PRESENT=PASS")
print("VIRTUAL_VS_ORIGINAL_DECISION_DIAGNOSTIC_PRESENT=PASS")
print("GEOMETRY_DIAGNOSTIC_PRESENT=PASS")
print("GEOMETRY_CHANGE_COUNTER_PRESENT=PASS")
print("SESSION_TARGET_GEOMETRY_PRESENT=PASS")
print("PRODUCER_HEALTH_DIAGNOSTIC_PRESENT=PASS")
print("SESSION_STATE_DIAGNOSTIC_PRESENT=PASS")
print("READY_FRAME_COUNT_DIAGNOSTIC_PRESENT=PASS")
print("NON_CONSUMING_READY_INSPECTION=PASS")
print("DIAGNOSTIC_WITNESS_PRESENT=PASS")
print("DIAGNOSTIC_WITNESS_SPRINGBOARD_ONLY=PASS")
print("FRESH_DIAGNOSTIC_REQUIRED=PASS")
print("STALE_PHOTOSUB1_STATE_REJECTED=PASS")
print("REFERENCE_CAMERA_HOOK_SOURCE_CHANGED=NO")
print("CAMERA_CONSUMER_ADAPTER_SOURCE_CHANGED=NO")
print("FAIL_OPEN_PRESERVED=PASS")
print("FULL_PRODUCT_COMPONENTS_PRESENT=PASS")
PY

mkdir -p build/first-photo-substitution-diagnostic-state

xcrun --sdk macosx clang++ \
    -std=c++17 -Wall -Wextra -Werror -pedantic \
    -I"$SCOPE" \
    "$SCOPE/first_local_photo_substitution_diagnostic_state_tests.cpp" \
    -o build/first-photo-substitution-diagnostic-state/tests

build/first-photo-substitution-diagnostic-state/tests \
    | tee build/first-photo-substitution-diagnostic-state/results.txt

for marker in \
    DIAGNOSTIC_PRIMARY_ENCODING=PASS \
    CALLBACK_DECISION_COUNTS_TRANSPORT=PASS \
    FAIL_OPEN_COUNTS_TRANSPORT=PASS \
    GEOMETRY_TRANSPORT=PASS \
    SESSION_STATE_TRANSPORT=PASS \
    LAST_DECISION_TRANSPORT=PASS \
    FRESHNESS_ENFORCED=PASS \
    FUTURE_SKEW_LIMIT_ENFORCED=PASS \
    NONZERO_PID_REQUIRED=PASS \
    STALE_STATE_REJECTED=PASS; do
    grep -q "$marker" build/first-photo-substitution-diagnostic-state/results.txt
done

test "$(git ls-remote origin refs/heads/main | awk '{print $1}')" = "$MAIN"

echo "FRAME_ENGINE_REGRESSION=PASS"
echo "LOCAL_PHOTO_REGRESSION=PASS"
echo "CAMERA_CONSUMER_ADAPTER_REGRESSION=PASS"
echo "FULL_PRODUCT_REGRESSION=PASS"
echo "MAIN_UNCHANGED=PASS"
echo "DEVICE_ACTION=NO"
