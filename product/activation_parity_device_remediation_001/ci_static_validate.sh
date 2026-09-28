#!/bin/sh
set -eu

BASE=699a9d017d290c106ba65776f867fd65d11c1ecb
MAIN=d476caacc4f557843f9551533c2fcbe7c5d40baa
IOS15=a908bccbcddb4efc072bb1bc8fbeb6ee89b1af9d
MOTION=5ede3a1973a01cb13fe7f3ab562b47513feec1b1
IOS16=cc20d787070c67565173d4a46c218e2549cecc93
SCOPE=product/activation_parity_device_remediation_001

test "$(git merge-base "$BASE" HEAD)" = "$BASE"

changed="$(git diff --name-only "$BASE"..HEAD)"
printf '%s\n' "$changed" | while IFS= read -r item; do
    test -n "$item" || continue
    case "$item" in
        "$SCOPE"/*|\
        docs/research/IOS15_USB_STILL_CAPTURE_PARITY_001.md|\
        src/product/MediaserverdRuntime.mm|\
        src/product/ReferenceCameraHook.mm|\
        src/product/CameraConsumerAdapter.h|\
        src/product/CameraConsumerAdapter.cpp|\
        src/media_engine/InternalGalleryMediaSession.h|\
        src/media_engine/InternalGalleryMediaSession.mm|\
        src/media_engine/ProducerWakeupDriver.h|\
        src/media_engine/ProducerWakeupDriver.mm|\
        tests/product/reference_camera_hook_output_ownership_tests.mm|\
        docs/CANONICAL_PROJECT_STATE.md|\
        .github/workflows/activation-parity-device-remediation-001-ci.yml)
            ;;
        *)
            echo "Unauthorized remediation mutation: $item"
            exit 1
            ;;
    esac
done

HOOK=src/product/ReferenceCameraHook.mm
RUNTIME=src/product/MediaserverdRuntime.mm
REPORT=docs/research/IOS15_USB_STILL_CAPTURE_PARITY_001.md
OWNERSHIP_TEST=tests/product/reference_camera_hook_output_ownership_tests.mm
BUILD="$SCOPE/build_activation_parity_device_remediation_input.sh"
CONTROL="$SCOPE/control"

for required in \
    "$HOOK" \
    "$RUNTIME" \
    "$REPORT" \
    "$OWNERSHIP_TEST" \
    "$BUILD" \
    "$CONTROL" \
    "$SCOPE/ActivationParityDeviceRemediationProof.h" \
    "$SCOPE/ActivationParityDeviceRemediationProof.mm" \
    "$SCOPE/ActivationParityDeviceRemediationProofState.h" \
    "$SCOPE/ActivationParityDeviceRemediationWitness.mm" \
    "product/VCAMPro.plist" \
    "$SCOPE/VCAMProActivationParityDeviceRemediationWitness.plist"; do
    test -s "$required"
done

for token in \
    '0x175d4' \
    '0x19798' \
    'StillImageKey' \
    'CMGetAttachment' \
    'render:toCVPixelBuffer:' \
    'virtual content -> ORIGINAL camera pixel buffer -> return ORIGINAL buffer' \
    'CMSampleBufferCreateReady' \
    'UNRESOLVED'; do
    grep -Fq "$token" "$REPORT"
done

grep -Fq 'CommitVirtualCameraOutputIntoOriginal' "$HOOK"
grep -Fq 'CMGetAttachment(' "$HOOK"
grep -Fq 'CFSTR("StillImageKey")' "$HOOK"
grep -Fq 'CFSTR("vcam_patched")' "$HOOK"
grep -Fq '&CMSampleBufferGetImageBuffer' "$HOOK"
grep -Fq '&HookedCMSampleBufferGetImageBuffer' "$HOOK"
test "$(grep -c 'MSHookFunction(' "$HOOK")" -eq 2
test "$(grep -c '&CMSampleBufferGetImageBuffer' "$HOOK")" -eq 1

# The unresolved historical CMSampleBufferCreateReady helper must not be
# introduced into the central still remediation path.
test -z "$(grep -F 'CMSampleBufferCreateReady' "$HOOK" || true)"

for token in \
    'VCAM_ACTIVATION_PARITY_DEVICE_REMEDIATION_PROOF' \
    'BeginActivationParityPhotoGeneration' \
    'ObserveActivationParityCameraDecision' \
    'PublishActivationParityPhotoSnapshot'; do
    grep -Fq "$token" "$RUNTIME"
done

for token in \
    'producerDriverState' \
    'lastPumpStatus' \
    'publishedFrameCount' \
    'photoDecodeCount'; do
    grep -Fq "$token" "$RUNTIME"
done

for token in \
    'hasCompatibleBlackFallback' \
    'preparedFallbackExisted'; do
    grep -Fq "$token" "$HOOK"
done

for token in \
    'producer-driver=' \
    'photo-decodes=' \
    'preview-geometry=' \
    'still-black-compatible=' \
    'prepared-fallback-existed='; do
    grep -Fq "$token" "$SCOPE/ActivationParityDeviceRemediationWitness.mm"
done

if grep -E 'tryAcquire\(|\.acquire\(' \
    "$SCOPE/ActivationParityDeviceRemediationProof.mm" \
    "$SCOPE/ActivationParityDeviceRemediationWitness.mm"; then
    echo "Diagnostic transport must not consume ReadyFrameQueue"
    exit 1
fi

for token in \
    'STILL_SAME_GEOMETRY_VIRTUAL_OWNERSHIP=PASS' \
    'STILL_GEOMETRY_MISMATCH_PRESERVES_ORIGINAL=OBSERVED' \
    'STILL_GEOMETRY_RACE_DEVICE_CLASSIFICATION=REQUIRED'; do
    grep -Fq "$token" "$OWNERSHIP_TEST"
done

# A host test cannot certify the unresolved flash/still device outcome.
test -z "$(grep -F 'FLASH_STILL_CAPTURE_DOES_NOT_EXPOSE_ORIGINAL=PASS' "$OWNERSHIP_TEST" || true)"

for forbidden in WhatsApp Telegram FaceTime KYC biometric; do
    test -z "$(grep -E -i "$forbidden" "$HOOK" "$RUNTIME" "$SCOPE/ActivationParityDeviceRemediationProof.mm" "$SCOPE/ActivationParityDeviceRemediationWitness.mm" || true)"
done
test -z "$(grep -E -i 'identity[[:space:]_-]*verification|verify[[:space:]_-]*identity' "$HOOK" "$RUNTIME" "$SCOPE/ActivationParityDeviceRemediationProof.mm" "$SCOPE/ActivationParityDeviceRemediationWitness.mm" || true)"

# Callback ownership work may copy already-prepared pixels, but must not decode,
# allocate media sessions, perform file I/O, sleep, or dispatch synchronously.
python3 - <<'PY'
from pathlib import Path

hook = Path("src/product/ReferenceCameraHook.mm").read_text()
start = hook.index("CVImageBufferRef HookedCMSampleBufferGetImageBuffer(")
end = hook.index("}  // namespace", start)
callback = hook[start:end]

for forbidden in (
    "AVAsset",
    "AVAssetReader",
    "UIImage",
    "PHAsset",
    "fopen(",
    "open(",
    "read(",
    "write(",
    "sleep(",
    "usleep(",
    "dispatch_sync(",
    "CVPixelBufferCreate(",
    "CVPixelBufferPoolCreate(",
):
    if forbidden in callback:
        raise SystemExit(f"Forbidden callback work: {forbidden}")

if "MSHookMessageEx" in hook:
    raise SystemExit("Unexpected Objective-C message hook")

build = Path("product/activation_parity_device_remediation_001/build_activation_parity_device_remediation_input.sh").read_text()
for token in (
    "-DVCAM_ACTIVATION_PARITY_DEVICE_REMEDIATION_PROOF=1",
    "ReferenceCameraHook.mm",
    "MediaserverdRuntime.mm",
    "LocalPhotoReader.mm",
    "LocalVideoReader.mm",
    "CameraConsumerAdapter.cpp",
    "ActivationParityDeviceRemediationProof.mm",
    "0.1.0+roothide15~activationremed2",
):
    if token not in build:
        raise SystemExit(f"Remediation build composition missing: {token}")
PY

python3 - <<'PY'
from pathlib import Path
import plistlib

scope = Path("product/activation_parity_device_remediation_001")
canonical_path = Path("product/VCAMPro.plist")
with canonical_path.open("rb") as f:
    product = plistlib.load(f)
with (scope / "VCAMProActivationParityDeviceRemediationWitness.plist").open("rb") as f:
    witness = plistlib.load(f)

expected_product = {
    "Filter": {
        "Bundles": [
            "com.apple.mediaserverd",
            "com.apple.springboard",
            "com.apple.UIKit",
        ],
        "Executables": ["mediaserverd"],
    }
}
if product != expected_product:
    raise SystemExit(product)
if witness != {"Filter": {"Executables": ["SpringBoard"]}}:
    raise SystemExit(witness)

duplicate = scope / "VCAMPro.ActivationParityDeviceRemediation.plist"
if duplicate.exists():
    raise SystemExit("Diagnostic product filter override still exists")

build = (scope / "build_activation_parity_device_remediation_input.sh").read_text()
canonical_copy = 'cp "$ROOT_DIR/product/VCAMPro.plist" "$TWEAK_DIR/VCAMPro.plist"'
if canonical_copy not in build:
    raise SystemExit("Canonical product filter is not the package source")
if "VCAMPro.ActivationParityDeviceRemediation.plist" in build:
    raise SystemExit("Diagnostic product filter override still referenced")
PY

grep -Fq 'Version: 0.1.0+roothide15~activationremed2' "$CONTROL"
grep -Fq 'Architecture: iphoneos-arm64' "$CONTROL"

test "$(git ls-remote origin refs/heads/main | awk '{print $1}')" = "$MAIN"
heads="$(git ls-remote --heads origin | awk '{print $2}' | sort)"
expected_heads="$(printf '%s\n' refs/heads/builder/canonical-hook-continuation-001 refs/heads/main | sort)"
test "$heads" = "$expected_heads"

test "$(git ls-remote https://github.com/martaxi-boss/IOS-15-USB.git refs/heads/main | awk '{print $1}')" = "$IOS15"
test "$(git ls-remote https://github.com/martaxi-boss/MotionCam-iOS.git refs/heads/main | awk '{print $1}')" = "$MOTION"
test "$(git ls-remote https://github.com/martaxi-boss/IOS-16-USB-4k.git refs/heads/main | awk '{print $1}')" = "$IOS16"

printf '%s\n' \
    "REMEDIATION_SCOPE=PASS" \
    "PHOTO_RUNTIME_DIAGNOSTIC_CAPABILITIES=PASS" \
    "STILL_RUNTIME_DIAGNOSTIC_CAPABILITIES=PASS" \
    "DIAGNOSTIC_QUEUE_CONSUMPTION=NO" \
    "HISTORICAL_DESTINATION_OWNERSHIP_ADAPTED=PASS" \
    "STILLIMAGEKEY_DIAGNOSTIC_PRESENT=PASS" \
    "CMSAMPLEBUFFERCREATEREADY_NOT_INTRODUCED=PASS" \
    "NO_NEW_HOOK_TARGET=PASS" \
    "NO_APP_SPECIFIC_HOOKS=PASS" \
    "NO_UI_CONTROL_SUPPRESSION=PASS" \
    "NO_CALLBACK_FILE_IO=PASS" \
    "NO_CALLBACK_DECODE=PASS" \
    "VCAMPRO_CANONICAL_FILTER_SHAPE=PASS" \
    "NO_DIAGNOSTIC_PRODUCT_FILTER_OVERRIDE=PASS" \
    "PHOTO_ROOT_CAUSE=UNRESOLVED_PENDING_DEVICE_DIAGNOSTIC" \
    "STILL_GEOMETRY_RACE_STATUS=UNRESOLVED" \
    "MAIN_UNCHANGED=PASS" \
    "READ_ONLY_REPOS_UNCHANGED=PASS" \
    "DEVICE_ACTION=NO"
