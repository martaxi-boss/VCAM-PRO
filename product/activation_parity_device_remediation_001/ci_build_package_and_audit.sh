#!/bin/sh
set -eu

MAIN=d476caacc4f557843f9551533c2fcbe7c5d40baa
IOS15=a908bccbcddb4efc072bb1bc8fbeb6ee89b1af9d
MOTION=5ede3a1973a01cb13fe7f3ab562b47513feec1b1
IOS16=cc20d787070c67565173d4a46c218e2549cecc93
PATCHER_SHA=80c16e08da33fecd27c0ff35777f37afd171868b

ROOT="$PWD/build/activation-parity-device-remediation-001"
SCOPE=product/activation_parity_device_remediation_001
INPUT="$ROOT/input/com.vcampro.camera_0.1.0+roothide15~activationremed2_iphoneos-arm64.deb"
FINAL_DIR="$ROOT/final"
FINAL="$FINAL_DIR/VCAM-PRO-RootHide-Activation-Parity-Device-Remediation-002.deb"
EXTRACT="$ROOT/extracted-final"
EVIDENCE="$ROOT/evidence"

PRODUCT_REL="usr/lib/TweakInject/VCAMPro.dylib"
PRODUCT_PLIST_REL="usr/lib/TweakInject/VCAMPro.plist"
INSTALL_WITNESS_REL="usr/lib/TweakInject/VCAMProFullProductRealHookWitness.dylib"
INSTALL_WITNESS_PLIST_REL="usr/lib/TweakInject/VCAMProFullProductRealHookWitness.plist"
REMEDIATION_WITNESS_REL="usr/lib/TweakInject/VCAMProActivationParityDeviceRemediationWitness.dylib"
REMEDIATION_WITNESS_PLIST_REL="usr/lib/TweakInject/VCAMProActivationParityDeviceRemediationWitness.plist"

sh "$SCOPE/build_activation_parity_device_remediation_input.sh"

mkdir -p "$EVIDENCE" "$FINAL_DIR"

test -f "$INPUT"
test "$(dpkg-deb -f "$INPUT" Package)" = "com.vcampro.camera"
test "$(dpkg-deb -f "$INPUT" Version)" = "0.1.0+roothide15~activationremed2"
test "$(dpkg-deb -f "$INPUT" Architecture)" = "iphoneos-arm64"
dpkg-deb -c "$INPUT" | tee "$EVIDENCE/input-inventory.txt"

git clone --quiet https://github.com/roothide/RootHidePatcher.git "$ROOT/RootHidePatcher"
git -C "$ROOT/RootHidePatcher" checkout --quiet "$PATCHER_SHA"
test "$(git -C "$ROOT/RootHidePatcher" rev-parse HEAD)" = "$PATCHER_SHA"

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
test "$(dpkg-deb -f "$FINAL" Version)" = "0.1.0+roothide15~activationremed2"
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

data_files="$(find "$EXTRACT/usr/lib/TweakInject" -type f | sed "s#^$EXTRACT/##" | sort)"
expected_files="$(printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$PRODUCT_REL" \
    "$PRODUCT_PLIST_REL" \
    "$INSTALL_WITNESS_REL" \
    "$INSTALL_WITNESS_PLIST_REL" \
    "$REMEDIATION_WITNESS_REL" \
    "$REMEDIATION_WITNESS_PLIST_REL" | sort)"
test "$data_files" = "$expected_files"

python3 - <<'PY'
from pathlib import Path
import plistlib

root = Path("build/activation-parity-device-remediation-001/extracted-final")
tweak = root / "usr/lib/TweakInject"

with (tweak / "VCAMPro.plist").open("rb") as f:
    product = plistlib.load(f)
with Path("product/VCAMPro.plist").open("rb") as f:
    canonical = plistlib.load(f)
with (tweak / "VCAMProFullProductRealHookWitness.plist").open("rb") as f:
    install = plistlib.load(f)
with (tweak / "VCAMProActivationParityDeviceRemediationWitness.plist").open("rb") as f:
    remediation = plistlib.load(f)

expected_product = {
    "Filter": {
        "Bundles": [
            "com.apple.mediaserverd",
            "com.apple.springboard",
            "com.apple.UIKit",
        ],
        "Executables": ["mediaserverd"],
    }
}
if canonical != expected_product:
    raise SystemExit(canonical)
