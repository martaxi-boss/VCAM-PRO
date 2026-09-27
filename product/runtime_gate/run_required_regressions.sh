#!/bin/sh
set -eu

mkdir -p build/runtime-gate-regressions

run_cpp_objc_test() {
    name="$1"
    shift
    "$@"
}

echo "== Shared Control Store =="
mkdir -p build/runtime-gate-regressions/shared-control
xcrun --sdk macosx clang++ \
  -std=c++17 -fobjc-arc -Wall -Wextra -Werror -pedantic -pthread \
  -Isrc/product \
  src/product/SharedControlStore.mm \
  tests/product/shared_control_store_fail_open_tests.mm \
  -framework Foundation \
  -o build/runtime-gate-regressions/shared-control/tests
build/runtime-gate-regressions/shared-control/tests | tee build/runtime-gate-regressions/shared-control/results.txt
grep -q 'Shared control store hardening tests run: 16, failures: 0' build/runtime-gate-regressions/shared-control/results.txt

echo "== Control Provenance Recovery =="
mkdir -p build/runtime-gate-regressions/control-provenance
xcrun --sdk macosx clang++ \
  -std=c++17 -fobjc-arc -Wall -Wextra -Werror -pedantic -pthread -Wno-deprecated-declarations \
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
  -o build/runtime-gate-regressions/control-provenance/tests
build/runtime-gate-regressions/control-provenance/tests | tee build/runtime-gate-regressions/control-provenance/results.txt
grep -q 'Control provenance recovery tests run: 4, failures: 0' build/runtime-gate-regressions/control-provenance/results.txt

echo "== SpringBoard Storage Decoupling =="
python3 tests/product/springboard_storage_recovery_decoupling_tests.py

echo "== Storage Recovery =="
mkdir -p build/runtime-gate-regressions/storage-recovery
xcrun --sdk macosx clang++ \
  -std=c++17 -fobjc-arc -Wall -Wextra -Werror -pedantic -pthread -Wno-deprecated-declarations \
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
  -o build/runtime-gate-regressions/storage-recovery/tests
build/runtime-gate-regressions/storage-recovery/tests | tee build/runtime-gate-regressions/storage-recovery/results.txt
grep -q 'Storage recovery tests run: 15, failures: 0' build/runtime-gate-regressions/storage-recovery/results.txt

echo "== Selection Race =="
mkdir -p build/runtime-gate-regressions/selection-race
xcrun --sdk macosx clang++ \
  -std=c++17 -Wall -Wextra -Werror -pedantic -pthread \
  -Isrc/control \
  tests/control/selection_completion_race_tests.cpp \
  -o build/runtime-gate-regressions/selection-race/tests
build/runtime-gate-regressions/selection-race/tests | tee build/runtime-gate-regressions/selection-race/results.txt
grep -q 'Selection race tests run: 10, failures: 0' build/runtime-gate-regressions/selection-race/results.txt

echo "== Post-claim Race =="
mkdir -p build/runtime-gate-regressions/post-claim
xcrun --sdk macosx clang++ \
  -std=c++17 -fobjc-arc -Wall -Wextra -Werror -pedantic -pthread -Wno-deprecated-declarations \
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
  -o build/runtime-gate-regressions/post-claim/tests
build/runtime-gate-regressions/post-claim/tests | tee build/runtime-gate-regressions/post-claim/results.txt
grep -q 'Post-claim commit race tests run: 4, failures: 0' build/runtime-gate-regressions/post-claim/results.txt

echo "== Product Control Lost Update =="
mkdir -p build/runtime-gate-regressions/control-lost-update
xcrun --sdk macosx clang++ \
  -std=c++17 -fobjc-arc -Wall -Wextra -Werror -pedantic -pthread -Wno-deprecated-declarations \
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
  -o build/runtime-gate-regressions/control-lost-update/tests
build/runtime-gate-regressions/control-lost-update/tests | tee build/runtime-gate-regressions/control-lost-update/results.txt
grep -q 'Product control lost-update tests run: 5, failures: 0' build/runtime-gate-regressions/control-lost-update/results.txt

