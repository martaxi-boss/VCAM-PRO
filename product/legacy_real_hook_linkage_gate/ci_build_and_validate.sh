#!/bin/sh
set -eu

BASE=ade6887fa6214ac1cd26b56f13e0d4f64e07e1d4
PARITY=ff2df5125e2e6f131b3b79ccb311a41105f950df
LEGACY=a908bccbcddb4efc072bb1bc8fbeb6ee89b1af9d
PR19=2475bd51953b536c32d12e37475fd32eaf7c4a67

EXPECTED_HOOK_BLOB=b3b5360757d17951b0c508ab455d7ea4ffb0d6fe
EXPECTED_RUNTIME_BLOB=37c613ab2c0746b34a86b74e20ce8814dee0a7da
EXPECTED_ENTRY_BLOB=0003e5e7b8d2b6973cb8feae699bd25e545e2658

ROOT=build/legacy-real-hook-linkage-gate-001
IOS_DIR="$ROOT/ios"
EVIDENCE="$ROOT/evidence"
MODEL_DIR="$ROOT/roothide-final-layout-model/usr/lib/TweakInject"
DYLIB="$IOS_DIR/VCAMProLegacyRealHookLinkageGate.dylib"

rm -rf "$ROOT"
mkdir -p "$IOS_DIR" "$EVIDENCE" "$MODEL_DIR"

test "$(git merge-base "$BASE" HEAD)" = "$BASE"

