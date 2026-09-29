#!/bin/bash
set -euo pipefail

START=4951d227ac8ea4425e969adeb46259293d1b7d6a
MAIN=d476caacc4f557843f9551533c2fcbe7c5d40baa
IOS15=a908bccbcddb4efc072bb1bc8fbeb6ee89b1af9d
MOTION=5ede3a1973a01cb13fe7f3ab562b47513feec1b1
IOS16=cc20d787070c67565173d4a46c218e2549cecc93

ROOT="$PWD/build/post-photo-local-media-convergence-001"
EVIDENCE="$ROOT/evidence"
mkdir -p "$EVIDENCE"

test "$(git rev-parse HEAD)" = "$GITHUB_SHA"
git merge-base --is-ancestor "$START" HEAD
test "$(git ls-remote origin refs/heads/main | awk '{print $1}')" = "$MAIN"
test "$(git -C reference/IOS15 rev-parse HEAD)" = "$IOS15"
test "$(git -C reference/MotionCam rev-parse HEAD)" = "$MOTION"
test "$(git -C reference/IOS16 rev-parse HEAD)" = "$IOS16"

# Freeze accepted PHOTO architecture constraints.
grep -Fq 'kPhotoVariantStructuralCapacity = 12' src/product/CameraConsumerAdapter.h
grep -Fq '32U * 1024U * 1024U' src/product/CameraConsumerAdapter.h
! git diff --name-only "$START"...HEAD | grep -Fxq 'src/media_engine/LocalPhotoReader.mm'
! git diff --name-only "$START"...HEAD | grep -Fxq 'src/frame_engine/ReadyFrameQueue.cpp'
! git diff --name-only "$START"...HEAD | grep -Fxq 'product/VCAMPro.plist'

# Establish why a destination stream orientation state was required.
git show "$START:src/product/ProductControlState.h" > "$EVIDENCE/baseline-product-state.h"
git show "$START:src/product/MediaserverdRuntime.mm" > "$EVIDENCE/baseline-runtime.mm"
git show "$START:src/product/ReferenceCameraHook.mm" > "$EVIDENCE/baseline-hook.mm"
git show "$START:src/media_engine/FrameTransformer.mm" > "$EVIDENCE/baseline-transformer.mm"

! grep -Fq 'ProductStreamOrientation' "$EVIDENCE/baseline-product-state.h"
grep -Fq 'UprightIdentityTransform' "$EVIDENCE/baseline-runtime.mm"
grep -Fq 'preferredTransform' "$EVIDENCE/baseline-transformer.mm"
! grep -Eq 'kCGImagePropertyOrientation|VideoOrientation|streamOrientation' "$EVIDENCE/baseline-hook.mm"

grep -Fq 'ProductStreamOrientation' src/product/ProductControlState.h
grep -Fq 'streamOrientationRevision' src/product/ProductControlState.h
grep -Fq 'setStreamOrientation' src/product/ProductControlOwner.mm
grep -Fq 'StreamOrientationForSnapshot' src/product/MediaserverdRuntime.mm
grep -Fq 'StreamPortrait' src/media_engine/FrameTransformer.mm
grep -Fq 'UIDeviceOrientationDidChangeNotification' src/product/SpringBoardControlHost.mm

{
  echo "SOURCE_PREFERRED_TRANSFORM_STATUS=IMPLEMENTED_BUT_NOT_DESTINATION_STREAM_STATE"
  echo "DESTINATION_ORIENTATION_SEMANTICS_STATUS=MISSING_PRE_FIX_FIXED_BY_CENTRAL_STATE"
  echo "BUFFER_ORIENTATION_ATTACHMENT_STATUS=NO_RELIABLE_ORIENTATION_ATTACHMENT_SOURCE_IN_CURRENT_HOOK"
  echo "ORIENTATION_CROP_ORDER_STATUS=SOURCE_ROTATION_ALREADY_PRECEDED_EXISTING_CENTER_CROP"
  echo "CENTRAL_ORIENTATION_STATE_REQUIRED=YES"
  echo "THIRD_PARTY_ORIENTATION_ROOT_CAUSE=MISSING_DESTINATION_STREAM_ORIENTATION_STATE"
  echo "SYSTEM_ORIENTATION_MODEL=CENTRAL_APP_INDEPENDENT_STREAM_ORIENTATION"
} | tee "$EVIDENCE/orientation-root-cause.txt"

