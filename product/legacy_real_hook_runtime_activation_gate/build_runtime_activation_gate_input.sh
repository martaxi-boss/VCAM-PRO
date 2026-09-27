#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
GATE_DIR="$ROOT_DIR/product/legacy_real_hook_runtime_activation_gate"
OUT_DIR="${1:-$ROOT_DIR/build/legacy-real-hook-runtime-activation-visible-witness-remediation-001}"
IOS_DIR="$OUT_DIR/ios"
PKG_ROOT="$OUT_DIR/rootless-input"
INPUT_DIR="$OUT_DIR/input"

rm -rf "$OUT_DIR"
mkdir -p "$IOS_DIR" "$PKG_ROOT/DEBIAN" "$INPUT_DIR"

SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
CXX="$(xcrun --sdk iphoneos -f clang++)"
COMMON="-std=c++17 -arch arm64 -isysroot $SDKROOT -miphoneos-version-min=15.0 -Wall -Wextra -Werror -Werror=unguarded-availability-new -pedantic -Wno-deprecated-declarations"

"$CXX" $COMMON -fobjc-arc -fblocks -dynamiclib \
  -Isrc/frame_engine -Isrc/media_engine -Isrc/product -I"$GATE_DIR" \
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
  src/product/MediaserverdRuntime.mm \
  src/product/ReferenceCameraHook.mm \
  "$GATE_DIR/RealHookRuntimeActivationGateEntry.mm" \
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
  -framework QuartzCore \
  -Wl,-rpath,@loader_path/.jbroot/Library/Frameworks \
  -Wl,-rpath,@loader_path/.jbroot/usr/lib \
  -Wl,-install_name,@loader_path/VCAMProRealHookRuntimeActivationGate.dylib \
  -o "$IOS_DIR/VCAMProRealHookRuntimeActivationGate.dylib"

"$CXX" $COMMON -fobjc-arc -fblocks -dynamiclib \
  -I"$GATE_DIR" \
  "$GATE_DIR/RealHookRuntimeWitness.mm" \
  -framework Foundation \
  -framework UIKit \
  -framework CoreGraphics \
  -Wl,-rpath,@loader_path/.jbroot/Library/Frameworks \
  -Wl,-rpath,@loader_path/.jbroot/usr/lib \
  -Wl,-install_name,@loader_path/VCAMProRealHookRuntimeWitness.dylib \
  -o "$IOS_DIR/VCAMProRealHookRuntimeWitness.dylib"

TWEAK_DIR="$PKG_ROOT/var/jb/usr/lib/TweakInject"
mkdir -p "$TWEAK_DIR"

cp "$IOS_DIR/VCAMProRealHookRuntimeActivationGate.dylib" \
  "$TWEAK_DIR/VCAMProRealHookRuntimeActivationGate.dylib"
cp "$GATE_DIR/VCAMPro.RealHookRuntimeActivationGate.plist" \
  "$TWEAK_DIR/VCAMProRealHookRuntimeActivationGate.plist"
cp "$IOS_DIR/VCAMProRealHookRuntimeWitness.dylib" \
  "$TWEAK_DIR/VCAMProRealHookRuntimeWitness.dylib"
cp "$GATE_DIR/VCAMPro.RealHookRuntimeWitness.plist" \
  "$TWEAK_DIR/VCAMProRealHookRuntimeWitness.plist"
cp "$GATE_DIR/control" "$PKG_ROOT/DEBIAN/control"
cp "$GATE_DIR/postinst" "$PKG_ROOT/DEBIAN/postinst"

chmod 0755 "$PKG_ROOT/DEBIAN/postinst"
chmod 0755 "$TWEAK_DIR/VCAMProRealHookRuntimeActivationGate.dylib"
chmod 0755 "$TWEAK_DIR/VCAMProRealHookRuntimeWitness.dylib"
chmod 0644 "$TWEAK_DIR/VCAMProRealHookRuntimeActivationGate.plist"
chmod 0644 "$TWEAK_DIR/VCAMProRealHookRuntimeWitness.plist"
chmod 0644 "$PKG_ROOT/DEBIAN/control"

INPUT_DEB="$INPUT_DIR/com.vcampro.camera_0.1.0+roothide7~realhookruntime2_iphoneos-arm64.deb"
dpkg-deb -Zzstd --build --root-owner-group "$PKG_ROOT" "$INPUT_DEB"

printf '%s\n' "$INPUT_DEB"