changed="$(git diff --name-only "$BASE"..HEAD)"
printf '%s\n' "$changed" | while IFS= read -r path; do
    test -n "$path" || continue
    case "$path" in
        product/legacy_real_hook_linkage_gate/*|.github/workflows/legacy-real-hook-linkage-gate-ci.yml)
            ;;
        *)
            echo "Unauthorized gate mutation: $path"
            exit 1
            ;;
    esac
done

git diff --quiet "$BASE"..HEAD -- src
git diff --quiet "$BASE"..HEAD -- product/build_roothide_integration_input.sh
git diff --quiet "$BASE"..HEAD -- product/VCAMPro.RootHideIntegration.plist
git diff --quiet "$BASE"..HEAD -- product/roothide_integration
git diff --quiet "$BASE"..HEAD -- product/hook_installation_readiness_gate
git diff --quiet "$BASE"..HEAD -- product/hook_reachability_gate
git diff --quiet "$BASE"..HEAD -- product/runtime_gate

test "$(git rev-parse "$BASE:src/product/ReferenceCameraHook.mm")" = "$EXPECTED_HOOK_BLOB"
test "$(git hash-object src/product/ReferenceCameraHook.mm)" = "$EXPECTED_HOOK_BLOB"
test "$(git rev-parse "$BASE:src/product/MediaserverdRuntime.mm")" = "$EXPECTED_RUNTIME_BLOB"
test "$(git hash-object src/product/MediaserverdRuntime.mm)" = "$EXPECTED_RUNTIME_BLOB"
test "$(git rev-parse "$BASE:src/product/VCAMProEntry.mm")" = "$EXPECTED_ENTRY_BLOB"
test "$(git hash-object src/product/VCAMProEntry.mm)" = "$EXPECTED_ENTRY_BLOB"

{
    echo "AUTHORITATIVE_BASE=$BASE"
    echo "REFERENCE_CAMERA_HOOK_GIT_BLOB=$EXPECTED_HOOK_BLOB"
    echo "MEDIASERVERD_RUNTIME_GIT_BLOB=$EXPECTED_RUNTIME_BLOB"
    echo "VCAMPRO_ENTRY_GIT_BLOB=$EXPECTED_ENTRY_BLOB"
    shasum -a 256 src/product/ReferenceCameraHook.mm
    shasum -a 256 src/product/MediaserverdRuntime.mm
    shasum -a 256 src/product/VCAMProEntry.mm
} > "$EVIDENCE/source-blobs-and-sha256.txt"

if ! git cat-file -e "$PARITY^{commit}" 2>/dev/null; then
    git fetch -q origin "$PARITY"
fi

test "$(git merge-base "$BASE" "$PARITY")" = "$BASE"
test "$(git rev-parse "$PARITY:src/product/ReferenceCameraHook.mm")" = "$EXPECTED_HOOK_BLOB"
test "$(git rev-parse "$PARITY:src/product/MediaserverdRuntime.mm")" = "$EXPECTED_RUNTIME_BLOB"
test "$(git rev-parse "$PARITY:src/product/VCAMProEntry.mm")" = "$EXPECTED_ENTRY_BLOB"

git show "$PARITY:product/legacy_hook_parity_audit/LEGACY_HOOK_STRUCTURAL_PARITY_AUDIT_001.md" \
    > "$EVIDENCE/frozen-parity-evidence.md"
grep -Fq 'LEGACY_STRUCTURAL_PARITY=CONFIRMED' "$EVIDENCE/frozen-parity-evidence.md"
grep -Fq 'target: `&CMSampleBufferGetImageBuffer`' "$EVIDENCE/frozen-parity-evidence.md"
grep -Fq 'replacement: `&HookedCMSampleBufferGetImageBuffer`' "$EVIDENCE/frozen-parity-evidence.md"
grep -Fq 'original storage: `&gOriginalCMSampleBufferGetImageBuffer`' "$EVIDENCE/frozen-parity-evidence.md"

test "$(git ls-remote https://github.com/martaxi-boss/IOS-15-USB.git refs/heads/main | awk '{print $1}')" = "$LEGACY"
test "$(git ls-remote origin refs/pull/19/head | awk '{print $1}')" = "$PR19"

test ! -e product/hook_provider_self_test_gate
test -z "$(find product/legacy_real_hook_linkage_gate -type f -name '*.plist' -print)"
test -z "$(find "$ROOT" -type f -name '*.plist' -print)"

grep -Fq 'TWEAK_DIR="$PKG_ROOT/var/jb/usr/lib/TweakInject"' product/build_roothide_integration_input.sh
grep -Fq -- '-Wl,-rpath,@loader_path/.jbroot/Library/Frameworks' product/build_roothide_integration_input.sh
grep -Fq -- '-Wl,-rpath,@loader_path/.jbroot/usr/lib' product/build_roothide_integration_input.sh
grep -Fq -- '-Wl,-install_name,@loader_path/VCAMPro.dylib' product/build_roothide_integration_input.sh
grep -Fq 'Architecture: iphoneos-arm64' product/roothide_integration/DEBIAN/control
grep -Fq 'Architecture)" = "iphoneos-arm64e"' product/hook_installation_readiness_gate/ci_build_package_and_audit.sh
grep -Fq '/usr/lib/TweakInject/VCAMPro.dylib' product/hook_installation_readiness_gate/ci_build_package_and_audit.sh
grep -Fq 'RootHidePatcher/patch.sh' product/hook_installation_readiness_gate/ci_build_package_and_audit.sh
grep -Fq 'LC_CODE_SIGNATURE' product/hook_installation_readiness_gate/ci_build_package_and_audit.sh

cat > "$EVIDENCE/linked-sources.txt" <<'EOF'
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
src/product/ControlStateCache.cpp
src/product/CameraConsumerAdapter.cpp
src/product/SharedControlStore.mm
src/product/SharedMediaStager.mm
src/product/ProductControlOwner.mm
src/product/SpringBoardControlHost.mm
src/product/MediaserverdRuntime.mm
src/product/ReferenceCameraHook.mm
EOF

grep -Fxq 'src/product/ReferenceCameraHook.mm' "$EVIDENCE/linked-sources.txt"
grep -Fxq 'src/product/MediaserverdRuntime.mm' "$EVIDENCE/linked-sources.txt"
if grep -Fxq 'src/product/VCAMProEntry.mm' "$EVIDENCE/linked-sources.txt"; then
    echo "Active product entry must not be linked into inert analysis dylib."
    exit 1
fi

constructor_sources="$(grep -RIl '__attribute__((constructor))' src | sort || true)"
test "$constructor_sources" = "src/product/VCAMProEntry.mm"
grep -Fq 'runtime.start()' src/product/VCAMProEntry.mm
grep -Fq 'InstallReferenceCameraHook()' src/product/VCAMProEntry.mm

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
  -Wl,-install_name,@loader_path/VCAMProLegacyRealHookLinkageGate.dylib \
  -Wl,-map,"$EVIDENCE/link-map.txt" \
  -o "$DYLIB"

codesign --force --sign - "$DYLIB"
codesign --verify --verbose=2 "$DYLIB" 2> "$EVIDENCE/codesign-verify.txt"

xcrun lipo -info "$DYLIB" | tee "$EVIDENCE/macho-arch.txt"
xcrun otool -l "$DYLIB" > "$EVIDENCE/macho-load-commands.txt"
xcrun otool -D "$DYLIB" > "$EVIDENCE/macho-install-name.txt"
xcrun otool -L "$DYLIB" > "$EVIDENCE/macho-linked-libraries.txt"
xcrun nm -a "$DYLIB" | c++filt > "$EVIDENCE/macho-symbols.txt"
xcrun nm -u "$DYLIB" > "$EVIDENCE/macho-undefined.txt"
strings "$DYLIB" > "$EVIDENCE/macho-strings.txt"

grep -q 'architecture: arm64' "$EVIDENCE/macho-arch.txt"
grep -q 'minos 15.0' "$EVIDENCE/macho-load-commands.txt"
grep -q '@loader_path/.jbroot/Library/Frameworks' "$EVIDENCE/macho-load-commands.txt"
grep -q '@loader_path/.jbroot/usr/lib' "$EVIDENCE/macho-load-commands.txt"
test -z "$(grep 'path /var/jb' "$EVIDENCE/macho-load-commands.txt" || true)"
grep -q '@loader_path/VCAMProLegacyRealHookLinkageGate.dylib' "$EVIDENCE/macho-install-name.txt"
grep -q '@rpath/CydiaSubstrate.framework/CydiaSubstrate' "$EVIDENCE/macho-linked-libraries.txt"
grep -q 'LC_CODE_SIGNATURE' "$EVIDENCE/macho-load-commands.txt"

grep -Fq 'vcam::product::InstallReferenceCameraHook()' "$EVIDENCE/macho-symbols.txt"
grep -Fq 'HookedCMSampleBufferGetImageBuffer' "$EVIDENCE/macho-symbols.txt"
grep -Fq 'gOriginalCMSampleBufferGetImageBuffer' "$EVIDENCE/macho-symbols.txt"
grep -Fxq '_MSHookFunction' "$EVIDENCE/macho-undefined.txt"
grep -Fxq '_CMSampleBufferGetImageBuffer' "$EVIDENCE/macho-undefined.txt"

test -z "$(grep -F 'VCAMProInitialize' "$EVIDENCE/macho-symbols.txt" || true)"
grep -Fq '[VCAM PRO] Hooking CMSampleBufferGetImageBuffer' "$EVIDENCE/macho-strings.txt"

cp "$DYLIB" "$MODEL_DIR/VCAMProLegacyRealHookLinkageGate.dylib"
test -f "$MODEL_DIR/VCAMProLegacyRealHookLinkageGate.dylib"
test -z "$(find "$ROOT/roothide-final-layout-model" -type f -name '*.plist' -print)"
test -z "$(find "$ROOT/roothide-final-layout-model" -type f -name '*.deb' -print)"

cat > "$EVIDENCE/roothide-linkage-model.txt" <<'EOF'
INPUT_PACKAGE_ARCH_MODEL=iphoneos-arm64
ROOT_HIDE_PATCHED_ARCH_MODEL=iphoneos-arm64e
ANALYSIS_MACHO_ARCH=arm64
MINIMUM_IOS=15.0
RPATH_1=@loader_path/.jbroot/Library/Frameworks
RPATH_2=@loader_path/.jbroot/usr/lib
INSTALL_NAME=@loader_path/VCAMProLegacyRealHookLinkageGate.dylib
FINAL_LAYOUT_MODEL=/usr/lib/TweakInject/VCAMProLegacyRealHookLinkageGate.dylib
AUTO_INJECTION_FILTER=ABSENT
INSTALLABLE_DEB=NOT_PRODUCED
EOF

cat > "$EVIDENCE/validation-report.txt" <<EOF
TASK_ID=VCAM-PRO-LEGACY-EQUIVALENT-REAL-HOOK-LINKAGE-GATE-001
AUTHORITATIVE_BASE=$BASE
STATIC_PARITY_EVIDENCE=$PARITY
LEGACY_REFERENCE_SHA=$LEGACY
ANALYSIS_DYLIB=VCAMProLegacyRealHookLinkageGate.dylib
AUTHORITATIVE_BASE_CONFIRMED=PASS
LEGACY_STRUCTURAL_PARITY_FROZEN=PASS
REFERENCE_CAMERA_HOOK_SOURCE_UNCHANGED=PASS
MEDIASERVERD_RUNTIME_SOURCE_UNCHANGED=PASS
VCAMPRO_ENTRY_SOURCE_UNCHANGED=PASS
REAL_REFERENCE_HOOK_LINKED=PASS
REAL_REPLACEMENT_SYMBOL_PRESENT=PASS
REAL_ORIGINAL_STORAGE_PRESENT=PASS
MSHOOKFUNCTION_REFERENCE_PRESENT=PASS
CMSAMPLEBUFFER_TARGET_REFERENCE_PRESENT=PASS
ARM64=PASS
MINIMUM_IOS_15=PASS
ROOTHIDE_LINKAGE_MODEL=PASS
AUTO_INJECTION_FILTER_ABSENT=PASS
ACTIVE_HOOK_CONSTRUCTOR_ABSENT=PASS
RUNTIME_HOOK_INSTALLATION=NOT_PERFORMED
CAMERA_INTERCEPTION=NOT_PERFORMED
FRAME_CALLBACK=NOT_PERFORMED
FRAME_ACCESS=NOT_PERFORMED
FRAME_SUBSTITUTION=NOT_PERFORMED
DUMMY_SELFTEST_DEVELOPMENT=STOPPED
PR19_MODIFIED=NO
REFERENCE_REPOS_MODIFIED=NO
MERGE_PERFORMED=NO
RELEASE_PERFORMED=NO
DEPLOY_PERFORMED=NO
DEVICE_ACTION=NO
EOF

cat "$EVIDENCE/validation-report.txt"
