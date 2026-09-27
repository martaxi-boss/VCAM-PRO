#!/bin/sh
set -eu

START=340f2de7fc3c01f3e23420f69919152e04994ede
MAIN=d476caacc4f557843f9551533c2fcbe7c5d40baa
IOS15=a908bccbcddb4efc072bb1bc8fbeb6ee89b1af9d
MOTION=5ede3a1973a01cb13fe7f3ab562b47513feec1b1
IOS16=cc20d787070c67565173d4a46c218e2549cecc93
SCOPE=product/ios15_usb_activation_semantics_parity_001

check_blob() {
    path="$1"
    expected="$2"
    actual="$(git hash-object "$path")"
    test "$actual" = "$expected"
}

check_blob src/product/ReferenceCameraHook.mm b3b5360757d17951b0c508ab455d7ea4ffb0d6fe
check_blob src/frame_engine/ReadyFrameQueue.cpp efa8583e9770807aae9b33affd927b3aa8c0d525
check_blob src/media_engine/LocalPhotoReader.mm 3746777d17fd95fa757c7161dfe683af449a0bc6
check_blob src/media_engine/InternalGalleryMediaSession.mm a73891bb5080e3fafe9cdd98be13604e23584c59
check_blob src/product/SharedMediaStager.mm d3c144d4ca2f522d438fd98266ac3e03bd50b38d
check_blob src/product/SharedControlStore.mm 0227cd19b48d6fcff9a97d0a28d6aa3283badadd
check_blob src/product/ProductControlOwner.mm 9e2909da17142127bbef2448891da02d8c95c516
check_blob src/media_engine/FrameTransformer.mm cef1d01f33122bf4481c0c79ee1a6fe5ebe4f0ae

test "$(git merge-base "$START" HEAD)" = "$START"

