#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT_DIR="${1:-$ROOT_DIR/build/roothide-product-integration}"
IOS_DIR="$OUT_DIR/ios"
PKG_ROOT="$OUT_DIR/rootless-input"
FINAL_DIR="$OUT_DIR/input"

rm -rf "$OUT_DIR"
mkdir -p "$IOS_DIR" "$PKG_ROOT/DEBIAN" "$FINAL_DIR"

SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
CXX="$(xcrun --sdk iphoneos -f clang++)"

COMMON="-std=c++17 -arch arm64 -isysroot $SDKROOT -miphoneos-version-min=15.0 -Wall -Wextra -Werror -Werror=unguarded-availability-new -pedantic -Wno-deprecated-declarations"

"$CXX" $COMMON -fobjc-arc -dynamiclib \
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
cp "$ROOT_DIR/product/VCAMPro.RootHideIntegration.plist" "$TWEAK_DIR/VCAMPro.plist"
cp "$ROOT_DIR/product/roothide_integration/DEBIAN/control" "$PKG_ROOT/DEBIAN/control"
cp "$ROOT_DIR/product/roothide_integration/DEBIAN/postinst" "$PKG_ROOT/DEBIAN/postinst"

chmod 0755 "$PKG_ROOT/DEBIAN/postinst"
chmod 0755 "$TWEAK_DIR/VCAMPro.dylib"
chmod 0644 "$TWEAK_DIR/VCAMPro.plist"
chmod 0644 "$PKG_ROOT/DEBIAN/control"

INPUT_DEB="$FINAL_DIR/com.vcampro.camera_0.1.0+roothide3_iphoneos-arm64.deb"
dpkg-deb -Zzstd --build --root-owner-group "$PKG_ROOT" "$INPUT_DEB"

printf '%s\n' "$INPUT_DEB"
