#!/bin/sh
set -eu

START=cbd42f43f0f6e9d48b2a02134a6f6ee9c6d1efbd
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
import re

scope = Path("product/local_photo_pipeline_ready_pass_through_001")
runtime = Path("src/product/MediaserverdRuntime.mm").read_text()
hook = Path("src/product/ReferenceCameraHook.mm").read_text()
adapter = Path("src/product/CameraConsumerAdapter.cpp").read_text()
ready = Path("src/frame_engine/ReadyFrameQueue.cpp").read_text()
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
control = (scope / "control").read_text()

if "#if defined(VCAM_LOCAL_PHOTO_PIPELINE_READY_PROOF)" not in runtime:
    raise SystemExit("Diagnostic code is not compile-time scoped")
if "-DVCAM_LOCAL_PHOTO_PIPELINE_READY_PROOF=1" not in build:
    raise SystemExit("Diagnostic build define missing")

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
    "purgeGeneration(",
    "purgeEpoch(",
    "purgeStale(",
):
    if forbidden in proof_code:
        raise SystemExit(f"Forbidden proof invocation: {forbidden}")

if "readyQueue().tryAcquire" in runtime:
    raise SystemExit("Diagnostic consumes ReadyFrameQueue")
if runtime.count("readyQueue().size()") != 1:
    raise SystemExit("Expected exactly one non-consuming queue size inspection")

# Camera-critical proof slice: atomics + adapter decision + async re-evaluation only.
decide_start = runtime.index("    CameraDecision decide(")
decide_end = runtime.index("    void applyCachedState(", decide_start)
decide = runtime[decide_start:decide_end]
for forbidden in (
    "readyQueue().size()",
    "isExistingOwnedMediaPath",
    "notify_",
    "fopen(",
    "open(",
    "stat(",
    "dispatch_sync(",
    "sleep(",
    "usleep(",
):
    if forbidden in decide:
        raise SystemExit(f"Camera callback proof path contains forbidden work: {forbidden}")
if "dispatch_async(" not in decide:
    raise SystemExit("Callback event-driven re-evaluation missing")

# Exact diagnostic window: 120 x 250 ms = 30 s, plus explicit 30 s constant.
for token in (
    "kPhotoDiagnosticMaxPeriodicChecks =\n            120",
    "kPhotoDiagnosticRetryNanoseconds =\n            INT64_C(250000000)",
    "kPhotoDiagnosticWindowSeconds =\n            30",
):
    if token not in runtime:
        raise SystemExit(f"Diagnostic timing contract missing: {token}")
if 120 * 250_000_000 < 30_000_000_000:
    raise SystemExit("Diagnostic window shorter than 30 seconds")

for token in (
    "beginOrRefreshLocalPhotoDiagnostic();",
    "evaluateLocalPhotoDiagnostic(\n                                    false);",
    "scheduleLocalPhotoDiagnosticFallback(",
    "dispatch_after(",
):
    if token not in runtime:
        raise SystemExit(f"Event/fallback diagnostic scheduling missing: {token}")

if "while (" in runtime:
    raise SystemExit("Busy wait loop present")
for token in ("sleep(", "usleep(", "nanosleep("):
    if token in runtime:
        raise SystemExit(f"Blocking sleep present: {token}")

# Monitor must start from valid PHOTO control, before requiring geometry/session/ready.
begin_start = runtime.index("    void beginOrRefreshLocalPhotoDiagnostic()")
begin_end = runtime.index("    void scheduleLocalPhotoDiagnosticFallback(", begin_start)
begin = runtime[begin_start:begin_end]
for token in (
    "snapshot.mediaKind ==",
    "ProductMediaKind::Photo",
    "snapshot.hasMedia()",
    "snapshot.selectionGeneration != 0",
    "isExistingOwnedMediaPath",
):
    if token not in begin:
        raise SystemExit(f"Early diagnostic lifecycle missing: {token}")
for forbidden in (
    "session_ == nullptr",
    "readyQueue().size()",
    "observedGeometry_.load",
):
    if forbidden in begin:
        raise SystemExit(f"Diagnostic starts too late; depends on {forbidden}")