echo "== Product Control Status =="
mkdir -p build/runtime-gate-regressions/control-status
xcrun --sdk macosx clang++ \
  -std=c++17 -fobjc-arc -Wall -Wextra -Werror -pedantic -pthread -Wno-deprecated-declarations \
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
  -o build/runtime-gate-regressions/control-status/tests
build/runtime-gate-regressions/control-status/tests | tee build/runtime-gate-regressions/control-status/results.txt
grep -q 'Product control status tests run: 2, failures: 0' build/runtime-gate-regressions/control-status/results.txt

echo "== Shared Media Root Containment =="
mkdir -p build/runtime-gate-regressions/media-containment
xcrun --sdk macosx clang++ \
  -std=c++17 -fobjc-arc -Wall -Wextra -Werror -pedantic -pthread -Wno-deprecated-declarations \
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
  -o build/runtime-gate-regressions/media-containment/tests
build/runtime-gate-regressions/media-containment/tests | tee build/runtime-gate-regressions/media-containment/results.txt
grep -q 'Media root containment tests run: 4, failures: 0' build/runtime-gate-regressions/media-containment/results.txt

echo "== Shared Media Root TOCTOU =="
mkdir -p build/runtime-gate-regressions/media-toctou
xcrun --sdk macosx clang++ \
  -std=c++17 -DVCAM_TESTING=1 -fobjc-arc -Wall -Wextra -Werror -pedantic -pthread -Wno-deprecated-declarations \
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
  -o build/runtime-gate-regressions/media-toctou/tests
build/runtime-gate-regressions/media-toctou/tests | tee build/runtime-gate-regressions/media-toctou/results.txt
grep -q 'Media root TOCTOU tests run: 4, failures: 0' build/runtime-gate-regressions/media-toctou/results.txt

echo "== Internal Gallery =="
mkdir -p build/runtime-gate-regressions/internal-gallery
xcrun --sdk macosx clang++ \
  -std=c++17 -fobjc-arc -Wall -Wextra -Werror -pedantic -Wno-deprecated-declarations \
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
  -o build/runtime-gate-regressions/internal-gallery/tests
build/runtime-gate-regressions/internal-gallery/tests | tee build/runtime-gate-regressions/internal-gallery/results.txt
grep -q 'Internal gallery tests run: 20, failures: 0' build/runtime-gate-regressions/internal-gallery/results.txt

echo "== Product Integration =="
mkdir -p build/runtime-gate-regressions/product-integration
xcrun --sdk macosx clang++ \
  -std=c++17 -fobjc-arc -Wall -Wextra -Werror -pedantic -pthread -Wno-deprecated-declarations \
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
  -o build/runtime-gate-regressions/product-integration/tests
build/runtime-gate-regressions/product-integration/tests | tee build/runtime-gate-regressions/product-integration/results.txt
grep -q 'Product integration tests run: 8, failures: 0' build/runtime-gate-regressions/product-integration/results.txt

echo "== Frame Engine A-F2 =="
tools/run_frame_regressions.sh

echo "SHARED_CONTROL_STORE=PASS"
echo "CONTROL_PROVENANCE_RECOVERY=PASS"
echo "SPRINGBOARD_STORAGE_DECOUPLING=PASS"
echo "STORAGE_RECOVERY=PASS"
echo "SELECTION_RACE=PASS"
echo "POST_CLAIM_RACE=PASS"
echo "PRODUCT_CONTROL_LOST_UPDATE=PASS"
echo "PRODUCT_CONTROL_STATUS=PASS"
echo "SHARED_MEDIA_ROOT_CONTAINMENT=PASS"
echo "SHARED_MEDIA_ROOT_TOCTOU=PASS"
echo "INTERNAL_GALLERY=PASS"
echo "PRODUCT_INTEGRATION=PASS"
echo "FRAME_ENGINE_A_F2=PASS"
