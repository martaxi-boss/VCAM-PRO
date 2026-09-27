#!/bin/sh
set -eu

START=949b7af7725caf672ea4ddaea12df08485b0550f
MAIN=d476caacc4f557843f9551533c2fcbe7c5d40baa
IOS15=a908bccbcddb4efc072bb1bc8fbeb6ee89b1af9d
MOTION=5ede3a1973a01cb13fe7f3ab562b47513feec1b1
IOS16=cc20d787070c67565173d4a46c218e2549cecc93
PATCHER_SHA=80c16e08da33fecd27c0ff35777f37afd171868b
HOOK_BLOB=b3b5360757d17951b0c508ab455d7ea4ffb0d6fe
ADAPTER_CPP_BLOB=c49806ae6af94f65d3d8d4b9158dd9eb38b9eec8
ADAPTER_H_BLOB=3577bd2935c72a69529c855c8730d6c75054ab34

ROOT="$PWD/build/local-photo-pipeline-ready-pass-through-001"
SCOPE=product/real_camera_callback_pass_through_001
FULL_SCOPE=product/full_product_real_hook_001
INPUT="$ROOT/input/com.vcampro.camera_0.1.0+roothide10~photoready1_iphoneos-arm64.deb"
FINAL_DIR="$ROOT/final"
FINAL="$FINAL_DIR/VCAM-PRO-RootHide-Local-Photo-Pipeline-Ready-Pass-Through-001.deb"
EXTRACT="$ROOT/extracted-final"
EVIDENCE="$ROOT/evidence"

PRODUCT_REL="usr/lib/TweakInject/VCAMPro.dylib"
PRODUCT_PLIST_REL="usr/lib/TweakInject/VCAMPro.plist"
INSTALL_WITNESS_REL="usr/lib/TweakInject/VCAMProFullProductRealHookWitness.dylib"
INSTALL_WITNESS_PLIST_REL="usr/lib/TweakInject/VCAMProFullProductRealHookWitness.plist"
PHOTO_WITNESS_REL="usr/lib/TweakInject/VCAMProLocalPhotoPipelineReadyWitness.dylib"
PHOTO_WITNESS_PLIST_REL="usr/lib/TweakInject/VCAMProLocalPhotoPipelineReadyWitness.plist"

sh "$SCOPE/build_local_photo_pipeline_ready_input.sh"

mkdir -p "$EVIDENCE"
sh "$SCOPE/ci_static_validate.sh" | tee "$EVIDENCE/static-validation.txt"

test -f "$INPUT"
test "$(dpkg-deb -f "$INPUT" Package)" = "com.vcampro.camera"
test "$(dpkg-deb -f "$INPUT" Version)" = "0.1.0+roothide10~photoready1"
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
test "$(dpkg-deb -f "$FINAL" Version)" = "0.1.0+roothide10~photoready1"
test "$(dpkg-deb -f "$FINAL" Architecture)" = "iphoneos-arm64e"
test ! -e "$EXTRACT/var/jb"

for item in \
    "$PRODUCT_REL" \
    "$PRODUCT_PLIST_REL" \
    "$INSTALL_WITNESS_REL" \
    "$INSTALL_WITNESS_PLIST_REL" \
    "$PHOTO_WITNESS_REL" \
    "$PHOTO_WITNESS_PLIST_REL"; do
    test -f "$EXTRACT/$item"
done

data_files="$(find "$EXTRACT/usr/lib/TweakInject" -type f | sed "s#^$EXTRACT/##" | sort)"
expected_files="$(printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$PRODUCT_REL" \
    "$PRODUCT_PLIST_REL" \
    "$INSTALL_WITNESS_REL" \
    "$INSTALL_WITNESS_PLIST_REL" \
    "$PHOTO_WITNESS_REL" \
    "$PHOTO_WITNESS_PLIST_REL" | sort)"
test "$data_files" = "$expected_files"

python3 - <<'PY'
from pathlib import Path
import plistlib