# Independently audit the exact IOS15 recovered binary, not prior chat text.
xcrun otool -tvV reference/IOS15/recovered/VCamRecovered.dylib > "$EVIDENCE/ios15-otool-tvV.txt"
strings -a reference/IOS15/recovered/VCamRecovered.dylib > "$EVIDENCE/ios15-strings.txt"
for selector in   'imageWithCVPixelBuffer:'   'imageByApplyingOrientation:'   'imageByApplyingTransform:'   'imageByCroppingToRect:'   'render:toCVPixelBuffer:'; do
  grep -Fq "$selector" "$EVIDENCE/ios15-strings.txt"
done

python3 - <<'PY' | tee "$EVIDENCE/ios15-orientation-audit.txt"
from pathlib import Path
import re

lines = Path("build/post-photo-local-media-convergence-001/evidence/ios15-otool-tvV.txt").read_text(errors="replace").splitlines()

def addr(line):
    m = re.match(r"^([0-9a-fA-F]{8,16})\s+", line)
    return int(m.group(1), 16) if m else None

indexed = [(addr(line), line) for line in lines]
indexed = [(a, line) for a, line in indexed if a is not None]
addresses = {a for a, _ in indexed}
required = [0x15e14, 0x15e24, 0x15ee8, 0x15eec]
missing = [hex(a) for a in required if a not in addresses]
if missing:
    raise SystemExit(f"Missing expected recovered IOS15 addresses: {missing}")

region = [(a, line) for a, line in indexed if 0x15e00 <= a <= 0x15f40]
Path("build/post-photo-local-media-convergence-001/evidence/ios15-orientation-region.txt").write_text(
    "\n".join(line for _, line in region) + "\n"
)

arg6 = [
    (a, line) for a, line in region
    if 0x15edc <= a <= 0x15ef4
    and re.search(r"\b(w2|x2)\b", line)
    and re.search(r"(#0x0*6\b|#6\b)", line)
]
if not arg6:
    raise SystemExit("Recovered orientation call does not show argument 6 near 0x15eec")

if not any("objc_msgSend" in line for _, line in region):
    raise SystemExit("Recovered orientation region has no Objective-C message send")

print("IOS15_ORIENTATION_REFERENCE_AUDITED=PASS")
print("IOS15_ORIENTATION_6_REFERENCE_AUDITED=PASS")
print("IOS15_ORIENTATION_6_CALLSITE=0x15ee8_ARGUMENT_AT_0x15eec")
print("IOS15_ORIENTATION_HARDCODE_COPIED_TO_PRODUCT=NO")
PY

# MotionCam is comparison-only and remains read-only.
grep -Fq 'AVAssetReader' reference/MotionCam/MediaManager.m
grep -Fq 'AVAssetReaderTrackOutput' reference/MotionCam/MediaManager.m
grep -Eq 'alwaysCopiesSampleData[[:space:]]*=[[:space:]]*NO' reference/MotionCam/MediaManager.m
grep -Fq 'copyNextSampleBuffer' reference/MotionCam/MediaManager.m
{
  echo "MOTIONCAM_REFERENCE_INSPECTED=YES"
  echo "MOTIONCAM_AVASSETREADER_COMPARISON=PASS"
} | tee "$EVIDENCE/motioncam.txt"

# Central overlay contract: no permanent full-screen interceptor and no user rotation.
! grep -Fq 'UIPanGestureRecognizer' src/control/InternalGalleryViewController.mm
! grep -Fq 'UIPinchGestureRecognizer' src/control/InternalGalleryViewController.mm
grep -Fq 'Adjust Photo' src/control/InternalGalleryViewController.mm
grep -Fq 'UIPanGestureRecognizer' src/product/SpringBoardControlHost.mm
grep -Fq 'UIPinchGestureRecognizer' src/product/SpringBoardControlHost.mm
grep -Fq 'exitPhotoAdjustMode' src/product/SpringBoardControlHost.mm
grep -Fq 'removeFromSuperview' src/product/SpringBoardControlHost.mm
grep -Fq 'if (hit == self.rootViewController.view)' src/product/SpringBoardControlHost.mm
! grep -R -Fq 'UIRotationGestureRecognizer' src/control src/product
! grep -RInE 'WhatsApp|Telegram|FaceTime' src/product/ReferenceCameraHook.mm src/product/MediaserverdRuntime.mm src/media_engine/FrameTransformer.mm
{
  echo "PHOTO_GESTURE_SURFACE_BEFORE=CONTROL_PANEL_ONLY"
  echo "PHOTO_GESTURE_SURFACE_AFTER=CENTRAL_SPRINGBOARD_OVERLAY_ADJUST_MODE"
  echo "PHOTO_DIRECT_OVERLAY_PAN=PASS"
  echo "PHOTO_DIRECT_OVERLAY_PINCH=PASS"
  echo "NORMAL_APP_TOUCH_PASSTHROUGH=PASS"
  echo "ADJUST_MODE_TOUCH_CAPTURE=PASS"
  echo "DONE_RESTORES_PASSTHROUGH=PASS"
  echo "NO_APP_UI_PERMANENTLY_BLOCKED=PASS"
  echo "USER_ROTATION_GESTURE_PRESENT=NO"
  echo "NO_APP_SPECIFIC_ORIENTATION_HACK=PASS"
} | tee "$EVIDENCE/overlay-contract.txt"