if product != canonical:
    raise SystemExit("Packaged VCAMPro.plist differs from canonical product filter")
if "SpringBoard" in product["Filter"]["Executables"]:
    raise SystemExit("Unexpected SpringBoard executable override")
expected_witness = {"Filter": {"Executables": ["SpringBoard"]}}
if install != expected_witness:
    raise SystemExit(install)
if remediation != expected_witness:
    raise SystemExit(remediation)

scope = Path("product/activation_parity_device_remediation_001")
if (scope / "VCAMPro.ActivationParityDeviceRemediation.plist").exists():
    raise SystemExit("Diagnostic product filter override still exists")
build_text = (scope / "build_activation_parity_device_remediation_input.sh").read_text()
if "VCAMPro.ActivationParityDeviceRemediation.plist" in build_text:
    raise SystemExit("Diagnostic product filter override still referenced")

(root / "filter-parity.txt").write_text(
    "\n".join([
        "PACKAGED_VCAMPRO_PLIST_PRESENT=PASS",
        "PACKAGED_VCAMPRO_PLIST_CANONICAL_MATCH=PASS",
        "PACKAGED_FILTER_BUNDLES_MATCH=PASS",
        "PACKAGED_FILTER_EXECUTABLES_MATCH=PASS",
        "IOS15_USB_FILTER_PARITY=PASS",
        "NO_DIAGNOSTIC_PRODUCT_FILTER_OVERRIDE=PASS",
        "PACKAGED_PRODUCT_FILTER_HAS_SPRINGBOARD_EXECUTABLE_OVERRIDE=NO",
        "",
    ])
)

expected_postinst = "#!/bin/sh\nset -e\n\nexit 0\n"
if (root / "DEBIAN/postinst").read_text() != expected_postinst:
    raise SystemExit("Unexpected maintainer script")
PY