# Existing observable events and failure points.
for token in (
    "PhotoSelectFailed",
    "ProducerStartFailed",
    "WaitingGeometry",
    "SessionAbsent",
    "WaitingReadyFrame",
    "WaitingCallback",
    "VcamUnexpectedlyEnabled",
    "ControlSuperseded",
):
    if token not in runtime:
        raise SystemExit(f"Pipeline stage not observable: {token}")

select_index = runtime.index("if (!selected)")
select_window = runtime[select_index:select_index + 700]
if "PhotoSelectFailed" not in select_window or "evaluateLocalPhotoDiagnostic" not in select_window:
    raise SystemExit("selectPhoto failure not made observable")

producer_index = runtime.index("if (!producerHealthy)")
producer_window = runtime[producer_index:producer_index + 900]
if "ProducerStartFailed" not in producer_window or "evaluateLocalPhotoDiagnostic" not in producer_window:
    raise SystemExit("producer start failure not made observable")

# producerHealthy must be retained from actual binding result.
bind_start = runtime.index("    void bindCurrentSession(")
bind_end = runtime.index("    static constexpr std::uint32_t", bind_start)
bind = runtime[bind_start:bind_end]
if "recordLocalPhotoProducerState" not in bind or "producerHealthy" not in bind:
    raise SystemExit("Actual producerHealthy binding result not retained")

# Raw callback state is retained, not only strict PASS state.
for token in (
    "gCallbackSequence",
    "gCallbackGeneration",
    "gCallbackFlags",
    "gCallbackVirtualDecisionCount",
    "ReadLocalPhotoCallbackSnapshot",
):
    if token not in proof:
        raise SystemExit(f"Raw callback diagnostic state missing: {token}")

# Structured cross-process transport.
for token in (
    "VCAM_LOCAL_PHOTO_PIPELINE_READY_SELECTION_STATE",
    "VCAM_LOCAL_PHOTO_PIPELINE_READY_FLAGS_STATE",
    "VCAM_LOCAL_PHOTO_PIPELINE_READY_ENUMS_STATE",
    "VCAM_LOCAL_PHOTO_PIPELINE_READY_COUNTS_STATE",
):
    if token not in proof_state or token not in proof or token not in witness:
        raise SystemExit(f"Structured notify transport missing: {token}")

if '"com.vcampro.gate.local-photo-pipeline-ready.remediation-a.001"' not in proof_state:
    raise SystemExit("Remediation-A notification identity missing")
if '"com.vcampro.gate.local-photo-pipeline-ready.001"' in proof_state:
    raise SystemExit("photoready1 identity reused")

for token in (
    "VCAM LOCAL PHOTO PIPELINE READY PASS",
    "VCAM LOCAL PHOTO PIPELINE DIAGNOSTIC",
    "selection-generation=%llu",
    "media-staged=%@",
    "control-state-observed=%@",
    "camera-geometry-observed=%@",
    "session-exists=%@",
    "selected-media-valid=%@",
    "selected-media-kind=%@",
    "selected-media-path-match=%@",
    "playback-intent=%@",
    "playback-state=%@",
    "producer-ready=%@",
    "ready-frame-count=%u",
    "camera-callback-exercised=%@",
    "decision-original=%@",
    "original-buffer-returned=%@",
    "virtual-decision-count=%u",
    "pipeline-stage=%@",
):
    if token not in witness:
        raise SystemExit(f"Visible structured witness field missing: {token}")

if "LocalPhotoProofResult::Diagnostic" not in runtime:
    raise SystemExit("Timeout diagnostic publication missing")
if "LocalPhotoProofResult::Pass" not in runtime:
    raise SystemExit("Strict PASS publication missing")

# No silent non-superseded timeout: timeout path publishes DIAGNOSTIC.
fallback_start = runtime.index("    void scheduleLocalPhotoDiagnosticFallback(")
fallback_end = runtime.index("    void recordLocalPhotoFailureStage(", fallback_start)
fallback = runtime[fallback_start:fallback_end]
if "kPhotoDiagnosticMaxPeriodicChecks" not in fallback or "evaluateLocalPhotoDiagnostic(" not in fallback:
    raise SystemExit("Bounded timeout path missing")
eval_start = runtime.index("    void evaluateLocalPhotoDiagnostic(")
eval_end = runtime.index("#endif", eval_start)
evaluate = runtime[eval_start:eval_end]
if "if (timeout)" not in evaluate or "LocalPhotoProofResult::" not in evaluate or "Diagnostic" not in evaluate:
    raise SystemExit("Silent timeout remains possible in normal timeout path")