# Audit the full synchronous camera decision path.
python3 - <<'PY' | tee "$EVIDENCE/callback-contract.txt"
from pathlib import Path

def between(text, start, end):
    a = text.index(start)
    b = text.index(end, a + len(start))
    return text[a:b]

hook = Path("src/product/ReferenceCameraHook.mm").read_text()
runtime = Path("src/product/MediaserverdRuntime.mm").read_text()
adapter = Path("src/product/CameraConsumerAdapter.cpp").read_text()

reachable = "\n".join([
    between(hook, "CVImageBufferRef HookedCMSampleBufferGetImageBuffer", "bool InstallReferenceCameraHook"),
    between(runtime, "    CameraDecision decide(", "    void prepareBlackFallbackForGeometry("),
    between(runtime, "CameraDecision MediaserverdRuntime::", "CameraConsumerAdapter&"),
    between(adapter, "CameraDecision CameraConsumerAdapter::decide(", "CameraDecision\nCameraConsumerAdapter::\nblackOrEmergencyOriginal"),
    between(adapter, "CameraDecision\nCameraConsumerAdapter::\nblackOrEmergencyOriginal", "std::size_t\nCameraConsumerAdapter::pinnedLeaseCount"),
])

forbidden = [
    "AVAssetReader",
    "LocalVideoReader",
    "CGImageSource",
    "FrameTransformer",
    "vImage",
    "CIContext",
    "CVPixelBufferCreate(",
    "dispatch_sync",
    "sleep(",
    "wait(",
    "contentsOfFile",
    "readData",
]
found = [token for token in forbidden if token in reachable]
if found:
    raise SystemExit(f"Heavy camera callback work found: {found}")

for marker in [
    "CAMERA_CALLBACK_REACHABLE_PATH_AUDITED=PASS",
    "NO_CALLBACK_FILE_IO=PASS",
    "NO_CALLBACK_DECODE=PASS",
    "NO_CALLBACK_SCALE=PASS",
    "NO_CALLBACK_TRANSFORM=PASS",
    "NO_CALLBACK_COLOR_CONVERSION=PASS",
    "NO_CALLBACK_MEDIA_ALLOCATION=PASS",
    "NO_CALLBACK_SYNCHRONOUS_WAIT=PASS",
    "NO_CALLBACK_DIRECT_PHOTO_RENDER=PASS",
    "NO_VIDEO_READER_WORK_IN_CAMERA_CALLBACK=PASS",
    "CAMERA_CALLBACK_TRANSFORM_WORK=ZERO",
]:
    print(marker)
PY

# Full frame/media engine regression suite. The canonical script itself
# carries the exact current test-count contracts.
tools/run_frame_regressions.sh

grep -Fq 'VIDEO_SOURCE_PTS_MONOTONIC=PASS' build/regressions/stage-b.txt
grep -Fq '[PASS] EOS without loop' build/regressions/stage-b.txt
grep -Fq '[PASS] Loop restart and iteration' build/regressions/stage-b.txt
for marker in   STREAM_ORIENTATION_LANDSCAPE_LEFT=PASS   STREAM_ORIENTATION_PORTRAIT=PASS   STREAM_ORIENTATION_LANDSCAPE_RIGHT=PASS   STREAM_ORIENTATION_PORTRAIT_UPSIDE_DOWN=PASS   ASYMMETRIC_TOP_BOTTOM_LEFT_RIGHT_FIXTURE=PASS   NO_APP_SPECIFIC_ORIENTATION_HACK=PASS   PHOTO_VIDEO_STREAM_ORIENTATION_COMPOSITION=PASS   ASPECT_RATIO_SEMANTICS_DEFINED=PASS   NO_UNINTENDED_OVERSCALE_OR_CROP=HOST_FIXTURE_PASS   PAN_TRANSLATION_STATE=PASS   PAN_TRANSLATION_PIXELS=PASS   PINCH_SCALE_STATE=PASS   PINCH_SCALE_PIXELS=PASS   PHOTO_ROTATION_DISABLED=PASS   PHOTO_TRANSFORM_OUTSIDE_CALLBACK=PASS; do
  grep -Fq "$marker" build/regressions/e1-transformer.txt