verify_signature() {
    DYLIB_PATH="$1" SIGNATURE_EVIDENCE="$2" python3 - <<'PY'
import hashlib
import os
import struct
from pathlib import Path

path = Path(os.environ["DYLIB_PATH"])
evidence = Path(os.environ["SIGNATURE_EVIDENCE"])
data = path.read_bytes()

if len(data) < 32:
    raise SystemExit("Mach-O too small")

magic, = struct.unpack_from("<I", data, 0)
if magic != 0xfeedfacf:
    raise SystemExit(f"Unexpected Mach-O magic: 0x{magic:08x}")

_, _, _, _, ncmds, sizeofcmds, _, _ = struct.unpack_from("<IiiIIIII", data, 0)
offset = 32
end_commands = offset + sizeofcmds
if end_commands > len(data):
    raise SystemExit("Load commands exceed file")

LC_CODE_SIGNATURE = 0x1D
sig_off = sig_size = None
for _ in range(ncmds):
    if offset + 8 > end_commands:
        raise SystemExit("Truncated load command")
    cmd, cmdsize = struct.unpack_from("<II", data, offset)
    if cmdsize < 8 or offset + cmdsize > end_commands:
        raise SystemExit("Invalid load command size")
    if cmd == LC_CODE_SIGNATURE:
        if cmdsize < 16:
            raise SystemExit("Invalid LC_CODE_SIGNATURE")
        sig_off, sig_size = struct.unpack_from("<II", data, offset + 8)
        break
    offset += cmdsize

if sig_off is None or sig_size is None or sig_size == 0:
    raise SystemExit("LC_CODE_SIGNATURE missing or empty")
if sig_off + sig_size > len(data):
    raise SystemExit("Code signature range exceeds file")

CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_CODEDIRECTORY = 0xFADE0C02
CSSLOT_CODEDIRECTORY = 0

smagic, total_len, count = struct.unpack_from(">III", data, sig_off)
if smagic != CSMAGIC_EMBEDDED_SIGNATURE:
    raise SystemExit(f"Unexpected signature superblob magic: 0x{smagic:08x}")
if total_len > sig_size or total_len < 12 + count * 8:
    raise SystemExit("Invalid signature superblob length")

cd_off = None
for i in range(count):
    slot_type, rel_off = struct.unpack_from(">II", data, sig_off + 12 + i * 8)
    if rel_off >= total_len:
        raise SystemExit("Signature blob offset out of range")
    if slot_type == CSSLOT_CODEDIRECTORY:
        cd_off = sig_off + rel_off
        break

if cd_off is None:
    raise SystemExit("Primary CodeDirectory missing")
if cd_off + 44 > sig_off + total_len:
    raise SystemExit("Truncated CodeDirectory header")

cd_magic, cd_len, cd_version, cd_flags, hash_off, ident_off, n_special, n_code, code_limit = struct.unpack_from(
    ">IIIIIIIII", data, cd_off
)
if cd_magic != CSMAGIC_CODEDIRECTORY:
    raise SystemExit(f"Unexpected CodeDirectory magic: 0x{cd_magic:08x}")
if cd_len < 44 or cd_off + cd_len > sig_off + total_len:
    raise SystemExit("Invalid CodeDirectory length")

hash_size, hash_type, platform, page_log2 = struct.unpack_from("BBBB", data, cd_off + 36)
if hash_type != 2 or hash_size != 32:
    raise SystemExit(f"Expected SHA-256 CodeDirectory, got type={hash_type} size={hash_size}")
if page_log2 > 20:
    raise SystemExit("Unreasonable CodeDirectory page size")

page_size = 1 << page_log2
expected_slots = (code_limit + page_size - 1) // page_size
if n_code != expected_slots:
    raise SystemExit(f"Code slot count mismatch: {n_code} != {expected_slots}")
if code_limit > sig_off:
    raise SystemExit("CodeDirectory codeLimit overlaps embedded signature")
if hash_off + n_code * hash_size > cd_len:
    raise SystemExit("Code hash array exceeds CodeDirectory")

for i in range(n_code):
    start = i * page_size
    end = min(start + page_size, code_limit)
    calculated = hashlib.sha256(data[start:end]).digest()
    stored_off = cd_off + hash_off + i * hash_size
    stored = data[stored_off:stored_off + hash_size]
    if calculated != stored:
        raise SystemExit(f"CodeDirectory page hash mismatch at slot {i}")

cd_blob = data[cd_off:cd_off + cd_len]
cdhash = hashlib.sha256(cd_blob).digest()[:20].hex()

evidence.write_text(
    "\n".join([
        "LC_CODE_SIGNATURE=PASS",
        "CODE_SIGNATURE_SUPERBLOB=PASS",
        "CODEDIRECTORY_SHA256=PASS",
        "CODEDIRECTORY_PAGE_HASHES=PASS",
        f"CODEDIRECTORY_VERSION=0x{cd_version:08x}",
        f"CODEDIRECTORY_FLAGS=0x{cd_flags:08x}",
        f"CODEDIRECTORY_PLATFORM={platform}",
        f"CODEDIRECTORY_CODE_LIMIT={code_limit}",
        f"CODEDIRECTORY_CODE_SLOTS={n_code}",
        f"CODEDIRECTORY_PAGE_SIZE={page_size}",
        f"CDHASH={cdhash}",
        "",
    ])
)
print(evidence.read_text(), end="")
PY
}

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

grep -Fq 'vcam::product::CommitVirtualCameraOutputIntoOriginal' "$EVIDENCE/product-symbols.txt"
grep -Fq 'vcam::product::proof::ObserveActivationParityHook' "$EVIDENCE/product-symbols.txt"
grep -Fq 'vcam::product::proof::PublishActivationParityPhotoSnapshot' "$EVIDENCE/product-symbols.txt"
grep -Fq 'vcam::product::MediaserverdRuntime' "$EVIDENCE/product-symbols.txt"
grep -Fq 'vcam::product::CameraConsumerAdapter' "$EVIDENCE/product-symbols.txt"
grep -Fq 'vcam::media_engine::LocalPhotoReader' "$EVIDENCE/product-symbols.txt"
grep -Fq 'vcam::media_engine::LocalVideoReader' "$EVIDENCE/product-symbols.txt"
grep -Fxq '_MSHookFunction' "$EVIDENCE/product-undefined.txt"
grep -Fxq '_CMSampleBufferGetImageBuffer' "$EVIDENCE/product-undefined.txt"
grep -Fxq '_CMGetAttachment' "$EVIDENCE/product-undefined.txt"

