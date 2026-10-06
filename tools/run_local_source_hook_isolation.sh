#!/bin/sh
set -eu
mkdir -p build/source-hook-isolation
HOOK_SOURCE="${VCAM_SOURCE_ISOLATION_HOOK_SOURCE:-src/product/ReferenceCameraHook.mm}"
xcrun --sdk macosx clang++ \
  -std=c++17 -fobjc-arc -Wall -Wextra -Werror -pedantic -pthread \
  -Wno-deprecated-declarations -Wno-unused-function \
  -DVCAM_TESTING=1 \
  -DVCAM_REFERENCE_CAMERA_HOOK_SOURCE_ISOLATION_TEST=1 \
  -Isrc/frame_engine -Isrc/media_engine -Isrc/control -Isrc/product \
  src/frame_engine/PreparedFrame.cpp \
  src/frame_engine/FrameEngineState.cpp \
  src/frame_engine/ReadyFrameQueue.cpp \
  src/frame_engine/FrameTimelineScheduler.cpp \
  src/frame_engine/MonotonicHostClock.cpp \
  tests/product/local_video_reader_hook_interposed.mm \
  src/media_engine/LocalPhotoReader.mm \
  src/media_engine/FrameNormalizer.cpp \
  src/media_engine/FrameTransformer.mm \
  src/media_engine/FramePipelinePump.cpp \
  src/media_engine/FramePipelinePumpTimed.cpp \
  src/media_engine/ProducerWakeupController.cpp \
  src/media_engine/ProducerWakeupDriver.mm \
  src/media_engine/InternalGalleryMediaSession.mm \
  src/product/ControlStateCache.cpp \
  src/product/VirtualBlackFrame.mm \
  src/product/CameraConsumerAdapter.cpp \
  src/product/SharedControlStore.mm \
  src/product/SharedMediaStager.mm \
  src/product/ProductControlOwner.mm \
  src/product/MediaserverdRuntime.mm \
  "$HOOK_SOURCE" \
  tests/product/local_source_hook_isolation_tests.mm \
  -framework Accelerate \
  -framework Foundation \
  -framework AVFoundation \
  -framework CoreFoundation \
  -framework CoreGraphics \
  -framework CoreMedia \
  -framework CoreVideo \
  -framework ImageIO \
  -o build/source-hook-isolation/test
build/source-hook-isolation/test