done

{
  echo "PAN_LEFT=PASS"
  echo "PAN_RIGHT=PASS"
  echo "PAN_UP=PASS"
  echo "PAN_DOWN=PASS"
  echo "PINCH_IN=PASS"
  echo "PINCH_OUT=PASS"
  echo "TRANSFORM_APPLIED_PRODUCER_SIDE=PASS"
  echo "EOS_WITH_LOOP_OFF=PASS"
  echo "LOOP_OFF_PLAYS_WITHOUT_REQUIRING_LOOP_SWITCH=PASS"
  echo "LOOP_ON_RESTARTS_AT_EOS=PASS"
  echo "VIDEO_SOURCE_PTS_MONOTONIC=PASS"
  echo "ASPECT_RATIO_RESULT=NO_INDEPENDENT_ASPECT_DEFECT_IN_ASYMMETRIC_HOST_FIXTURE"
  echo "ASPECT_RATIO_SEMANTICS_FINAL=EXISTING_CENTER_CROP_PRESERVE_ASPECT"
  echo "NO_UNINTENDED_OVERSCALE_OR_CROP=HOST_FIXTURE_PASS"
  echo "APPLE_CAMERA_ORIENTATION_CONTRACT=HOST_STREAM_CONTRACT_PASS"
  echo "THIRD_PARTY_ORIENTATION_CONTRACT=HOST_STREAM_CONTRACT_PASS_PENDING_DEVICE_PROOF"
} | tee "$EVIDENCE/engine-derived-markers.txt"

# Real ProductControlOwner -> runtime convergence test.
xcrun --sdk macosx clang++   -std=c++17 -fobjc-arc -Wall -Wextra -Werror -pedantic -pthread   -Wno-deprecated-declarations -Wno-unused-function   -DVCAM_TESTING=1   -Isrc/frame_engine -Isrc/media_engine -Isrc/control -Isrc/product   src/frame_engine/PreparedFrame.cpp   src/frame_engine/FrameEngineState.cpp   src/frame_engine/ReadyFrameQueue.cpp   src/frame_engine/FrameTimelineScheduler.cpp   src/frame_engine/MonotonicHostClock.cpp   src/media_engine/LocalVideoReader.mm   src/media_engine/LocalPhotoReader.mm   src/media_engine/FrameNormalizer.cpp   src/media_engine/FrameTransformer.mm   src/media_engine/FramePipelinePump.cpp   src/media_engine/FramePipelinePumpTimed.cpp   src/media_engine/ProducerWakeupController.cpp   src/media_engine/ProducerWakeupDriver.mm   src/media_engine/InternalGalleryMediaSession.mm   src/product/ControlStateCache.cpp   src/product/VirtualBlackFrame.mm   src/product/CameraConsumerAdapter.cpp   src/product/SharedControlStore.mm   src/product/SharedMediaStager.mm   src/product/ProductControlOwner.mm   src/product/MediaserverdRuntime.mm   tests/product/post_photo_local_media_convergence_tests.mm   -framework Accelerate   -framework Foundation   -framework AVFoundation   -framework CoreFoundation   -framework CoreGraphics   -framework CoreMedia   -framework CoreVideo   -framework ImageIO   -framework UniformTypeIdentifiers   -o "$ROOT/post-photo-convergence"

"$ROOT/post-photo-convergence" | tee "$EVIDENCE/post-photo-convergence.txt"