root = Path("build/local-photo-pipeline-ready-pass-through-001/extracted-final")
tweak = root / "usr/lib/TweakInject"

with (tweak / "VCAMPro.plist").open("rb") as f:
    product = plistlib.load(f)
with (tweak / "VCAMProFullProductRealHookWitness.plist").open("rb") as f:
    install_witness = plistlib.load(f)
with (tweak / "VCAMProLocalPhotoPipelineReadyWitness.plist").open("rb") as f:
    photo_witness = plistlib.load(f)

if product != {"Filter": {"Executables": ["SpringBoard", "mediaserverd"]}}:
    raise SystemExit(product)
expected_witness = {"Filter": {"Executables": ["SpringBoard"]}}
if install_witness != expected_witness:
    raise SystemExit(install_witness)
if photo_witness != expected_witness:
    raise SystemExit(photo_witness)

expected_postinst = "#!/bin/sh\nset -e\n\nexit 0\n"
if (root / "DEBIAN/postinst").read_text() != expected_postinst:
    raise SystemExit("Unexpected maintainer script")

print("PHOTO_WITNESS_SPRINGBOARD_ONLY=PASS")
print("INSTALL_WITNESS_SPRINGBOARD_ONLY=PASS")
print("ROOTHIDE_PACKAGE=PASS")
print("PACKAGE_ID_CORRECT=PASS")
print("PACKAGE_VERSION_CORRECT=PASS")
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
PHOTO_WITNESS="$EXTRACT/$PHOTO_WITNESS_REL"

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
grep -Fq 'vcam::product::SharedControlStore' "$EVIDENCE/product-symbols.txt"
grep -Fq 'vcam::product::SharedMediaStager' "$EVIDENCE/product-symbols.txt"
grep -Fq 'vcam::product::ProductControlOwner' "$EVIDENCE/product-symbols.txt"
grep -Fq 'vcam::product::StartSpringBoardControlHost()' "$EVIDENCE/product-symbols.txt"
grep -Fq 'vcam::product::CameraConsumerAdapter' "$EVIDENCE/product-symbols.txt"
grep -Fq 'vcam::product::MediaserverdRuntime' "$EVIDENCE/product-symbols.txt"
grep -Fq 'vcam::product::InstallReferenceCameraHook()' "$EVIDENCE/product-symbols.txt"
grep -Fq 'HookedCMSampleBufferGetImageBuffer' "$EVIDENCE/product-symbols.txt"
grep -Fq 'gOriginalCMSampleBufferGetImageBuffer' "$EVIDENCE/product-symbols.txt"
grep -Fq 'vcam::product::proof::BeginLocalPhotoPipelineSelection' "$EVIDENCE/product-symbols.txt"
grep -Fq 'vcam::product::proof::ObserveLocalPhotoCallbackPhase' "$EVIDENCE/product-symbols.txt"
grep -Fq 'vcam::product::proof::ObserveLocalPhotoReadyPhase' "$EVIDENCE/product-symbols.txt"
grep -Fq 'vcam::product::proof::ResetLocalPhotoPipelineReadyProofState' "$EVIDENCE/product-symbols.txt"
grep -Fq '_OBJC_CLASS_$_VCAMInternalGalleryViewController' "$EVIDENCE/product-symbols.txt"
grep -Fxq '_MSHookFunction' "$EVIDENCE/product-undefined.txt"
grep -Fxq '_CMSampleBufferGetImageBuffer' "$EVIDENCE/product-undefined.txt"

for forbidden in \
    ReferenceCameraHookInstallationReadinessStub \
    ReferenceCameraHookReachabilityStub \
    ReferenceCameraHookRuntimeGateStub \
    MSHookFunctionStub \
    hookselftest \
    'dummy hook provider' \
    'synthetic callback provider'; do
    test -z "$(grep -Fi "$forbidden" "$EVIDENCE/product-symbols.txt" "$EVIDENCE/product-strings.txt" || true)"
done

