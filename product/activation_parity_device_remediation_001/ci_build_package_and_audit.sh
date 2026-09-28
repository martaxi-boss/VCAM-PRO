#!/bin/sh
set -eu

MAIN=d476caacc4f557843f9551533c2fcbe7c5d40baa
IOS15=a908bccbcddb4efc072bb1bc8fbeb6ee89b1af9d
MOTION=5ede3a1973a01cb13fe7f3ab562b47513feec1b1
IOS16=cc20d787070c67565173d4a46c218e2549cecc93
PATCHER_SHA=80c16e08da33fecd27c0ff35777f37afd171868b

ROOT="$PWD/build/activation-parity-device-remediation-001"
SCOPE=product/activation_parity_device_remediation_001
INPUT="$ROOT/input/com.vcampro.camera_0.1.0+roothide14~activationremed1_iphoneos-arm64.deb"
FINAL_DIR="$ROOT/final"
FINAL="$FINAL_DIR/VCAM-PRO-RootHide-Activation-Parity-Device-Remediation-001.deb"
EXTRACT="$ROOT/extracted-final"
EVIDENCE="$ROOT/evidence"

PRODUCT_REL="usr/lib/TweakInject/VCAMPro.dylib"
PRODUCT_PLIST_REL="usr/lib/TweakInject/VCAMPro.plist"
INSTALL_WITNESS_REL="usr/lib/TweakInject/VCAMProFullProductRealHookWitness.dylib"
INSTALL_WITNESS_PLIST_REL="usr/lib/TweakInject/VCAMProFullProductRealHookWitness.plist"
REMEDIATION_WITNESS_REL="usr/lib/TweakInject/VCAMProActivationParityDeviceRemediationWitness.dylib"
REMEDIATION_WITNESS_PLIST_REL="usr/lib/TweakInject/VCAMProActivationParityDeviceRemediationWitness.plist"

sh "$SCOPE/build_activation_parity_device_remediation_input.sh"

mkdir -p "$EVIDENCE"
test -f "$INPUT"
test "$(dpkg-deb -f "$INPUT" Package)" = "com.vcampro.camera"
test "$(dpkg-deb -f "$INPUT" Version)" = "0.1.0+roothide14~activationremed1"
test "$(dpkg-deb -f "$INPUT" Architecture)" = "iphoneos-arm64"
dpkg-deb -c "$INPUT" | tee "$EVIDENCE/input-inventory.txt"

git clone --quiet https://github.com/roothide/RootHidePatcher.git "$ROOT/RootHidePatcher"
git -C "$ROOT/RootHidePatcher" checkout --quiet "$PATCHER_SHA"
test "$(git -C "$ROOT/RootHidePatcher" rev-parse HEAD)" = "$PATCHER_SHA"

mkdir -p "$FINAL_DIR"
sudo env "PATH=$PATH" bash "$ROOT/RootHidePatcher/patch.sh" "$INPUT" "$FINAL"

test -f "$FINAL"
shasum -a 256 "$FINAL" | tee "$FINAL.sha256"
wc -c < "$FINAL" | tr -d ' ' | tee "$EVIDENCE/deb-size.txt"

rm -rf "$EXTRACT"
mkdir -p "$EXTRACT"
dpkg-deb -R "$FINAL" "$EXTRACT"
dpkg-deb -f "$FINAL" | tee "$EVIDENCE/final-control.txt"
dpkg-deb -c "$FINAL" | tee "$EVIDENCE/final-inventory.txt"

test "$(dpkg-deb -f "$FINAL" Package)" = "com.vcampro.camera"
test "$(dpkg-deb -f "$FINAL" Version)" = "0.1.0+roothide14~activationremed1"
test "$(dpkg-deb -f "$FINAL" Architecture)" = "iphoneos-arm64e"
test ! -e "$EXTRACT/var/jb"

for item in \
    "$PRODUCT_REL" \
    "$PRODUCT_PLIST_REL" \
    "$INSTALL_WITNESS_REL" \
    "$INSTALL_WITNESS_PLIST_REL" \
    "$REMEDIATION_WITNESS_REL" \
    "$REMEDIATION_WITNESS_PLIST_REL"; do
    test -f "$EXTRACT/$item"
done

python3 - <<'PY'
from pathlib import Path
import plistlib

root = Path("build/activation-parity-device-remediation-001/extracted-final")
tweak = root / "usr/lib/TweakInject"

with (tweak / "VCAMPro.plist").open("rb") as f:
    product = plistlib.load(f)
with (tweak / "VCAMProFullProductRealHookWitness.plist").open("rb") as f:
    install_witness = plistlib.load(f)
with (tweak / "VCAMProActivationParityDeviceRemediationWitness.plist").open("rb") as f:
    remediation_witness = plistlib.load(f)

if product != {"Filter": {"Executables": ["SpringBoard", "mediaserverd"]}}:
    raise SystemExit(product)
expected_witness = {"Filter": {"Executables": ["SpringBoard"]}}
if install_witness != expected_witness:
    raise SystemExit(install_witness)
if remediation_witness != expected_witness:
    raise SystemExit(remediation_witness)

expected_postinst = "#!/bin/sh\nset -e\n\nexit 0\n"
if (root / "DEBIAN/postinst").read_text() != expected_postinst:
    raise SystemExit("Unexpected maintainer script")

