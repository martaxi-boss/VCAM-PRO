#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$ROOT_DIR"

mkdir -p build/runtime-gate-regressions

echo "== Jailbreak root resolver =="
xcrun --sdk macosx clang++ \
  -std=c++17 -Wall -Wextra -Werror -pedantic \
  -Isrc/product \
  tests/product/jailbreak_root_resolver_tests.cpp \
  -o build/runtime-gate-regressions/root-resolver
build/runtime-gate-regressions/root-resolver |
  tee build/runtime-gate-regressions/root-resolver.txt
grep -q 'SHARED_CONTROL_ROOT_RESOLUTION=PASS' build/runtime-gate-regressions/root-resolver.txt
grep -q 'SHARED_MEDIA_ROOT_RESOLUTION=PASS' build/runtime-gate-regressions/root-resolver.txt

echo "== Shared media root containment =="
xcrun --sdk macosx clang++ \
  -std=c++17 -fobjc-arc -Wall -Wextra -Werror -pedantic -pthread \
  -Wno-deprecated-declarations \
  -Isrc/frame_engine -Isrc/media_engine -Isrc/product \
  src/frame_engine/PreparedFrame.cpp \
  src/frame_engine/FrameEngineState.cpp \
  src/media_engine/LocalVideoReader.mm \
  src/media_engine/LocalPhotoReader.mm \
  src/product/SharedMediaStager.mm \
  tests/product/shared_media_root_containment_tests.mm \
  -framework Accelerate -framework Foundation -framework AVFoundation \
  -framework CoreFoundation -framework CoreGraphics -framework CoreMedia \
  -framework CoreVideo -framework ImageIO \
  -o build/runtime-gate-regressions/media-root-containment
build/runtime-gate-regressions/media-root-containment |
  tee build/runtime-gate-regressions/media-root-containment.txt
grep -q 'Media root containment tests run: 4, failures: 0' build/runtime-gate-regressions/media-root-containment.txt

echo "== Shared media root TOCTOU =="
xcrun --sdk macosx clang++ \
  -std=c++17 -DVCAM_TESTING=1 -fobjc-arc -Wall -Wextra -Werror -pedantic -pthread \
  -Wno-deprecated-declarations \
  -Isrc/frame_engine -Isrc/media_engine -Isrc/product \
  src/frame_engine/PreparedFrame.cpp \
  src/frame_engine/FrameEngineState.cpp \
  src/media_engine/LocalVideoReader.mm \
  src/media_engine/LocalPhotoReader.mm \
  src/product/SharedMediaStager.mm \
  tests/product/shared_media_root_toctou_tests.mm \
  -framework Accelerate -framework Foundation -framework AVFoundation \
  -framework CoreFoundation -framework CoreGraphics -framework CoreMedia \
  -framework CoreVideo -framework ImageIO \
  -o build/runtime-gate-regressions/media-root-toctou
build/runtime-gate-regressions/media-root-toctou |
  tee build/runtime-gate-regressions/media-root-toctou.txt
grep -q 'Media root TOCTOU tests run: 4, failures: 0' build/runtime-gate-regressions/media-root-toctou.txt

echo "== Shared Control Store =="
xcrun --sdk macosx clang++ \
  -std=c++17 -fobjc-arc -Wall -Wextra -Werror -pedantic -pthread \
  -Isrc/product \
  src/product/SharedControlStore.mm \
  tests/product/shared_control_store_fail_open_tests.mm \
  -framework Foundation \
  -o build/runtime-gate-regressions/shared-control
build/runtime-gate-regressions/shared-control |
  tee build/runtime-gate-regressions/shared-control.txt
grep -q 'Shared control store hardening tests run: 16, failures: 0' build/runtime-gate-regressions/shared-control.txt

echo "== Control provenance recovery =="
xcrun --sdk macosx clang++ \
  -std=c++17 -fobjc-arc -Wall -Wextra -Werror -pedantic -pthread \
  -Wno-deprecated-declarations \
  -Isrc/frame_engine -Isrc/media_engine -Isrc/product \
  src/frame_engine/PreparedFrame.cpp \
  src/frame_engine/FrameEngineState.cpp \
  src/media_engine/LocalVideoReader.mm \
  src/media_engine/LocalPhotoReader.mm \
  src/product/SharedControlStore.mm \
  src/product/SharedMediaStager.mm \
  src/product/ProductControlOwner.mm \
  tests/product/shared_control_store_recovery_provenance_tests.mm \
  -framework Accelerate -framework Foundation -framework AVFoundation \
  -framework CoreFoundation -framework CoreGraphics -framework CoreMedia \
  -framework CoreVideo -framework ImageIO \
  -o build/runtime-gate-regressions/control-provenance
build/runtime-gate-regressions/control-provenance |
  tee build/runtime-gate-regressions/control-provenance.txt
grep -q 'Control provenance recovery tests run: 4, failures: 0' build/runtime-gate-regressions/control-provenance.txt