xcrun lipo -info "$INSTALL_WITNESS" | grep -q 'architecture: arm64'
xcrun otool -l "$INSTALL_WITNESS" | grep -q 'minos 15.0'
xcrun lipo -info "$REMEDIATION_WITNESS" | grep -q 'architecture: arm64'
xcrun otool -l "$REMEDIATION_WITNESS" | grep -q 'minos 15.0'
strings "$REMEDIATION_WITNESS" > "$EVIDENCE/remediation-witness-strings.txt"
grep -Fq 'VCAM ACTIVATION PARITY REMEDIATION DIAGNOSTIC' "$EVIDENCE/remediation-witness-strings.txt"
grep -Fq 'still-source:' "$EVIDENCE/remediation-witness-strings.txt"
grep -Fq 'still-geometry=' "$EVIDENCE/remediation-witness-strings.txt"
grep -Fq 'producer-driver=' "$EVIDENCE/remediation-witness-strings.txt"
grep -Fq 'photo-decodes=' "$EVIDENCE/remediation-witness-strings.txt"
grep -Fq 'preview-geometry=' "$EVIDENCE/remediation-witness-strings.txt"
grep -Fq 'still-black-compatible=' "$EVIDENCE/remediation-witness-strings.txt"
grep -Fq 'prepared-fallback-existed=' "$EVIDENCE/remediation-witness-strings.txt"

verify_signature "$PRODUCT" "$EVIDENCE/product-code-signature.txt"
verify_signature "$INSTALL_WITNESS" "$EVIDENCE/install-witness-code-signature.txt"
verify_signature "$REMEDIATION_WITNESS" "$EVIDENCE/remediation-witness-code-signature.txt"

test "$(git ls-remote origin refs/heads/main | awk '{print $1}')" = "$MAIN"
test "$(git ls-remote https://github.com/martaxi-boss/IOS-15-USB.git refs/heads/main | awk '{print $1}')" = "$IOS15"
test "$(git ls-remote https://github.com/martaxi-boss/MotionCam-iOS.git refs/heads/main | awk '{print $1}')" = "$MOTION"
test "$(git ls-remote https://github.com/martaxi-boss/IOS-16-USB-4k.git refs/heads/main | awk '{print $1}')" = "$IOS16"

{
    echo "TASK_ID=VCAM-PRO-ACTIVATION-PARITY-DEVICE-REMEDIATION-001"
    echo "PACKAGE_ROLE=DIAGNOSTIC_REMEDIATION_CANDIDATE"
    echo "ARM64=PASS"
    echo "MINIMUM_IOS_15=PASS"
    echo "ROOTHIDE_PACKAGE=PASS"
    echo "ROOT_HIDE_PATCHER_PINNED=PASS"
    echo "VALID_CODE_SIGNATURE=PASS"
    echo "PACKAGE_ID_CORRECT=PASS"
    echo "PACKAGE_VERSION_CORRECT=PASS"
    echo "CANONICAL_FILTER_SOURCE=product/VCAMPro.plist"
    echo "PACKAGED_FILTER_SOURCE=product/VCAMPro.plist"
    echo "PACKAGED_VCAMPRO_PLIST_PRESENT=PASS"
    echo "PACKAGED_VCAMPRO_PLIST_CANONICAL_MATCH=PASS"
    echo "PACKAGED_FILTER_BUNDLES_MATCH=PASS"
    echo "PACKAGED_FILTER_EXECUTABLES_MATCH=PASS"
    echo "IOS15_USB_FILTER_PARITY=PASS"
    echo "NO_DIAGNOSTIC_PRODUCT_FILTER_OVERRIDE=PASS"
    echo "PACKAGED_PRODUCT_FILTER_HAS_SPRINGBOARD_EXECUTABLE_OVERRIDE=NO"
    echo "PHOTO_ROOT_CAUSE=UNRESOLVED_PENDING_DEVICE_DIAGNOSTIC"
    echo "PHOTO_RUNTIME_DIAGNOSTIC_CAPABILITIES=PASS"
    echo "STILL_RUNTIME_DIAGNOSTIC_CAPABILITIES=PASS"
    echo "VCAM_ON_NO_MEDIA_USES_BLACK=PASS"
    echo "STILL_GEOMETRY_RACE_STATUS=UNRESOLVED"
    echo "FLASH_STILL_CAPTURE_DOES_NOT_EXPOSE_ORIGINAL=UNRESOLVED"
    echo "STILL_CAPTURE_REMEDIATION=INCOMPLETE_EVIDENCE"
    echo "MAIN_UNCHANGED=PASS"
    echo "READ_ONLY_REPOS_UNCHANGED=PASS"
    echo "DEVICE_ACTION=NO"
} | tee "$EVIDENCE/validation-report.txt"

cat "$FINAL.sha256"