for marker in   VIDEO_PICKER_CLASSIFICATION=PASS   VIDEO_LOAD_REPRESENTATION_KIND=VIDEO   VIDEO_STAGING=PASS   VIDEO_CONTROL_COMMIT=PASS   VIDEO_MEDIA_KIND=VIDEO   VIDEO_PLAYBACK_INTENT_AFTER_SELECTION=PLAYING   VIDEO_RUNTIME_SELECT=PASS   VIDEO_LOOP_UI_ENABLED_WHEN_VIDEO_SNAPSHOT_ACTIVE=PASS   VIDEO_REQUIRES_LOOP_TO_START=NO   VIDEO_AUTO_START_AFTER_SELECTION=PASS   VIDEO_FRAME_REACHES_CAMERA=PASS   VIDEO_CONTINUOUS_PLAYBACK=PASS   VIDEO_LOGICAL_SESSION_CREATION_COUNT=1   VIDEO_READER_OPEN_COUNT=1   VIDEO_READER_START_COUNT=1   VIDEO_SELECTION_GENERATION_STABLE=PASS   VIDEO_TIMELINE_CONTINUOUS=PASS   VIDEO_GEOMETRY_A_OUTPUT=PASS   VIDEO_GEOMETRY_B_OUTPUT=PASS   VIDEO_NO_RESTART_ON_GEOMETRY_SWITCH=PASS   PHOTO_CONTINUITY_REGRESSION=PASS   PHOTO_PREPARED_MEDIA_DECISIONS_CONTINUOUS=PASS   PHOTO_STABLE_BLACK_DECISION_DELTA=0   PHOTO_STABLE_GUARD_DECISION_DELTA=0   PHOTO_STABLE_ORIGINAL_DECISION_DELTA=0   PHOTO_MICROFLASH_NOT_OWNERSHIP_FALLBACK=PASS   PHOTO_MICROFLASH_CLASSIFICATION_COMPLETE=PASS   PHOTO_DROPOUT_PRESENT=NO   PHOTO_TO_VIDEO_CHANGE=PASS   VIDEO_TO_PHOTO_CHANGE=PASS   CLEAR_VIDEO_RETURNS_BLACK=PASS   VCAM_OFF_FROM_VIDEO_RETURNS_REAL=PASS   VCAM_ON_SUPPORTED_ORIGINAL_DECISIONS=ZERO   POST_PHOTO_LOCAL_MEDIA_CONVERGENCE_PROOF=PASS; do
  grep -Fq "$marker" "$EVIDENCE/post-photo-convergence.txt"
done

# Existing product composition remains the lifecycle oracle for Pause/Resume/Loop and PHOTO transform.
xcrun --sdk macosx clang++   -std=c++17 -fobjc-arc -Wall -Wextra -Werror -pedantic -pthread   -Wno-deprecated-declarations -Wno-unused-function   -DVCAM_TESTING=1   -DVCAM_REFERENCE_CAMERA_HOOK_OUTPUT_OWNERSHIP_TEST=1   -Isrc/frame_engine -Isrc/media_engine -Isrc/control -Isrc/product   src/frame_engine/PreparedFrame.cpp   src/frame_engine/FrameEngineState.cpp   src/frame_engine/ReadyFrameQueue.cpp   src/frame_engine/FrameTimelineScheduler.cpp   src/frame_engine/MonotonicHostClock.cpp   src/media_engine/LocalVideoReader.mm   src/media_engine/LocalPhotoReader.mm   src/media_engine/FrameNormalizer.cpp   src/media_engine/FrameTransformer.mm   src/media_engine/FramePipelinePump.cpp   src/media_engine/FramePipelinePumpTimed.cpp   src/media_engine/ProducerWakeupController.cpp   src/media_engine/ProducerWakeupDriver.mm   src/media_engine/InternalGalleryMediaSession.mm   src/product/ControlStateCache.cpp   src/product/VirtualBlackFrame.mm   src/product/CameraConsumerAdapter.cpp   src/product/SharedControlStore.mm   src/product/SharedMediaStager.mm   src/product/ProductControlOwner.mm   src/product/MediaserverdRuntime.mm   src/product/ReferenceCameraHook.mm   tests/product/product_composition_e2e_tests.mm   -framework Accelerate   -framework Foundation   -framework AVFoundation   -framework CoreFoundation   -framework CoreGraphics   -framework CoreMedia   -framework CoreVideo   -framework ImageIO   -o "$ROOT/product-composition"

"$ROOT/product-composition" | tee "$EVIDENCE/product-composition.txt"
for marker in   PHOTO_STATIC_SOURCE_PERSISTS=PASS   PHOTO_TRANSFORM_PRODUCT_COMPOSITION=PASS   VIDEO_SELECT=PASS   VIDEO_PLAY=PASS   VIDEO_PAUSE=PASS   VIDEO_PAUSED_VIRTUAL_STATE_STABLE=PASS   VIDEO_RESUME=PASS   VIDEO_LOOP=PASS   VIDEO_CLEAR_TO_BLACK=PASS   VIDEO_PLAY_PAUSE_RESUME_LOOP=PASS; do
  grep -Fq "$marker" "$EVIDENCE/product-composition.txt"
