#!/bin/sh
set -eu

START=10f2a2518f6fe844121b0c9473e2619500efbde1
MAIN=d476caacc4f557843f9551533c2fcbe7c5d40baa
HOOK_BLOB=b3b5360757d17951b0c508ab455d7ea4ffb0d6fe
ADAPTER_CPP_BLOB=c49806ae6af94f65d3d8d4b9158dd9eb38b9eec8
ADAPTER_H_BLOB=3577bd2935c72a69529c855c8730d6c75054ab34
RUNTIME_H_BLOB=880143505c07450a2c47cb345722371fa820e2e9
SCOPE=product/real_camera_callback_pass_through_001

test "$(git merge-base "$START" HEAD)" = "$START"

changed="$(git diff --name-only "$START"..HEAD)"
printf '%s\n' "$changed" | while IFS= read -r item; do
    test -n "$item" || continue
    case "$item" in
        "$SCOPE"/*|src/product/MediaserverdRuntime.mm|docs/CANONICAL_PROJECT_STATE.md|.github/workflows/real-camera-callback-pass-through-001-ci.yml)
            ;;
        *)
            echo "Unauthorized mutation: $item"
            exit 1
            ;;
    esac
done

test "$(git hash-object src/product/ReferenceCameraHook.mm)" = "$HOOK_BLOB"
test "$(git hash-object src/product/CameraConsumerAdapter.cpp)" = "$ADAPTER_CPP_BLOB"
test "$(git hash-object src/product/CameraConsumerAdapter.h)" = "$ADAPTER_H_BLOB"
test "$(git hash-object src/product/MediaserverdRuntime.h)" = "$RUNTIME_H_BLOB"

git diff --quiet "$START"..HEAD -- src/product/ReferenceCameraHook.mm
git diff --quiet "$START"..HEAD -- src/product/CameraConsumerAdapter.cpp
git diff --quiet "$START"..HEAD -- src/product/CameraConsumerAdapter.h
git diff --quiet "$START"..HEAD -- src/product/MediaserverdRuntime.h

src_changed="$(git diff --name-only "$START"..HEAD -- src)"
test "$src_changed" = "src/product/MediaserverdRuntime.mm"

python3 - <<'PY'
from pathlib import Path
import plistlib
import re

scope = Path("product/real_camera_callback_pass_through_001")
runtime = Path("src/product/MediaserverdRuntime.mm").read_text()
hook = Path("src/product/ReferenceCameraHook.mm").read_text()
adapter = Path("src/product/CameraConsumerAdapter.cpp").read_text()
adapter_h = Path("src/product/CameraConsumerAdapter.h").read_text()
state = Path("src/product/ProductControlState.h").read_text()
host = Path("src/product/SpringBoardControlHost.mm").read_text()
gallery = Path("src/control/InternalGalleryViewController.mm").read_text()
proof = (scope / "RealCameraCallbackPassThroughProof.mm").read_text()
proof_h = (scope / "RealCameraCallbackPassThroughProof.h").read_text()
proof_state = (scope / "RealCameraCallbackPassThroughProofState.h").read_text()
witness = (scope / "RealCameraCallbackPassThroughWitness.mm").read_text()
build = (scope / "build_callback_pass_through_input.sh").read_text()

hook_compact = re.sub(r"\s+", "", hook)
hook_calls = (
    ("gOriginalCMSampleBufferGetImageBuffer(sampleBuffer)", "original provider call"),
    ("runtime.observeRealCameraBuffer(original)", "real-buffer observation"),
    ("runtime.decideCameraBuffer(original)", "production decision call"),
)
for call, label in hook_calls:
    count = hook_compact.count(call)
    if count != 1:
        raise SystemExit(f"Frozen hook {label} count changed: {count}")

for token in (
    "return decision.pixelBuffer != nullptr",
    "HookedCMSampleBufferGetImageBuffer",
    "MSHookFunction",
):
    if token not in hook:
        raise SystemExit(f"Frozen real callback path token missing: {token}")

if "#if defined(VCAM_REAL_CAMERA_CALLBACK_PASSTHROUGH_PROOF)" not in runtime:
    raise SystemExit("Callback proof instrumentation is not compile-time scoped")
if "ObserveRealCameraCallbackPassThroughDecision" not in runtime:
    raise SystemExit("Runtime callback observation missing")
if runtime.count("adapter_.decide(") != 2:
    raise SystemExit("Unexpected adapter decide call structure")
if "proofControlState_" not in runtime:
    raise SystemExit("Atomic proof control-state word missing")
if "std::atomic<std::uint32_t>" not in runtime:
    raise SystemExit("Proof control-state word is not atomic")
if "proofControlState_.load(" not in runtime:
    raise SystemExit("Callback does not atomically load proof control facts")
if "(snapshot.enabled ? UINT32_C(0x01)" not in runtime:
    raise SystemExit("Enabled proof fact is not derived from the control snapshot")
if "(snapshot.hasMedia() ? UINT32_C(0x02)" not in runtime:
    raise SystemExit("Media proof fact is not derived from the same control snapshot")
if "decisionCountBefore" not in runtime or "decisionCountAfter" not in runtime:
    raise SystemExit("Decision counter provenance missing")
if "virtualDecisionCountBefore" not in runtime or "virtualDecisionCountAfter" not in runtime:
    raise SystemExit("Virtual decision counter provenance missing")

proof_code = proof + "\n" + proof_h
for forbidden in (
    "CMSampleBufferGetImageBuffer(",
    "HookedCMSampleBufferGetImageBuffer(",
    "MSHookFunction(",
    "InstallReferenceCameraHook(",
    "decideCameraBuffer(",
    "CameraConsumerAdapter::decide",
):
    if forbidden in proof_code:
        raise SystemExit(f"Direct provider/target/callback invocation from proof code: {forbidden}")

for required in (
    "!facts.originalNonNull",
    "facts.controlEnabled",
    "facts.controlHasMedia",
    "!facts.decisionOriginal",
    "!facts.disabledReason",
    "!facts.originalBufferReturned",
    "facts.decisionCountAfter !=",
    "facts.virtualDecisionCountBefore == 0U",
    "facts.virtualDecisionCountAfter == 0U",
    "compare_exchange_strong",
    "dispatch_async",
):
    if required not in proof:
        raise SystemExit(f"Required proof predicate missing: {required}")

if '"com.vcampro.gate.real-camera-callback-pass-through.001"' not in proof_state:
    raise SystemExit("Fresh callback proof notification identity missing")
if "com.vcampro.gate.full-product-real-hook.001" in proof_state:
    raise SystemExit("Old install-proof identity reused")

if 'bool enabled = false;' not in state:
    raise SystemExit("VCAM disabled default changed")
if "ProductMediaKind::None" not in state:
    raise SystemExit("No-media default changed")
if "std::string mediaPath;" not in state:
    raise SystemExit("Default empty mediaPath storage changed")
if "selectionGeneration = 0" not in state:
    raise SystemExit("Default media generation changed")
if "bool hasMedia() const noexcept" not in state:
    raise SystemExit("hasMedia contract missing")

if "decision.pixelBuffer = original;" not in adapter:
    raise SystemExit("Original pixel buffer default missing")
if "CameraFailOpenReason::Disabled" not in adapter:
    raise SystemExit("Disabled fail-open reason missing")
if adapter.count("virtualDecisionCount_.fetch_add") != 1:
    raise SystemExit("Virtual decision counter increment count changed")
if adapter.index("CameraFailOpenReason::Disabled") > adapter.index("virtualDecisionCount_.fetch_add"):
    raise SystemExit("Disabled fail-open no longer precedes virtual path")
if adapter.index("virtualDecisionCount_.fetch_add") > adapter.index("decision.kind =\n        CameraDecisionKind::Virtual"):
    raise SystemExit("Virtual decision counter no longer belongs to successful virtual path")
if "std::atomic<std::uint64_t> virtualDecisionCount_{0};" not in adapter_h.replace("\n", " "):
    normalized = " ".join(adapter_h.split())
    if "std::atomic<std::uint64_t> virtualDecisionCount_{0};" not in normalized:
        raise SystemExit("Virtual decision counter declaration changed")

for token in (
    "StartSpringBoardControlHost",
    "ProductControlOwner",
    "VCAMInternalGalleryViewController",
    "colorWithWhite:0.1",
):
    if token not in host:
        raise SystemExit(f"Black Product Control token missing: {token}")

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

for token in (
    "VCAM REAL CAMERA CALLBACK PASS",
    "callback=EXERCISED",
    "vcam-enabled=NO",
    "media-selected=NO",
    "decision=ORIGINAL",
    "original-buffer-returned=YES",
    "frame-substitution=INACTIVE",
    "virtual-decision-count=0",
):
    if token not in witness:
        raise SystemExit(f"Callback witness token missing: {token}")

with (scope / "VCAMPro.RealCameraCallbackPassThrough.plist").open("rb") as f:
    product_filter = plistlib.load(f)
with (scope / "VCAMProRealCameraCallbackPassThroughWitness.plist").open("rb") as f:
    witness_filter = plistlib.load(f)

if product_filter != {"Filter": {"Executables": ["SpringBoard", "mediaserverd"]}}:
    raise SystemExit(product_filter)
if witness_filter != {"Filter": {"Executables": ["SpringBoard"]}}:
    raise SystemExit(witness_filter)

required_sources = (
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
    "ControlStateCache.cpp",
    "CameraConsumerAdapter.cpp",
    "SharedControlStore.mm",
    "SharedMediaStager.mm",
    "ProductControlOwner.mm",
    "SpringBoardControlHost.mm",
    "MediaserverdRuntime.mm",
    "ReferenceCameraHook.mm",
    "VCAMProEntry.mm",
    "FullProductRealHookProof.mm",
    "RealCameraCallbackPassThroughProof.mm",
)
for token in required_sources:
    if token not in build:
        raise SystemExit(f"Full-product build source missing: {token}")

for forbidden in (
    "ReferenceCameraHookInstallationReadinessStub.mm",
    "ReferenceCameraHookReachabilityStub.mm",
    "ReferenceCameraHookRuntimeGateStub.mm",
    "MSHookFunctionStub",
):
    if forbidden in build:
        raise SystemExit(f"Forbidden stub linked: {forbidden}")

if "-DVCAM_REAL_CAMERA_CALLBACK_PASSTHROUGH_PROOF=1" not in build:
    raise SystemExit("Callback proof build define missing")
if "-DVCAM_FULL_PRODUCT_REAL_HOOK_PROOF=1" not in build:
    raise SystemExit("Existing install proof not preserved")

print("FULL_PRODUCT_COMPONENTS_PRESENT=PASS")
print("REFERENCE_CAMERA_HOOK_SOURCE_UNCHANGED=PASS")
print("CAMERA_CONSUMER_ADAPTER_SOURCE_UNCHANGED=PASS")
print("REAL_CAMERA_CALLBACK_PATH_PRESENT=PASS")
print("CALLBACK_PROOF_COMPILE_TIME_SCOPED=PASS")
print("SYNTHETIC_CALLBACK_TEST_ABSENT=PASS")
print("DIRECT_PROVIDER_INVOCATION_FROM_PROOF_ABSENT=PASS")
print("DIRECT_TARGET_INVOCATION_FROM_PROOF_ABSENT=PASS")
print("VCAM_DISABLED_DEFAULT=PASS")
print("NO_MEDIA_DEFAULT=PASS")
print("ORIGINAL_DECISION_FAIL_OPEN_PRESENT=PASS")
print("DISABLED_REASON_PRESENT=PASS")
print("ORIGINAL_PIXEL_BUFFER_PRESERVED=PASS")
print("VIRTUAL_DECISION_COUNTER_PRESENT=PASS")
print("VIRTUAL_DECISION_COUNTER_ONLY_ON_VIRTUAL_PATH=PASS")
print("CALLBACK_WITNESS_PRESENT=PASS")
print("CALLBACK_WITNESS_SPRINGBOARD_ONLY=PASS")
print("FRAME_SUBSTITUTION_INACTIVE_BY_DEFAULT=PASS")
print("FAIL_OPEN_BEHAVIOR_PRESERVED=PASS")
print("BLACK_VCAM_PRODUCT_CONTROL_PRESENT=PASS")
PY

mkdir -p build/callback-pass-through-static-tests

xcrun --sdk macosx clang++ \
    -std=c++17 -Wall -Wextra -Werror -pedantic \
    -I"$SCOPE" \
    "$SCOPE/callback_pass_through_state_tests.cpp" \
    -o build/callback-pass-through-static-tests/proof-state

build/callback-pass-through-static-tests/proof-state \
    | tee build/callback-pass-through-static-tests/proof-state-tests.txt

grep -q 'REQUIRED_FLAGS_ACCEPTED=PASS' build/callback-pass-through-static-tests/proof-state-tests.txt
grep -q 'INCOMPLETE_FLAGS_REJECTED=PASS' build/callback-pass-through-static-tests/proof-state-tests.txt
grep -q 'STALE_STATE_REJECTED=PASS' build/callback-pass-through-static-tests/proof-state-tests.txt
grep -q 'FUTURE_SKEW_LIMIT_ENFORCED=PASS' build/callback-pass-through-static-tests/proof-state-tests.txt
grep -q 'NONZERO_PID_REQUIRED=PASS' build/callback-pass-through-static-tests/proof-state-tests.txt

test "$(git ls-remote origin refs/heads/main | awk '{print $1}')" = "$MAIN"

echo "FRESH_PROOF_REQUIRED=PASS"
echo "NONZERO_PID_REQUIRED=PASS"
echo "MAIN_UNCHANGED=PASS"
echo "DEVICE_ACTION=NO"