# Strict PASS semantics.
for token in (
    "facts.mediaStaged",
    "facts.controlObserved",
    "facts.cameraGeometryObserved",
    "facts.sessionExists",
    "facts.selectedMediaValid",
    "facts.selectedMediaPathMatches",
    "facts.producerReady",
    "facts.readyFrameCount > 0",
    "facts.callbackExercised",
    "facts.originalNonNull",
    "facts.decisionOriginal",
    "facts.disabledReason",
    "facts.originalBufferReturned",
    "facts.virtualDecisionCount == 0",
):
    if token not in evaluate:
        raise SystemExit(f"Strict PASS predicate missing: {token}")

with (scope / "VCAMPro.LocalPhotoPipelineReady.plist").open("rb") as f:
    product_filter = plistlib.load(f)
with (scope / "VCAMProLocalPhotoPipelineReadyWitness.plist").open("rb") as f:
    witness_filter = plistlib.load(f)
if product_filter != {"Filter": {"Executables": ["SpringBoard", "mediaserverd"]}}:
    raise SystemExit(product_filter)
if witness_filter != {"Filter": {"Executables": ["SpringBoard"]}}:
    raise SystemExit(witness_filter)

if "std::lock_guard<std::mutex>" not in ready or "entries_.size()" not in ready:
    raise SystemExit("ReadyFrameQueue::size thread-safe implementation missing")
if "isExistingOwnedMediaPath" not in stager:
    raise SystemExit("Owned staged-media validation missing")
if "notify_register_dispatch" not in store:
    raise SystemExit("SharedControlStore observer path missing")
if "std::make_unique<LocalPhotoReader>" not in session or "reader->open(" not in session:
    raise SystemExit("LocalPhotoReader session path missing")
if "FramePipelinePump" not in session or "ProducerWakeupDriver" not in session:
    raise SystemExit("Frame pipeline/producer path missing")
if "stager_.stageAndValidate(" not in owner:
    raise SystemExit("ProductControlOwner staging path missing")

if "bool enabled = false;" not in state:
    raise SystemExit("VCAM disabled default changed")
if "decision.pixelBuffer = original;" not in adapter:
    raise SystemExit("Fail-open original buffer initialization missing")
if adapter.count("virtualDecisionCount_.fetch_add") != 1:
    raise SystemExit("Virtual decision counter semantics changed")

for token in ("StartSpringBoardControlHost", "ProductControlOwner", "colorWithWhite:0.1"):
    if token not in host:
        raise SystemExit(f"Black Product Control marker missing: {token}")
for token in ("Select Media", "Change", "Clear", "Play", "Pause", "Resume", "Loop", "VCAM ON"):
    if token not in gallery:
        raise SystemExit(f"Product UI marker missing: {token}")

required_build_sources = (
    "LocalVideoReader.mm", "LocalPhotoReader.mm", "PreparedFrame.cpp",
    "FrameEngineState.cpp", "ReadyFrameQueue.cpp", "FrameTimelineScheduler.cpp",
    "MonotonicHostClock.cpp", "FrameNormalizer.cpp", "FrameTransformer.mm",
    "FramePipelinePump.cpp", "FramePipelinePumpTimed.cpp",
    "ProducerWakeupController.cpp", "ProducerWakeupDriver.mm",
    "InternalGalleryMediaSession.mm", "InternalGalleryViewController.mm",
    "SharedControlStore.mm", "SharedMediaStager.mm", "ProductControlOwner.mm",
    "SpringBoardControlHost.mm", "MediaserverdRuntime.mm",
    "CameraConsumerAdapter.cpp", "ReferenceCameraHook.mm", "VCAMProEntry.mm",
    "LocalPhotoPipelineReadyProof.mm",
)
for token in required_build_sources:
    if token not in build:
        raise SystemExit(f"Full product source missing: {token}")

if "0.1.0+roothide10~photoready2" not in build or "0.1.0+roothide10~photoready2" not in control:
    raise SystemExit("photoready2 package version missing")

