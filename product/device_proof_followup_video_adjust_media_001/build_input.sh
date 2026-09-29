#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
SCOPE_DIR="$ROOT_DIR/product/device_proof_followup_video_adjust_media_001"
OUT_DIR="${1:-$ROOT_DIR/build/device-proof-followup-video-adjust-media-001}"
IOS_DIR="$OUT_DIR/ios"
PKG_ROOT="$OUT_DIR/rootless-input"
INPUT_DIR="$OUT_DIR/input"

rm -rf "$OUT_DIR"
mkdir -p "$IOS_DIR" "$PKG_ROOT/DEBIAN" "$INPUT_DIR"

SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
CXX="$(xcrun --sdk iphoneos -f clang++)"
COMMON="-std=c++17 -arch arm64 -isysroot $SDKROOT -miphoneos-version-min=15.0 -Wall -Wextra -Werror -Werror=unguarded-availability-new -pedantic -Wno-deprecated-declarations"

"$CXX" $COMMON -fobjc-arc -fblocks -dynamiclib \
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
  src/control/InternalGalleryViewController.mm \
  src/product/ControlStateCache.cpp \
  src/product/VirtualBlackFrame.mm \
  src/product/CameraConsumerAdapter.cpp \
  src/product/SharedControlStore.mm \
  src/product/SharedMediaStager.mm \
  src/product/ProductControlOwner.mm \
  src/product/SpringBoardControlHost.mm \
  src/product/MediaserverdRuntime.mm \
  src/product/ReferenceCameraHook.mm \
  src/product/VCAMProEntry.mm \
  -Fproduct/stubs \
  -framework CydiaSubstrate \
  -framework Accelerate \
  -framework Foundation \
  -framework CoreFoundation \
  -framework CoreGraphics \
  -framework CoreMedia \
  -framework CoreVideo \
  -framework AVFoundation \
  -framework ImageIO \
  -framework UIKit \
  -framework PhotosUI \
  -framework UniformTypeIdentifiers \
  -framework QuartzCore \
  -Wl,-rpath,@loader_path/.jbroot/Library/Frameworks \
  -Wl,-rpath,@loader_path/.jbroot/usr/lib \
  -Wl,-install_name,@loader_path/VCAMPro.dylib \
  -o "$IOS_DIR/VCAMPro.dylib"

TWEAK_DIR="$PKG_ROOT/var/jb/usr/lib/TweakInject"
mkdir -p "$TWEAK_DIR"

cp "$IOS_DIR/VCAMPro.dylib" "$TWEAK_DIR/VCAMPro.dylib"
cp "$ROOT_DIR/product/VCAMPro.plist" "$TWEAK_DIR/VCAMPro.plist"
cp "$SCOPE_DIR/control" "$PKG_ROOT/DEBIAN/control"
cp "$SCOPE_DIR/postinst" "$PKG_ROOT/DEBIAN/postinst"

chmod 0755 "$PKG_ROOT/DEBIAN/postinst"
chmod 0755 "$TWEAK_DIR/VCAMPro.dylib"
chmod 0644 "$TWEAK_DIR/VCAMPro.plist"
chmod 0644 "$PKG_ROOT/DEBIAN/control"

INPUT_DEB="$INPUT_DIR/com.vcampro.camera_0.1.0+roothide22~videodiag1_iphoneos-arm64.deb"
dpkg-deb -Zzstd --build --root-owner-group "$PKG_ROOT" "$INPUT_DEB"

printf '%s\n' "$INPUT_DEB"
