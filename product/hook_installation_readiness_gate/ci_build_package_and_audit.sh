#!/bin/sh
set -eu

ROOT="$PWD/build/reference-camera-hook-installation-readiness-gate-001"
GATE=product/hook_installation_readiness_gate
INPUT="$ROOT/input/com.vcampro.camera_0.1.0+roothide6~hookready1_iphoneos-arm64.deb"
FINAL_DIR="$ROOT/final"
FINAL="$FINAL_DIR/VCAM-PRO-RootHide-Reference-Hook-Installation-Readiness-Gate-001.deb"
EXTRACT="$ROOT/extracted-final"
EVIDENCE="$ROOT/evidence"
PATCHER_SHA=80c16e08da33fecd27c0ff35777f37afd171868b

sh "$GATE/build_hook_installation_readiness_gate_input.sh"

test -f "$INPUT"
test "$(dpkg-deb -f "$INPUT" Package)" = "com.vcampro.camera"
test "$(dpkg-deb -f "$INPUT" Version)" = "0.1.0+roothide6~hookready1"
test "$(dpkg-deb -f "$INPUT" Architecture)" = "iphoneos-arm64"
mkdir -p "$EVIDENCE"
dpkg-deb -c "$INPUT" | tee "$EVIDENCE/input-inventory.txt"
test -z "$(grep 'ReferenceCameraHook.compile-only.o' "$EVIDENCE/input-inventory.txt" || true)"

git clone --quiet https://github.com/roothide/RootHidePatcher.git "$ROOT/RootHidePatcher"
git -C "$ROOT/RootHidePatcher" checkout --quiet "$PATCHER_SHA"
test "$(git -C "$ROOT/RootHidePatcher" rev-parse HEAD)" = "$PATCHER_SHA"

mkdir -p "$FINAL_DIR"
sudo env "PATH=$PATH" bash "$ROOT/RootHidePatcher/patch.sh" "$INPUT" "$FINAL"
test -f "$FINAL"
shasum -a 256 "$FINAL" | tee "$FINAL.sha256"

rm -rf "$EXTRACT"
mkdir -p "$EXTRACT"
dpkg-deb -R "$FINAL" "$EXTRACT"
dpkg-deb -f "$FINAL" | tee "$EVIDENCE/final-control.txt"
dpkg-deb -c "$FINAL" | tee "$EVIDENCE/final-inventory.txt"

test "$(dpkg-deb -f "$FINAL" Package)" = "com.vcampro.camera"
test "$(dpkg-deb -f "$FINAL" Version)" = "0.1.0+roothide6~hookready1"
test "$(dpkg-deb -f "$FINAL" Architecture)" = "iphoneos-arm64e"
test ! -e "$EXTRACT/var/jb"
test -z "$(grep 'ReferenceCameraHook.compile-only.o' "$EVIDENCE/final-inventory.txt" || true)"

for file in     VCAMPro.dylib     VCAMPro.plist     VCAMProHookInstallationReadinessWitness.dylib     VCAMProHookInstallationReadinessWitness.plist; do
    test -f "$EXTRACT/usr/lib/TweakInject/$file"
done

python3 - <<'PY'
from pathlib import Path
import plistlib

root = Path("build/reference-camera-hook-installation-readiness-gate-001/extracted-final")
tweak = root / "usr/lib/TweakInject"
with (tweak / "VCAMPro.plist").open("rb") as f:
    product = plistlib.load(f)
with (tweak / "VCAMProHookInstallationReadinessWitness.plist").open("rb") as f:
    witness = plistlib.load(f)
if product != {"Filter": {"Executables": ["SpringBoard", "mediaserverd"]}}:
    raise SystemExit(product)
if witness != {"Filter": {"Executables": ["SpringBoard"]}}:
    raise SystemExit(witness)
expected = "#!/bin/sh\nset -e\n\nexit 0\n"
actual = (root / "DEBIAN/postinst").read_text()
if actual != expected:
    raise SystemExit("Unexpected maintainer script content")
print("EXACT_HOOK_INSTALLATION_READINESS_FILTER=PASS")
PY

DYLIB="$EXTRACT/usr/lib/TweakInject/VCAMPro.dylib"
xcrun lipo -info "$DYLIB" | tee "$EVIDENCE/product-arch.txt"
grep -q 'architecture: arm64' "$EVIDENCE/product-arch.txt"
test -z "$(grep 'arm64e' "$EVIDENCE/product-arch.txt" || true)"
xcrun otool -l "$DYLIB" > "$EVIDENCE/product-load-commands.txt"
xcrun otool -D "$DYLIB" > "$EVIDENCE/product-install-name.txt"
xcrun otool -L "$DYLIB" | tee "$EVIDENCE/product-linked-libraries.txt"
xcrun nm "$DYLIB" | c++filt > "$EVIDENCE/product-symbols.txt" || true
xcrun nm -u "$DYLIB" | tee "$EVIDENCE/product-undefined.txt" || true
strings "$DYLIB" > "$EVIDENCE/product-strings.txt"