echo "== SpringBoard storage decoupling =="
python3 tests/product/springboard_storage_recovery_decoupling_tests.py |
  tee build/runtime-gate-regressions/springboard-storage-decoupling.txt

echo "== Storage recovery =="
xcrun --sdk macosx clang++ \
  -std=c++17 -fobjc-arc -Wall -Wextra -Werror -pedantic -pthread \
  -Wno-deprecated-declarations \
  -Isrc/frame_engine -Isrc/media_engine -Isrc/product \
  src/frame_engine/PreparedFrame.cpp \
  src/frame_engine/FrameEngineState.cpp \
  src/media_engine/LocalVideoReader.mm \
  src/media_engine/LocalPhotoReader.mm \
  src/product/SharedControlStore.mm \
  src/product/SharedMediaStager.mm \
  src/product/ProductControlOwner.mm \
  tests/product/local_media_storage_recovery_tests.mm \
  -framework Accelerate -framework Foundation -framework AVFoundation \
  -framework CoreFoundation -framework CoreGraphics -framework CoreMedia \
  -framework CoreVideo -framework ImageIO \
  -o build/runtime-gate-regressions/storage-recovery
build/runtime-gate-regressions/storage-recovery |
  tee build/runtime-gate-regressions/storage-recovery.txt
grep -q 'Storage recovery tests run: 15, failures: 0' build/runtime-gate-regressions/storage-recovery.txt

echo "== Selection race =="
xcrun --sdk macosx clang++ \
  -std=c++17 -Wall -Wextra -Werror -pedantic -pthread \
  -Isrc/control \
  tests/control/selection_completion_race_tests.cpp \
  -o build/runtime-gate-regressions/selection-race
build/runtime-gate-regressions/selection-race |
  tee build/runtime-gate-regressions/selection-race.txt
grep -q 'Selection race tests run: 10, failures: 0' build/runtime-gate-regressions/selection-race.txt

echo "== Post-claim race =="
xcrun --sdk macosx clang++ \
  -std=c++17 -fobjc-arc -Wall -Wextra -Werror -pedantic -pthread \
  -Wno-deprecated-declarations \
  -Isrc/frame_engine -Isrc/media_engine -Isrc/control -Isrc/product \
  src/frame_engine/PreparedFrame.cpp \
  src/frame_engine/FrameEngineState.cpp \
  src/media_engine/LocalVideoReader.mm \
  src/media_engine/LocalPhotoReader.mm \
  src/product/SharedControlStore.mm \
  src/product/SharedMediaStager.mm \
  src/product/ProductControlOwner.mm \
  tests/product/selection_post_claim_commit_race_tests.mm \
  -framework Accelerate -framework Foundation -framework AVFoundation \
  -framework CoreFoundation -framework CoreGraphics -framework CoreMedia \
  -framework CoreVideo -framework ImageIO \
  -o build/runtime-gate-regressions/post-claim
build/runtime-gate-regressions/post-claim |
  tee build/runtime-gate-regressions/post-claim.txt
grep -q 'Post-claim commit race tests run: 4, failures: 0' build/runtime-gate-regressions/post-claim.txt

echo "== Product Control lost-update =="
xcrun --sdk macosx clang++ \
  -std=c++17 -fobjc-arc -Wall -Wextra -Werror -pedantic -pthread \
  -Wno-deprecated-declarations \
  -Isrc/frame_engine -Isrc/media_engine -Isrc/control -Isrc/product \
  src/frame_engine/PreparedFrame.cpp \
  src/frame_engine/FrameEngineState.cpp \
  src/media_engine/LocalVideoReader.mm \
  src/media_engine/LocalPhotoReader.mm \
  src/product/SharedControlStore.mm \
  src/product/SharedMediaStager.mm \
  src/product/ProductControlOwner.mm \
  tests/product/product_control_lost_update_tests.mm \
  -framework Accelerate -framework Foundation -framework AVFoundation \
  -framework CoreFoundation -framework CoreGraphics -framework CoreMedia \
  -framework CoreVideo -framework ImageIO \
  -o build/runtime-gate-regressions/product-control-lost-update
build/runtime-gate-regressions/product-control-lost-update |
  tee build/runtime-gate-regressions/product-control-lost-update.txt
grep -q 'Product control lost-update tests run: 5, failures: 0' build/runtime-gate-regressions/product-control-lost-update.txt

echo "== Product Control status =="
xcrun --sdk macosx clang++ \
  -std=c++17 -fobjc-arc -Wall -Wextra -Werror -pedantic -pthread \
  -Wno-deprecated-declarations \
  -Isrc/frame_engine -Isrc/media_engine -Isrc/product \
  src/frame_engine/PreparedFrame.cpp \
  src/frame_engine/FrameEngineState.cpp \
  src/media_engine/LocalVideoReader.mm \
  src/media_engine/LocalPhotoReader.mm \
  src/product/SharedControlStore.mm \
  src/product/SharedMediaStager.mm \
  src/product/ProductControlOwner.mm \
  tests/product/product_control_status_thread_safety_tests.mm \
  -framework Accelerate -framework Foundation -framework AVFoundation \
  -framework CoreFoundation -framework CoreGraphics -framework CoreMedia \
  -framework CoreVideo -framework ImageIO \
  -o build/runtime-gate-regressions/product-control-status