print("REFERENCE_CAMERA_HOOK_SOURCE_UNCHANGED=PASS")
print("CAMERA_CONSUMER_ADAPTER_SOURCE_UNCHANGED=PASS")
print("READY_FRAME_QUEUE_SOURCE_UNCHANGED=PASS")
print("LOCAL_PHOTO_READER_SOURCE_UNCHANGED=PASS")
print("INTERNAL_GALLERY_SESSION_SOURCE_UNCHANGED=PASS")
print("SHARED_MEDIA_STAGER_SOURCE_UNCHANGED=PASS")
print("SHARED_CONTROL_STORE_SOURCE_UNCHANGED=PASS")
print("PRODUCT_CONTROL_OWNER_SOURCE_UNCHANGED=PASS")
print("DIAGNOSTIC_WITNESS_PRESENT=PASS")
print("PASS_WITNESS_PRESENT=PASS")
print("SILENT_TIMEOUT_REMOVED=PASS")
print("DIAGNOSTIC_WINDOW_AT_LEAST_30_SECONDS=PASS")
print("EVENT_DRIVEN_RECHECK_PRESENT=PASS")
print("BOUNDED_FALLBACK_RECHECK_PRESENT=PASS")
print("BUSY_WAIT_ABSENT=PASS")
print("CAMERA_CALLBACK_BLOCKING_WAIT_ABSENT=PASS")
print("CAMERA_CALLBACK_FILE_IO_ABSENT=PASS")
print("NON_CONSUMING_READY_INSPECTION=PASS")
print("READY_QUEUE_ACQUIRE_FROM_PROOF_ABSENT=PASS")
print("PHOTO_SELECT_FAILURE_OBSERVABLE=PASS")
print("PRODUCER_START_FAILURE_OBSERVABLE=PASS")
print("WAITING_GEOMETRY_OBSERVABLE=PASS")
print("SESSION_ABSENT_OBSERVABLE=PASS")
print("READY_FRAME_ZERO_OBSERVABLE=PASS")
print("RAW_CALLBACK_STATE_OBSERVABLE=PASS")
print("FRESH_DIAGNOSTIC_STATE_REQUIRED=PASS")
print("STALE_PHOTOREADY1_REJECTED=PASS")
print("FRAME_SUBSTITUTION_INACTIVE=PASS")
print("VCAM_DISABLED_DURING_GATE_REQUIRED=PASS")
print("SYNTHETIC_CALLBACK_TEST_ABSENT=PASS")
print("DIRECT_HOOK_INVOCATION_FROM_PROOF_ABSENT=PASS")
print("DIRECT_CAMERA_TARGET_INVOCATION_FROM_PROOF_ABSENT=PASS")
print("FULL_PRODUCT_COMPONENTS_PRESENT=PASS")
print("BLACK_VCAM_PRODUCT_CONTROL_PRESENT=PASS")
PY

mkdir -p build/local-photo-proof-state

xcrun --sdk macosx clang++ \
    -std=c++17 -Wall -Wextra -Werror -pedantic \
    -I"$SCOPE" \
    "$SCOPE/local_photo_pipeline_ready_state_tests.cpp" \
    -o build/local-photo-proof-state/tests

build/local-photo-proof-state/tests \
    | tee build/local-photo-proof-state/results.txt

for marker in \
    PASS_ENCODING_DECODING=PASS \
    DIAGNOSTIC_ENCODING_DECODING=PASS \
    DIAGNOSTIC_BOOLEAN_FIELDS=PASS \
    MEDIA_KIND_ENUM=PASS \
    PLAYBACK_INTENT_ENUM=PASS \
    PLAYBACK_STATE_ENUM=PASS \
    PIPELINE_STAGE_ENUM=PASS \
    SELECTION_GENERATION_TRANSPORT=PASS \
    READY_FRAME_COUNT_TRANSPORT=PASS \
    VIRTUAL_DECISION_COUNT_TRANSPORT=PASS \
    FRESHNESS_ENFORCED=PASS \
    FUTURE_SKEW_LIMIT_ENFORCED=PASS \
    NONZERO_PID_REQUIRED=PASS \
    STALE_STATE_REJECTED=PASS \
    SELECTION_SUPERSESSION_INVALIDATION=PASS; do
    grep -q "$marker" build/local-photo-proof-state/results.txt
done

test "$(git ls-remote origin refs/heads/main | awk '{print $1}')" = "$MAIN"

echo "DIAGNOSTIC_WINDOW_SECONDS=30"
echo "MAIN_UNCHANGED=PASS"
echo "DEVICE_ACTION=NO"