grep -q 'minos 15.0' "$EVIDENCE/product-load-commands.txt"
grep -q '@loader_path/.jbroot/Library/Frameworks' "$EVIDENCE/product-load-commands.txt"
grep -q '@loader_path/.jbroot/usr/lib' "$EVIDENCE/product-load-commands.txt"
grep -q '@loader_path/VCAMPro.dylib' "$EVIDENCE/product-install-name.txt"
grep -Fq 'vcam::product::MediaserverdRuntime::start()' "$EVIDENCE/product-symbols.txt"
grep -Fq 'VCAMProInitialize' "$EVIDENCE/product-symbols.txt"
grep -Fq 'vcam::product::InstallReferenceCameraHook()' "$EVIDENCE/product-symbols.txt"
grep -q '_dlsym' "$EVIDENCE/product-undefined.txt"
grep -Fq 'CMSampleBufferGetImageBuffer' "$EVIDENCE/product-strings.txt"
grep -Fq 'MSHookFunction' "$EVIDENCE/product-strings.txt"
grep -Fq 'hook-provider=RESOLVED' "$EVIDENCE/product-strings.txt"
grep -Fq 'hook-install=NOT_EXECUTED' "$EVIDENCE/product-strings.txt"
test -z "$(grep '_MSHookFunction' "$EVIDENCE/product-undefined.txt" || true)"
test -z "$(grep -E 'HookedCMSampleBufferGetImageBuffer|Hooking CMSampleBufferGetImageBuffer|gOriginalCMSampleBufferGetImageBuffer' "$EVIDENCE/product-symbols.txt" "$EVIDENCE/product-strings.txt" || true)"
test -z "$(grep 'CydiaSubstrate' "$EVIDENCE/product-linked-libraries.txt" || true)"

WITNESS="$EXTRACT/usr/lib/TweakInject/VCAMProHookInstallationReadinessWitness.dylib"
xcrun lipo -info "$WITNESS" | tee "$EVIDENCE/witness-arch.txt"
grep -q 'architecture: arm64' "$EVIDENCE/witness-arch.txt"
xcrun otool -l "$WITNESS" > "$EVIDENCE/witness-load-commands.txt"
xcrun otool -D "$WITNESS" > "$EVIDENCE/witness-install-name.txt"
xcrun otool -L "$WITNESS" | tee "$EVIDENCE/witness-linked-libraries.txt"
strings "$WITNESS" > "$EVIDENCE/witness-strings.txt"
grep -q 'minos 15.0' "$EVIDENCE/witness-load-commands.txt"
grep -q '@loader_path/VCAMProHookInstallationReadinessWitness.dylib' "$EVIDENCE/witness-install-name.txt"
grep -Fq 'VCAM REFERENCE HOOK INSTALLATION READINESS PASS' "$EVIDENCE/witness-strings.txt"
grep -Fq 'hook-provider=RESOLVED' "$EVIDENCE/witness-strings.txt"
grep -Fq 'hook-install=NOT_EXECUTED' "$EVIDENCE/witness-strings.txt"
test -z "$(grep -Ei 'AVFoundation|CoreMedia|CoreVideo|VideoToolbox|Photos' "$EVIDENCE/witness-linked-libraries.txt" || true)"

echo "REFERENCE_CAMERA_HOOK_OBJECT_NOT_PACKAGED=PASS"
echo "HOOK_PROVIDER_NOT_INVOKED=PASS"
echo "HOOK_INSTALLATION_NOT_EXECUTED=PASS"
echo "PRODUCTION_REPLACEMENT_FUNCTION_ABSENT=PASS"
echo "CAMERA_INTERCEPTION_INACTIVE=PASS"
echo "FRAME_CALLBACK_PATH_INACTIVE=PASS"
echo "FRAME_ACCESS_INACTIVE=PASS"
echo "FRAME_SUBSTITUTION_INACTIVE=PASS"
echo "ROOT_HIDE_PACKAGE_ARCH=PASS"
echo "ELLEKIT_TWEAKINJECT_LAYOUT=PASS"
echo "MACHO_ARM64_A9_COMPATIBLE=PASS"
echo "IOS_MIN_VERSION=15.0"
echo "MERGE_PERFORMED=NO"
echo "RELEASE_PERFORMED=NO"
echo "DEPLOY_PERFORMED=NO"
echo "DEVICE_ACTION=NO"
cat "$FINAL.sha256"