for W in "$INSTALL_WITNESS" "$PHOTO_WITNESS"; do
    xcrun lipo -info "$W" | grep -q 'architecture: arm64'
    xcrun otool -l "$W" | grep -q 'minos 15.0'
done

xcrun otool -L "$INSTALL_WITNESS" > "$EVIDENCE/install-witness-linked-libraries.txt"
strings "$INSTALL_WITNESS" > "$EVIDENCE/install-witness-strings.txt"
grep -Fq 'VCAM REAL HOOK INSTALL PASS' "$EVIDENCE/install-witness-strings.txt"
test -z "$(grep -Ei 'AVFoundation|CoreMedia|CoreVideo|VideoToolbox|Photos|PhotosUI' "$EVIDENCE/install-witness-linked-libraries.txt" || true)"

xcrun otool -L "$PHOTO_WITNESS" > "$EVIDENCE/photo-witness-linked-libraries.txt"
strings "$PHOTO_WITNESS" > "$EVIDENCE/photo-witness-strings.txt"
for token in \
    'VCAM LOCAL PHOTO PIPELINE READY PASS' \
    'vcam-enabled=NO' \
    'media-kind=PHOTO' \
    'media-staged=YES' \
    'control-state-observed=YES' \
    'camera-geometry-observed=YES' \
    'producer-ready=YES' \
    'ready-frame-count=>0' \
    'camera-callback=EXERCISED' \
    'decision=ORIGINAL' \
    'original-buffer-returned=YES' \
    'frame-substitution=INACTIVE' \
    'virtual-decision-count=0'; do
    grep -Fq "$token" "$EVIDENCE/photo-witness-strings.txt"
done
test -z "$(grep -Ei 'AVFoundation|CoreMedia|CoreVideo|VideoToolbox|Photos|PhotosUI' "$EVIDENCE/photo-witness-linked-libraries.txt" || true)"

verify_signature "$PRODUCT" "$EVIDENCE/product-code-signature.txt"
verify_signature "$INSTALL_WITNESS" "$EVIDENCE/install-witness-code-signature.txt"
verify_signature "$PHOTO_WITNESS" "$EVIDENCE/photo-witness-code-signature.txt"

test "$(git hash-object src/product/ReferenceCameraHook.mm)" = "$HOOK_BLOB"
test "$(git hash-object src/product/CameraConsumerAdapter.cpp)" = "$ADAPTER_CPP_BLOB"
test "$(git hash-object src/product/CameraConsumerAdapter.h)" = "$ADAPTER_H_BLOB"

test "$(git ls-remote origin refs/heads/main | awk '{print $1}')" = "$MAIN"
heads="$(git ls-remote --heads origin | awk '{print $2}' | sort)"
expected_heads="$(printf '%s\n' refs/heads/builder/canonical-hook-continuation-001 refs/heads/main | sort)"
test "$heads" = "$expected_heads"

test "$(git ls-remote https://github.com/martaxi-boss/IOS-15-USB.git refs/heads/main | awk '{print $1}')" = "$IOS15"
test "$(git ls-remote https://github.com/martaxi-boss/MotionCam-iOS.git refs/heads/main | awk '{print $1}')" = "$MOTION"
test "$(git ls-remote https://github.com/martaxi-boss/IOS-16-USB-4k.git refs/heads/main | awk '{print $1}')" = "$IOS16"

