#!/bin/bash
set -euo pipefail

OUT="${1:-build/controlled-device-candidate}"
IOS_DIR="${OUT}/ios"
PKG_ROOT="${OUT}/package-root"
FINAL_DIR="${OUT}/final"
EVIDENCE_DIR="${OUT}/evidence"

rm -rf "${OUT}"
mkdir -p   "${IOS_DIR}"   "${PKG_ROOT}/DEBIAN"   "${PKG_ROOT}/var/jb/Library/MobileSubstrate/DynamicLibraries"   "${PKG_ROOT}/var/jb/var/mobile/Library/VCAMPro/Media"   "${FINAL_DIR}"   "${EVIDENCE_DIR}"

SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
CXX="$(xcrun --sdk iphoneos -f clang++)"

COMMON=(
  -std=c++17
  -arch arm64
  -isysroot "${SDKROOT}"
  -miphoneos-version-min=15.0
  -Wall
  -Wextra
  -Werror
  -Werror=unguarded-availability-new
  -pedantic
  -Wno-deprecated-declarations
  -DVCAM_CONTROLLED_PREVIEW=1
  -Isrc/frame_engine
  -Isrc/media_engine
  -Isrc/control
  -Isrc/product
  -Isrc/controlled
)

SOURCES=(
  src/frame_engine/PreparedFrame.cpp
  src/frame_engine/FrameEngineState.cpp
  src/frame_engine/ReadyFrameQueue.cpp
  src/frame_engine/FrameTimelineScheduler.cpp
  src/frame_engine/MonotonicHostClock.cpp
  src/media_engine/LocalVideoReader.mm
  src/media_engine/LocalPhotoReader.mm
  src/media_engine/FrameNormalizer.cpp
  src/media_engine/FrameTransformer.mm
  src/media_engine/FramePipelinePump.cpp
  src/media_engine/FramePipelinePumpTimed.cpp
  src/media_engine/ProducerWakeupController.cpp
  src/media_engine/ProducerWakeupDriver.mm
  src/media_engine/InternalGalleryMediaSession.mm
  src/control/InternalGalleryViewController.mm
  src/product/ProductControlOwner.mm
  src/product/SharedControlStore.mm
  src/product/SharedMediaStager.mm
  src/product/SpringBoardControlHost.mm
  src/controlled/ControlledFrameConsumer.cpp
  src/controlled/ControlledRuntime.mm
  src/controlled/ControlledPreviewView.mm
  src/controlled/VCAMProControlledEntry.mm
)

"${CXX}"   "${COMMON[@]}"   -fobjc-arc   -dynamiclib   "${SOURCES[@]}"   -framework Accelerate   -framework Foundation   -framework CoreFoundation   -framework CoreGraphics   -framework CoreMedia   -framework CoreVideo   -framework AVFoundation   -framework ImageIO   -framework UIKit   -framework PhotosUI   -framework UniformTypeIdentifiers   -framework QuartzCore   -Wl,-install_name,/var/jb/Library/MobileSubstrate/DynamicLibraries/VCAMProControlled.dylib   -o "${IOS_DIR}/VCAMProControlled.dylib"

cp   "${IOS_DIR}/VCAMProControlled.dylib"   "${PKG_ROOT}/var/jb/Library/MobileSubstrate/DynamicLibraries/VCAMProControlled.dylib"

cp   controlled/VCAMProControlled.plist   "${PKG_ROOT}/var/jb/Library/MobileSubstrate/DynamicLibraries/VCAMProControlled.plist"

cp   controlled/package/DEBIAN/control   "${PKG_ROOT}/DEBIAN/control"

cp   controlled/package/DEBIAN/postinst   "${PKG_ROOT}/DEBIAN/postinst"

chmod 0755   "${PKG_ROOT}/DEBIAN/postinst"   "${PKG_ROOT}/var/jb/Library/MobileSubstrate/DynamicLibraries/VCAMProControlled.dylib"

chmod 0644   "${PKG_ROOT}/DEBIAN/control"   "${PKG_ROOT}/var/jb/Library/MobileSubstrate/DynamicLibraries/VCAMProControlled.plist"

chmod 0755   "${PKG_ROOT}/var/jb/var/mobile/Library/VCAMPro/Media"

DEB="${FINAL_DIR}/com.vcampro.controlledtest_0.1.0_iphoneos-arm64.deb"

dpkg-deb --build   "${PKG_ROOT}"   "${DEB}"

shasum -a 256 "${DEB}"   | tee "${DEB}.sha256"

printf '%s
' "${DEB}"