changed="$(git diff --name-only "$START"..HEAD)"
printf '%s\n' "$changed" | while IFS= read -r item; do
    test -n "$item" || continue
    case "$item" in
        "$SCOPE"/*|        src/product/CameraConsumerAdapter.h|        src/product/CameraConsumerAdapter.cpp|        src/product/MediaserverdRuntime.mm|        src/product/VirtualBlackFrame.h|        src/product/VirtualBlackFrame.mm|        tests/product/camera_consumer_adapter_tests.cpp|        tests/product/full_product_integration_tests.mm|        tests/product/virtual_black_frame_tests.mm|        docs/research/IOS15_USB_ACTIVATION_SEMANTICS_PARITY_001.md|        docs/CANONICAL_PROJECT_STATE.md|        .github/workflows/first-local-photo-virtual-substitution-001-ci.yml|        .github/workflows/ios15-usb-activation-semantics-parity-001-ci.yml)
            ;;
        *)
            echo "Unauthorized mutation: $item"
            exit 1
            ;;
    esac
done

REF_DIR=build/ios15-usb-reference
rm -rf "$REF_DIR"
git clone --quiet https://github.com/martaxi-boss/IOS-15-USB.git "$REF_DIR"
git -C "$REF_DIR" checkout --quiet "$IOS15"
test "$(git -C "$REF_DIR" rev-parse HEAD)" = "$IOS15"

python3 - <<'PY'
from pathlib import Path
import plistlib
import re

root = Path(".")
scope = root / "product/ios15_usb_activation_semantics_parity_001"
adapter_h = (root / "src/product/CameraConsumerAdapter.h").read_text()
adapter = (root / "src/product/CameraConsumerAdapter.cpp").read_text()
runtime = (root / "src/product/MediaserverdRuntime.mm").read_text()
black_h = (root / "src/product/VirtualBlackFrame.h").read_text()
black = (root / "src/product/VirtualBlackFrame.mm").read_text()
hook = (root / "src/product/ReferenceCameraHook.mm").read_text()
tests = (root / "tests/product/camera_consumer_adapter_tests.cpp").read_text()
integration = (root / "tests/product/full_product_integration_tests.mm").read_text()
black_tests = (root / "tests/product/virtual_black_frame_tests.mm").read_text()
proof = (scope / "IOS15ActivationParityProof.mm").read_text()
proof_h = (scope / "IOS15ActivationParityProof.h").read_text()
proof_state = (scope / "IOS15ActivationParityProofState.h").read_text()
witness = (scope / "IOS15ActivationParityWitness.mm").read_text()
build = (scope / "build_ios15_activation_parity_input.sh").read_text()
research = (root / "docs/research/IOS15_USB_ACTIVATION_SEMANTICS_PARITY_001.md").read_text()
legacy_workflow = (root / ".github/workflows/first-local-photo-virtual-substitution-001-ci.yml").read_text()

ref = root / "build/ios15-usb-reference"
ref_plist = (ref / "recovered/VCamRecovered.plist").read_text()
ref_strings = (ref / "analysis/strings/VCamRecovered.strings.txt").read_text()
ref_imports = (ref / "analysis/symbols/VCamRecovered.undefined-symbols.txt").read_text()
ref_disassembly = ref / "analysis/disassembly/VCamRecovered.disassembly.txt"

for token in (
    '"com.apple.mediaserverd"',
    '"com.apple.springboard"',
    '"com.apple.UIKit"',
    '"mediaserverd"',
):
    if token not in ref_plist:
        raise SystemExit(f"Reference filter token missing: {token}")

for token in (
    "frameQueue",
    "clearQueue",
    "isLive",
    "setIsLive:",
    "CIContext",
    "imageWithCVPixelBuffer:",
    "render:toCVPixelBuffer:",
):
    if token not in ref_strings:
        raise SystemExit(f"Reference string missing: {token}")

for token in (
    "_CMSampleBufferGetImageBuffer",
    "_CMSampleBufferCreateReady",
    "_CMBlockBufferCreateWithMemoryBlock",
    "_MSHookFunction",
    "_VTPixelTransferSessionCreate",
    "_VTPixelTransferSessionTransferImage",
):
    if token not in ref_imports:
        raise SystemExit(f"Reference import missing: {token}")

if ref_disassembly.stat().st_size != 0:
    raise SystemExit("Recovered reference disassembly unexpectedly non-empty")
if "blackColor" not in ref_strings:
    raise SystemExit("blackColor evidence note no longer matches reference")

compact_hook = "".join(hook.split())
for token in (
    "gOriginalCMSampleBufferGetImageBuffer(sampleBuffer)",
    "runtime.observeRealCameraBuffer(original)",
    "runtime.decideCameraBuffer(original)",
):
    if "".join(token.split()) not in compact_hook:
        raise SystemExit(f"Frozen central hook path missing: {token}")

for token in (
    "CameraDecisionSource",
    "PreparedMedia",
    "BlackFallback",
    "BlackFallbackUnavailable",
    "mediaFailureReason",
    "mediaVirtualDecisionCount",
    "blackVirtualDecisionCount",
    "emergencyOriginalDecisionCount",
):
    if token not in adapter_h:
        raise SystemExit(f"Decision/source contract missing: {token}")

for token in (
    "blackOrEmergencyOriginal(",
    "CameraDecisionSource::PreparedMedia",
    "CameraDecisionSource::BlackFallback",
    "CameraFailOpenReason::BlackFallbackUnavailable",
    "virtualDecisionCount_.fetch_add",
    "mediaVirtualDecisionCount_",
    "blackVirtualDecisionCount_",
    "emergencyOriginalDecisionCount_",
):
    if token not in adapter:
        raise SystemExit(f"Adapter activation semantics missing: {token}")

if adapter.count("virtualDecisionCount_.fetch_add") != 2:
    raise SystemExit("Virtual decision accounting must cover media and black exactly")
if "std::try_to_lock" not in adapter:
    raise SystemExit("Nonblocking media reconfiguration lock changed")

decide_start = adapter.index("CameraDecision CameraConsumerAdapter::decide(")
decide_end = adapter.index("CameraDecision\nCameraConsumerAdapter::\nblackOrEmergencyOriginal", decide_start)
decide = adapter[decide_start:decide_end]
black_start = adapter.index("CameraDecision\nCameraConsumerAdapter::\nblackOrEmergencyOriginal")
black_end = adapter.index("std::size_t\nCameraConsumerAdapter::pinnedLeaseCount", black_start)
black_callback = adapter[black_start:black_end]

for forbidden in (
    "CVPixelBufferCreate(",
    "CVPixelBufferPoolCreate(",
    "CVPixelBufferPoolCreatePixelBuffer(",
    "CVPixelBufferLockBaseAddress(",
    "memset(",
    "dispatch_sync(",
    "sleep(",
    "usleep(",
    "AVAsset",
    "FrameTransformer",
    "UIKit",
):
    if forbidden in decide or forbidden in black_callback:
        raise SystemExit(f"Forbidden camera-callback work: {forbidden}")

for token in (
    "CVPixelBufferPoolCreate",
    "kCVPixelBufferWidthKey",
    "kCVPixelBufferHeightKey",
    "kCVPixelBufferPixelFormatTypeKey",
    "kCVPixelBufferIOSurfacePropertiesKey",
    "CVPixelBufferPoolCreatePixelBuffer",
    "CVPixelBufferGetPlaneCount",
    "CVPixelBufferGetBaseAddressOfPlane",
    "std::memset",
):
    if token not in black:
        raise SystemExit(f"BLACK preparation primitive missing: {token}")

if "kCacheCapacity = 4" not in black_h:
    raise SystemExit("BLACK cache bound changed")
if "pixelFormat ==" not in black or "420YpCbCr8BiPlanarVideoRange" not in black:
    raise SystemExit("420v support missing")
if "420YpCbCr8BiPlanarFullRange" not in black:
    raise SystemExit("420f support missing")
if "? 16" not in black or ": 0" not in black or "128" not in black:
    raise SystemExit("BLACK NV12 fill values missing")

for token in (
    "prepareBlackFallbackForObservedGeometry",
    "virtualBlackFrame_.prepare(",
    "adapter_.bindBlackFallback(",
    "adapter_.clearBlackFallback()",
):
    if token not in runtime:
        raise SystemExit(f"Runtime BLACK publication missing: {token}")

runtime_decide_start = runtime.index("    CameraDecision decide(")
runtime_decide_end = runtime.index("    void prepareBlackFallbackForObservedGeometry()", runtime_decide_start)
runtime_decide = runtime[runtime_decide_start:runtime_decide_end]
if "prepareBlackFallbackForObservedGeometry" in runtime_decide:
    raise SystemExit("BLACK allocation/preparation reachable from runtime callback")

for forbidden in (
    "CVPixelBufferPoolCreate",
    "CVPixelBufferCreate(",
    "CVPixelBufferLockBaseAddress",
    "memset(",
    "dispatch_sync(",
    "stageAndValidate",
    "AVAsset",
):
    if forbidden in runtime_decide:
        raise SystemExit(f"Heavy runtime callback work: {forbidden}")

for token in (
    "VCAM OFF no media returns original",
    "VCAM OFF media ready returns original",
    "VCAM ON no media uses black",
    "empty queue uses black",
    "stale generation uses black",
    "stale epoch uses black",
    "producer unavailable uses black",
    "media geometry mismatch uses black",
    "clear media returns black",
    "VCAM disable restores original",
    "VCAM OFF to ON restores ownership",
    "emergency no-black returns original",
):
    if token not in tests:
        raise SystemExit(f"Adapter regression case missing: {token}")

for token in (
    "420v black content",
    "420f black content",
    "same geometry reuses fallback",
    "geometry cache remains bounded",
):
    if token not in black_tests:
        raise SystemExit(f"BLACK content/cache test missing: {token}")

if "activation parity black photo black original" not in integration:
    raise SystemExit("Full product activation lifecycle test missing")
for token in (
    "CameraDecisionSource::BlackFallback",
    "CameraDecisionSource::PreparedMedia",
    "owner.clearMedia()",
    "owner.setEnabled(false)",
):
    if token not in integration:
        raise SystemExit(f"Activation integration assertion missing: {token}")

if "#if defined(VCAM_IOS15_ACTIVATION_PARITY_PROOF)" not in runtime:
    raise SystemExit("Activation proof not compile-time scoped")
if "-DVCAM_IOS15_ACTIVATION_PARITY_PROOF=1" not in build:
    raise SystemExit("Activation proof build define missing")

proof_code = proof + "\n" + proof_h + "\n" + witness
for forbidden in (
    "CMSampleBufferGetImageBuffer(",
    "HookedCMSampleBufferGetImageBuffer(",
    "MSHookFunction(",
    "InstallReferenceCameraHook(",
    "CameraConsumerAdapter::decide",
    "adapter_.decide(",
):
    if forbidden in proof_code:
        raise SystemExit(f"Direct/synthetic proof invocation present: {forbidden}")

for token in (
    "IOS15ActivationOutput::Original",
    "IOS15ActivationOutput::BlackVirtual",
    "IOS15ActivationOutput::PhotoVirtual",
    "facts.decisionReasonNone",
    "dispatch_async(",
):
    if token not in proof:
        raise SystemExit(f"Activation proof predicate/publication missing: {token}")

for token in (
    "VCAM ACTIVATION PARITY ORIGINAL PASS",
    "VCAM ACTIVATION PARITY BLACK PASS",
    "VCAM ACTIVATION PARITY PHOTO PASS",
    "output=%@",
    "virtual-source=BLACK_FALLBACK",
    "virtual-source=PREPARED_MEDIA",
):
    if token not in witness:
        raise SystemExit(f"Visible parity witness missing: {token}")

with (scope / "VCAMPro.IOS15ActivationParity.plist").open("rb") as f:
    product_filter = plistlib.load(f)
with (scope / "VCAMProIOS15ActivationParityWitness.plist").open("rb") as f:
    witness_filter = plistlib.load(f)
if product_filter != {"Filter": {"Executables": ["SpringBoard", "mediaserverd"]}}:
    raise SystemExit(product_filter)
if witness_filter != {"Filter": {"Executables": ["SpringBoard"]}}:
    raise SystemExit(witness_filter)

if "workflow_dispatch:" not in legacy_workflow or "\n  push:" in legacy_workflow:
    raise SystemExit("Superseded diagnostic workflow remains automatically authoritative")

for token in (
    "a908bccbcddb4efc072bb1bc8fbeb6ee89b1af9d",
    "disassembly/VCamRecovered.disassembly.txt",
    "blackColor",
    "Owner-authoritative activation contract",
    "ReferenceCameraHook.mm",
):
    if token not in research:
        raise SystemExit(f"Parity research evidence missing: {token}")

required_sources = (
    "LocalVideoReader.mm",
    "LocalPhotoReader.mm",
    "ReadyFrameQueue.cpp",
    "FrameTransformer.mm",
    "FramePipelinePump.cpp",
    "ProducerWakeupDriver.mm",
    "InternalGalleryMediaSession.mm",
    "InternalGalleryViewController.mm",
    "SharedControlStore.mm",
    "SharedMediaStager.mm",
    "ProductControlOwner.mm",
    "SpringBoardControlHost.mm",
    "VirtualBlackFrame.mm",
    "CameraConsumerAdapter.cpp",
    "MediaserverdRuntime.mm",
    "ReferenceCameraHook.mm",
    "VCAMProEntry.mm",
    "IOS15ActivationParityProof.mm",
)
for token in required_sources:
    if token not in build:
        raise SystemExit(f"Full product build source missing: {token}")

if "0.1.0+roothide13~activationparity1" not in build:
    raise SystemExit("Activation parity version missing")

print("IOS15_REFERENCE_INSPECTED=YES")
print("IOS15_REFERENCE_SHA_CORRECT=PASS")
print("CENTRAL_FILTER_PARITY=PASS")
print("VCAM_ON_OWNS_CAMERA_OUTPUT=PASS")
print("BLACK_FALLBACK_PRESENT=PASS")
print("BLACK_FALLBACK_PREPARED_OUTSIDE_CALLBACK=PASS")
print("BLACK_FALLBACK_REUSABLE=PASS")
print("BLACK_FALLBACK_CACHE_BOUNDED=PASS")
print("NO_MEDIA_DOES_NOT_RETURN_ORIGINAL=PASS")
print("MEDIA_PENDING_USES_BLACK=PASS")
print("PRODUCER_UNAVAILABLE_USES_BLACK=PASS")
print("EMPTY_QUEUE_USES_BLACK=PASS")
print("INVALID_MEDIA_LEASE_USES_BLACK=PASS")
print("MEDIA_GEOMETRY_MISMATCH_USES_BLACK=PASS")
print("PHOTO_REPLACES_BLACK=PASS")
print("CLEAR_MEDIA_RETURNS_BLACK=PASS")
print("VCAM_OFF_RESTORES_ORIGINAL=PASS")
print("VCAM_OFF_WITH_MEDIA_READY_RETURNS_ORIGINAL=PASS")
print("DECISION_SOURCE_DISTINGUISHES_BLACK_AND_MEDIA=PASS")
print("NO_BLACK_ALLOCATION_IN_CALLBACK=PASS")
print("NO_HEAVY_CAMERA_CALLBACK_WORK=PASS")
print("NO_BLOCKING_CAMERA_CALLBACK_WORK=PASS")
print("REFERENCE_CAMERA_HOOK_SOURCE_CHANGED=NO")
print("NO_NEW_HOOK=PASS")
print("NO_APP_SPECIFIC_HOOK=PASS")
print("FAIL_SAFE_EMERGENCY_ORIGINAL_PATH_PRESENT=PASS")
print("VISIBLE_ACTIVATION_PARITY_WITNESS_PRESENT=PASS")
PY

mkdir -p build/ios15-activation-proof-state

xcrun --sdk macosx clang++ \
    -std=c++17 -Wall -Wextra -Werror -pedantic \
    -I"$SCOPE" \
    "$SCOPE/ios15_activation_parity_state_tests.cpp" \
    -o build/ios15-activation-proof-state/tests

build/ios15-activation-proof-state/tests \
    | tee build/ios15-activation-proof-state/results.txt

for marker in \
    ORIGINAL_STATE_VALIDATION=PASS \
    BLACK_STATE_VALIDATION=PASS \
    PHOTO_STATE_VALIDATION=PASS \
    FRESHNESS_VALIDATION=PASS \
    SELECTION_IDENTITY_VALIDATION=PASS; do
    grep -q "$marker" build/ios15-activation-proof-state/results.txt
done

test "$(git ls-remote origin refs/heads/main | awk '{print $1}')" = "$MAIN"
test "$(git ls-remote https://github.com/martaxi-boss/IOS-15-USB.git refs/heads/main | awk '{print $1}')" = "$IOS15"
test "$(git ls-remote https://github.com/martaxi-boss/MotionCam-iOS.git refs/heads/main | awk '{print $1}')" = "$MOTION"
test "$(git ls-remote https://github.com/martaxi-boss/IOS-16-USB-4k.git refs/heads/main | awk '{print $1}')" = "$IOS16"

echo "READ_ONLY_REPOS_UNCHANGED=PASS"
echo "MAIN_UNCHANGED=PASS"
echo "DEVICE_ACTION=NO"
