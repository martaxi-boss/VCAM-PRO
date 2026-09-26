#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT_DIR="${1:-$ROOT_DIR/build/full-camera-gallery}"
IOS_DIR="$OUT_DIR/ios"
PKG_ROOT="$OUT_DIR/pkgroot"
FINAL_DIR="$OUT_DIR/final"

rm -rf "$OUT_DIR"
mkdir -p "$IOS_DIR" "$PKG_ROOT/DEBIAN" "$FINAL_DIR"

SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
CXX="$(xcrun --sdk iphoneos -f clang++)"

COMMON="-std=c++17 -arch arm64 -isysroot $SDKROOT -miphoneos-version-min=15.0 -Wall -Wextra -Werror -Werror=unguarded-availability-new -pedantic -Wno-deprecated-declarations"

"$CXX" $COMMON -fobjc-arc -dynamiclib   -Isrc/frame_engine -Isrc/media_engine -Isrc/control -Isrc/product   src/frame_engine/PreparedFrame.cpp   src/frame_engine/FrameEngineState.cpp   src/frame_engine/ReadyFrameQueue.cpp   src/frame_engine/FrameTimelineScheduler.cpp   src/frame_engine/MonotonicHostClock.cpp   src/media_engine/LocalVideoReader.mm   src/media_engine/LocalPhotoReader.mm   src/media_engine/FrameNormalizer.cpp   src/media_engine/FrameTransformer.mm   src/media_engine/FramePipelinePump.cpp   src/media_engine/FramePipelinePumpTimed.cpp   src/media_engine/ProducerWakeupController.cpp   src/media_engine/ProducerWakeupDriver.mm   src/media_engine/InternalGalleryMediaSession.mm   src/control/InternalGalleryViewController.mm   src/product/ControlStateCache.cpp   src/product/CameraConsumerAdapter.cpp   src/product/SharedControlStore.mm   src/product/SharedMediaStager.mm   src/product/ProductControlOwner.mm   src/product/SpringBoardControlHost.mm   src/product/MediaserverdRuntime.mm   src/product/ReferenceCameraHook.mm   src/product/VCAMProEntry.mm   -Fproduct/stubs   -framework CydiaSubstrate   -framework Accelerate   -framework Foundation   -framework CoreFoundation   -framework CoreGraphics   -framework CoreMedia   -framework CoreVideo   -framework AVFoundation   -framework ImageIO   -framework UIKit   -framework PhotosUI   -framework UniformTypeIdentifiers   -framework QuartzCore   -Wl,-rpath,/var/jb/Library/Frameworks   -Wl,-rpath,/var/jb/usr/lib   -Wl,-rpath,@loader_path/.jbroot/Library/Frameworks   -Wl,-rpath,@loader_path/.jbroot/usr/lib   -Wl,-install_name,/var/jb/Library/MobileSubstrate/DynamicLibraries/VCAMPro.dylib   -o "$IOS_DIR/VCAMPro.dylib"

DYLIB_DIR="$PKG_ROOT/var/jb/Library/MobileSubstrate/DynamicLibraries"
MEDIA_DIR="$PKG_ROOT/var/jb/var/mobile/Library/VCAMPro/Media"

mkdir -p "$DYLIB_DIR" "$MEDIA_DIR"

cp "$IOS_DIR/VCAMPro.dylib" "$DYLIB_DIR/VCAMPro.dylib"
cp "$ROOT_DIR/product/VCAMPro.plist" "$DYLIB_DIR/VCAMPro.plist"
cp "$ROOT_DIR/product/package/DEBIAN/control" "$PKG_ROOT/DEBIAN/control"
cp "$ROOT_DIR/product/package/DEBIAN/postinst" "$PKG_ROOT/DEBIAN/postinst"

chmod 0755 "$PKG_ROOT/DEBIAN/postinst"
chmod 0755 "$PKG_ROOT/var/jb/var/mobile/Library/VCAMPro"
chmod 0755 "$MEDIA_DIR"
chmod 0644 "$DYLIB_DIR/VCAMPro.plist"
chmod 0755 "$DYLIB_DIR/VCAMPro.dylib"

DEB="$FINAL_DIR/com.vcampro.camera_0.1.0_iphoneos-arm64.deb"

dpkg-deb --build --root-owner-group "$PKG_ROOT" "$DEB"

shasum -a 256 "$DEB" > "$FINAL_DIR/com.vcampro.camera_0.1.0_iphoneos-arm64.deb.sha256"

printf '%s\n' "$DEB"