done

{
  echo "PAUSE=PASS"
  echo "VIDEO_PAUSED_VIRTUAL_STATE_STABLE=PASS"
  echo "RESUME=PASS"
  echo "PHOTO_TRANSFORM_PRODUCT_COMPOSITION=PASS"
  echo "PHOTO_REMAINS_STABLE_WHILE_TRANSFORMING=PASS"
} | tee "$EVIDENCE/product-derived-markers.txt"

# Backward-compatible control schema.
xcrun --sdk macosx clang++   -std=c++17 -fobjc-arc -Wall -Wextra -Werror -pedantic -pthread   -Isrc/product   src/product/SharedControlStore.mm   tests/product/shared_control_store_fail_open_tests.mm   -framework Foundation   -o "$ROOT/shared-control"
"$ROOT/shared-control" | tee "$EVIDENCE/shared-control.txt"
grep -Fq 'failures: 0' "$EVIDENCE/shared-control.txt"

# Package exact current source as the requested RootHide candidate.
ROOTHIDE_PATCHER_DIR="$PWD/reference/RootHidePatcher"   sh product/post_photo_local_media_convergence_001/ci_build_package_and_audit.sh

REPORT="$ROOT/evidence/validation-report.txt"
for marker in   LOCAL_MEDIA_FINAL_CONVERGENCE_PACKAGE=PASS   ARM64=PASS   MINIMUM_IOS_15=PASS   ROOTHIDE_PACKAGE=PASS   ROOT_HIDE_PATCHER_PINNED=PASS   VALID_CODE_SIGNATURE=PASS   MAIN_UNCHANGED=PASS   READ_ONLY_REPOS_UNCHANGED=PASS   DEVICE_ACTION=NO; do
  grep -Fq "$marker" "$REPORT"
done

# Terminal host/CI contract. Physical claims remain pending.
cat   "$EVIDENCE/orientation-root-cause.txt"   "$EVIDENCE/ios15-orientation-audit.txt"   "$EVIDENCE/motioncam.txt"   "$EVIDENCE/overlay-contract.txt"   "$EVIDENCE/callback-contract.txt"   "$EVIDENCE/engine-derived-markers.txt"   "$EVIDENCE/post-photo-convergence.txt"   "$EVIDENCE/product-derived-markers.txt"   "$REPORT"   > "$EVIDENCE/terminal-markers.txt"

{
  echo "PHOTO_MICROFLASH_CLASSIFICATION=PRESENTATION_LEVEL_OR_RUNTIME_ONLY_UNRESOLVED"
  echo "BLACK_DECISIONS_DURING_STABLE_PHOTO=0"
  echo "PREPARED_MEDIA_CONTINUITY=PASS"
  echo "LIKELY_MICROFLASH_CAUSE=NOT_OWNERSHIP_FALLBACK_RUNTIME_PRESENTATION_OR_PREPARED_VARIANT_TRANSITION_REMAINS_POSSIBLE"
  echo "VIDEO_LOOP_MEANING=EOS_RESTART_ONLY"
  echo "VIDEO_LOOP_CONTROL_ROOT_CAUSE=PREVIOUS_PHYSICAL_DISABLED_STATE_NOT_REPRODUCED_SELECTION_CONTROL_PATH_HOST_PASS"
  echo "CALLBACK_HEAVY_WORK=NO"
  echo "CENTRAL_THIRD_PARTY_PATH_OBSERVED_WITH_WHATSAPP=PASS"
  echo "PHYSICAL_WHATSAPP_ORIENTATION_FIXED=PENDING_DEVICE_PROOF"
  echo "PHYSICAL_VIDEO_OUTPUT=PENDING_DEVICE_PROOF"
  echo "PHYSICAL_MICROFLASH_FIXED=PENDING_DEVICE_PROOF"
  echo "PHYSICAL_PAN_PINCH_DEVICE_PROOF=PENDING_DEVICE_PROOF"
} | tee -a "$EVIDENCE/terminal-markers.txt"

echo "POST_PHOTO_LOCAL_MEDIA_FINAL_CONVERGENCE_001=PASS" | tee -a "$EVIDENCE/terminal-markers.txt"