{
    echo "TASK_ID=VCAM-PRO-LOCAL-PHOTO-PIPELINE-READY-PASS-THROUGH-001"
    echo "STARTING_HEAD=$START"
    echo "REFERENCE_CAMERA_HOOK_SOURCE_BLOB=$HOOK_BLOB"
    echo "CAMERA_CONSUMER_ADAPTER_CPP_BLOB=$ADAPTER_CPP_BLOB"
    echo "CAMERA_CONSUMER_ADAPTER_H_BLOB=$ADAPTER_H_BLOB"
    echo "ROOT_HIDE_PATCHER_SHA=$PATCHER_SHA"
    echo "FULL_PRODUCT_COMPONENTS_PRESENT=PASS"
    echo "REFERENCE_CAMERA_HOOK_SOURCE_UNCHANGED=PASS"
    echo "CAMERA_CONSUMER_ADAPTER_SOURCE_UNCHANGED=PASS"
    echo "READY_FRAME_QUEUE_SOURCE_UNCHANGED=PASS"
    echo "LOCAL_PHOTO_READER_SOURCE_UNCHANGED=PASS"
    echo "INTERNAL_GALLERY_SESSION_SOURCE_UNCHANGED=PASS"
    echo "SHARED_MEDIA_STAGER_SOURCE_UNCHANGED=PASS"
    echo "SHARED_CONTROL_STORE_SOURCE_UNCHANGED=PASS"
    echo "PRODUCT_CONTROL_OWNER_SOURCE_UNCHANGED=PASS"
    echo "PHOTO_PROOF_COMPILE_TIME_SCOPED=PASS"
    echo "SYNTHETIC_CALLBACK_TEST_ABSENT=PASS"
    echo "DIRECT_HOOK_INVOCATION_FROM_PROOF_ABSENT=PASS"
    echo "DIRECT_CAMERA_TARGET_INVOCATION_FROM_PROOF_ABSENT=PASS"
    echo "MEDIA_STAGING_PATH_PRESENT=PASS"
    echo "CONTROL_PROPAGATION_PATH_PRESENT=PASS"
    echo "PHOTO_READER_PATH_PRESENT=PASS"
    echo "FRAME_PIPELINE_PATH_PRESENT=PASS"
    echo "PRODUCER_WAKEUP_PATH_PRESENT=PASS"
    echo "READY_FRAME_QUEUE_PATH_PRESENT=PASS"
    echo "READY_FRAME_EXISTENCE_CHECK_NON_CONSUMING=PASS"
    echo "READY_QUEUE_ACQUIRE_FROM_PROOF_ABSENT=PASS"
    echo "VCAM_DISABLED_DURING_PROOF_REQUIRED=PASS"
    echo "PHOTO_MEDIA_KIND_REQUIRED=PASS"
    echo "CAMERA_GEOMETRY_REQUIRED=PASS"
    echo "PRODUCER_PLAYING_REQUIRED=PASS"
    echo "READY_FRAME_COUNT_GREATER_THAN_ZERO_REQUIRED=PASS"
    echo "CALLBACK_EXERCISED_REQUIRED=PASS"
    echo "ORIGINAL_DECISION_REQUIRED=PASS"
    echo "ORIGINAL_PIXEL_BUFFER_REQUIRED=PASS"
    echo "VIRTUAL_DECISION_COUNT_ZERO_REQUIRED=PASS"
    echo "FRAME_SUBSTITUTION_INACTIVE=PASS"
    echo "FAIL_OPEN_BEHAVIOR_PRESERVED=PASS"
    echo "BLACK_VCAM_PRODUCT_CONTROL_PRESENT=PASS"
    echo "PHOTO_WITNESS_PRESENT=PASS"
    echo "PHOTO_WITNESS_SPRINGBOARD_ONLY=PASS"
    echo "FRESH_PROOF_REQUIRED=PASS"
    echo "NONZERO_PID_REQUIRED=PASS"
    echo "ARM64=PASS"
    echo "MINIMUM_IOS_15=PASS"
    echo "ROOTHIDE_PACKAGE=PASS"
    echo "ROOT_HIDE_PATCHER_PINNED=PASS"
    echo "VALID_CODE_SIGNATURE=PASS"
    echo "PACKAGE_ID_CORRECT=PASS"
    echo "PACKAGE_VERSION_CORRECT=PASS"
    echo "MAIN_UNCHANGED=PASS"
    echo "READ_ONLY_REPOS_UNCHANGED=PASS"
    echo "DEVICE_ACTION=NO"
} | tee "$EVIDENCE/validation-report.txt"

cat "$FINAL.sha256"