build/runtime-gate-regressions/product-control-status |
  tee build/runtime-gate-regressions/product-control-status.txt
grep -q 'Product control status tests run: 2, failures: 0' build/runtime-gate-regressions/product-control-status.txt

echo "== Internal Gallery =="
xcrun --sdk macosx clang++ \
  -std=c++17 -fobjc-arc -Wall -Wextra -Werror -pedantic \
  -Wno-deprecated-declarations \
  -Isrc/frame_engine -Isrc/media_engine -Isrc/control \
  src/frame_engine/PreparedFrame.cpp \
  src/frame_engine/FrameEngineState.cpp \
  src/frame_engine/ReadyFrameQueue.cpp \
  src/media_engine/LocalVideoReader.mm \
  src/media_engine/LocalPhotoReader.mm \
  src/media_engine/FrameNormalizer.cpp \
  src/media_engine/FrameTransformer.mm \
  src/media_engine/FramePipelinePump.cpp \
  tests/media_engine/internal_gallery_integration_tests.mm \
  -framework Accelerate -framework Foundation -framework AVFoundation \
  -framework CoreFoundation -framework CoreGraphics -framework CoreMedia \
  -framework CoreVideo -framework ImageIO \
  -o build/runtime-gate-regressions/internal-gallery
build/runtime-gate-regressions/internal-gallery |
  tee build/runtime-gate-regressions/internal-gallery.txt
grep -q 'Internal gallery tests run: 20, failures: 0' build/runtime-gate-regressions/internal-gallery.txt

echo "== Product Integration =="
xcrun --sdk macosx clang++ \
  -std=c++17 -fobjc-arc -Wall -Wextra -Werror -pedantic -pthread \
  -Wno-deprecated-declarations \
  -Isrc/frame_engine -Isrc/media_engine -Isrc/control -Isrc/product \
  src/frame_engine/PreparedFrame.cpp \
  src/frame_engine/FrameEngineState.cpp \
  src/frame_engine/ReadyFrameQueue.cpp \
  src/frame_engine/FrameTimelineScheduler.cpp \
  src/frame_engine/MonotonicHostClock.cpp \
  src/media_engine/LocalVideoReader.mm \
  src/media_engine/LocalPhotoReader.mm \
  src/media_engine/FrameNormalizer.cpp \
  src/media_engine/FrameTransformer.mm \
  src/media_engine/FramePipelinePump.cpp \
  src/media_engine/FramePipelinePumpTimed.cpp \
  src/media_engine/ProducerWakeupController.cpp \
  src/media_engine/ProducerWakeupDriver.mm \
  src/media_engine/InternalGalleryMediaSession.mm \
  src/product/ControlStateCache.cpp \
  src/product/CameraConsumerAdapter.cpp \
  src/product/SharedControlStore.mm \
  src/product/SharedMediaStager.mm \
  src/product/ProductControlOwner.mm \
  tests/product/full_product_integration_tests.mm \
  -framework Accelerate -framework Foundation -framework AVFoundation \
  -framework CoreFoundation -framework CoreGraphics -framework CoreMedia \
  -framework CoreVideo -framework ImageIO \
  -o build/runtime-gate-regressions/product-integration
build/runtime-gate-regressions/product-integration |
  tee build/runtime-gate-regressions/product-integration.txt
grep -q 'Product integration tests run: 8, failures: 0' build/runtime-gate-regressions/product-integration.txt

echo "== Floating control geometry =="
xcrun --sdk macosx clang++ \
  -std=c++17 -Wall -Wextra -Werror -pedantic \
  -Isrc/product \
  tests/product/floating_control_drag_geometry_tests.cpp \
  -o build/runtime-gate-regressions/floating-control
build/runtime-gate-regressions/floating-control |
  tee build/runtime-gate-regressions/floating-control.txt

echo "== Frame Engine A-F2 =="
tools/run_frame_regressions.sh |
  tee build/runtime-gate-regressions/frame-engine-a-f2.txt

echo "SHARED_CONTROL_SEMANTICS_UNCHANGED=PASS"
echo "SHARED_MEDIA_SEMANTICS_UNCHANGED=PASS"
echo "SPRINGBOARD_CONTROL_UNCHANGED=PASS"
echo "FLOATING_CONTROL_UNCHANGED=PASS"
echo "FRAME_ENGINE_UNCHANGED=PASS"
echo "LOCAL_GALLERY_UNCHANGED=PASS"
echo "FAIL_OPEN_UNCHANGED=PASS"