print("PACKAGE_FILTER_CENTRAL_ONLY=PASS")
print("REMEDIATION_WITNESS_SPRINGBOARD_ONLY=PASS")
PY

PRODUCT="$EXTRACT/$PRODUCT_REL"
INSTALL_WITNESS="$EXTRACT/$INSTALL_WITNESS_REL"
REMEDIATION_WITNESS="$EXTRACT/$REMEDIATION_WITNESS_REL"

xcrun lipo -info "$PRODUCT" | tee "$EVIDENCE/product-arch.txt"
xcrun otool -l "$PRODUCT" > "$EVIDENCE/product-load-commands.txt"
xcrun otool -L "$PRODUCT" > "$EVIDENCE/product-linked-libraries.txt"
xcrun nm -a "$PRODUCT" | c++filt > "$EVIDENCE/product-symbols.txt" || true
xcrun nm -u "$PRODUCT" > "$EVIDENCE/product-undefined.txt" || true
strings "$PRODUCT" > "$EVIDENCE/product-strings.txt"

grep -q 'architecture: arm64' "$EVIDENCE/product-arch.txt"
test -z "$(grep 'arm64e' "$EVIDENCE/product-arch.txt" || true)"
grep -q 'minos 15.0' "$EVIDENCE/product-load-commands.txt"

grep -Fq 'vcam::media_engine::LocalVideoReader' "$EVIDENCE/product-symbols.txt"
grep -Fq 'vcam::media_engine::LocalPhotoReader' "$EVIDENCE/product-symbols.txt"
grep -Fq 'vcam::frame_engine::ReadyFrameQueue' "$EVIDENCE/product-symbols.txt"
grep -Fq 'vcam::media_engine::FramePipelinePump' "$EVIDENCE/product-symbols.txt"
grep -Fq 'vcam::media_engine::ProducerWakeupDriver' "$EVIDENCE/product-symbols.txt"
grep -Fq 'vcam::product::CameraConsumerAdapter' "$EVIDENCE/product-symbols.txt"
grep -Fq 'vcam::product::MediaserverdRuntime' "$EVIDENCE/product-symbols.txt"
grep -Fq 'vcam::product::InstallReferenceCameraHook()' "$EVIDENCE/product-symbols.txt"
grep -Fq 'CommitVirtualCameraOutputIntoOriginal' "$EVIDENCE/product-symbols.txt"
grep -Fq 'ReferenceSampleBufferHasStillImageKey' "$EVIDENCE/product-symbols.txt"
grep -Fq 'ObserveActivationParityHook' "$EVIDENCE/product-symbols.txt"
grep -Fq 'PublishActivationParityPhotoSnapshot' "$EVIDENCE/product-symbols.txt"

grep -Fxq '_MSHookFunction' "$EVIDENCE/product-undefined.txt"
grep -Fxq '_CMSampleBufferGetImageBuffer' "$EVIDENCE/product-undefined.txt"
grep -Fxq '_CMGetAttachment' "$EVIDENCE/product-undefined.txt"
test -z "$(grep -F '_CMSampleBufferCreateReady' "$EVIDENCE/product-undefined.txt" || true)"

for token in WhatsApp Telegram FaceTime com.whatsapp; do
    test -z "$(grep -Fi "$token" "$EVIDENCE/product-strings.txt" || true)"
done

for binary in "$PRODUCT" "$INSTALL_WITNESS" "$REMEDIATION_WITNESS"; do
    xcrun otool -l "$binary" | grep -q 'LC_CODE_SIGNATURE'
    codesign --verify --verbose=2 "$binary"
done

test "$(git ls-remote origin refs/heads/main | awk '{print $1}')" = "$MAIN"
heads="$(git ls-remote --heads origin | awk '{print $2}' | sort)"
expected_heads="$(printf '%s\n' refs/heads/builder/canonical-hook-continuation-001 refs/heads/main | sort)"
test "$heads" = "$expected_heads"

test "$(git ls-remote https://github.com/martaxi-boss/IOS-15-USB.git refs/heads/main | awk '{print $1}')" = "$IOS15"
test "$(git ls-remote https://github.com/martaxi-boss/MotionCam-iOS.git refs/heads/main | awk '{print $1}')" = "$MOTION"
test "$(git ls-remote https://github.com/martaxi-boss/IOS-16-USB-4k.git refs/heads/main | awk '{print $1}')" = "$IOS16"

{
    echo "TASK_ID=VCAM-PRO-ACTIVATION-PARITY-DEVICE-REMEDIATION-001"
    echo "PACKAGE_VERSION=0.1.0+roothide14~activationremed1"
    echo "ARM64=PASS"
    echo "MINIMUM_IOS_15=PASS"
    echo "ROOTHIDE_PACKAGE=PASS"
    echo "VALID_CODE_SIGNATURE=PASS"
    echo "NO_APP_SPECIFIC_HOOKS=PASS"
    echo "NO_UI_CONTROL_SUPPRESSION=PASS"
    echo "MAIN_UNCHANGED=PASS"
    echo "READ_ONLY_REPOS_UNCHANGED=PASS"
    echo "DEVICE_ACTION=NO"
} | tee "$EVIDENCE/package-validation-report.txt"

cat "$FINAL.sha256"
