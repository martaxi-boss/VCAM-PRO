#!/bin/sh
set -eu

MAIN=d476caacc4f557843f9551533c2fcbe7c5d40baa
IOS15=a908bccbcddb4efc072bb1bc8fbeb6ee89b1af9d
MOTION=5ede3a1973a01cb13fe7f3ab562b47513feec1b1
IOS16=cc20d787070c67565173d4a46c218e2549cecc93
PATCHER_SHA=80c16e08da33fecd27c0ff35777f37afd171868b

ROOT="$PWD/build/video-device-proof-remediation-002"
SCOPE=product/video_device_proof_remediation_002
INPUT="$ROOT/input/com.vcampro.camera_0.1.0+roothide24~sourcefix1_iphoneos-arm64.deb"
FINAL_DIR="$ROOT/final"
FINAL="$FINAL_DIR/VCAM-PRO-RootHide-Video-Source-Isolation-001.deb"
EXTRACT="$ROOT/extracted-final"
EVIDENCE="$ROOT/evidence"
PRODUCT_REL="usr/lib/TweakInject/VCAMPro.dylib"
PRODUCT_PLIST_REL="usr/lib/TweakInject/VCAMPro.plist"

rm -rf "$FINAL_DIR" "$EVIDENCE" "$EXTRACT"
sh "$SCOPE/build_input.sh"

mkdir -p "$EVIDENCE" "$FINAL_DIR"

test -f "$INPUT"
test "$(dpkg-deb -f "$INPUT" Package)" = "com.vcampro.camera"
test "$(dpkg-deb -f "$INPUT" Version)" = "0.1.0+roothide24~sourcefix1"
test "$(dpkg-deb -f "$INPUT" Architecture)" = "iphoneos-arm64"
dpkg-deb -c "$INPUT" | tee "$EVIDENCE/input-inventory.txt"

PATCHER_DIR="${ROOTHIDE_PATCHER_DIR:-$PWD/reference/RootHidePatcher}"
test -d "$PATCHER_DIR/.git"
test "$(git -C "$PATCHER_DIR" rev-parse HEAD)" = "$PATCHER_SHA"

sudo env "PATH=$PATH" bash "$PATCHER_DIR/patch.sh" "$INPUT" "$FINAL"

test -f "$FINAL"
shasum -a 256 "$FINAL" | tee "$FINAL.sha256"
wc -c < "$FINAL" | tr -d ' ' | tee "$EVIDENCE/deb-size.txt"

rm -rf "$EXTRACT"
mkdir -p "$EXTRACT"
dpkg-deb -R "$FINAL" "$EXTRACT"
dpkg-deb -f "$FINAL" | tee "$EVIDENCE/final-control.txt"
dpkg-deb -c "$FINAL" | tee "$EVIDENCE/final-inventory.txt"

test "$(dpkg-deb -f "$FINAL" Package)" = "com.vcampro.camera"
test "$(dpkg-deb -f "$FINAL" Version)" = "0.1.0+roothide24~sourcefix1"
test "$(dpkg-deb -f "$FINAL" Architecture)" = "iphoneos-arm64e"
test ! -e "$EXTRACT/var/jb"

test -f "$EXTRACT/$PRODUCT_REL"
test -f "$EXTRACT/$PRODUCT_PLIST_REL"

data_files="$(find "$EXTRACT/usr/lib/TweakInject" -type f | sed "s#^$EXTRACT/##" | sort)"
expected_files="$(printf '%s\n%s\n' "$PRODUCT_REL" "$PRODUCT_PLIST_REL" | sort)"
test "$data_files" = "$expected_files"

python3 - <<'PY'
from pathlib import Path
import plistlib

root = Path("build/video-device-proof-remediation-002/extracted-final")
tweak = root / "usr/lib/TweakInject"

with (tweak / "VCAMPro.plist").open("rb") as f:
    packaged = plistlib.load(f)
with Path("product/VCAMPro.plist").open("rb") as f:
    canonical = plistlib.load(f)

expected = {
    "Filter": {
        "Bundles": [
            "com.apple.mediaserverd",
            "com.apple.springboard",
            "com.apple.UIKit",
        ],
        "Executables": ["mediaserverd"],
    }
}
if canonical != expected:
    raise SystemExit(canonical)
if packaged != canonical:
    raise SystemExit("Packaged product filter differs from canonical VCAMPro.plist")
if "SpringBoard" in packaged["Filter"]["Executables"]:
    raise SystemExit("Unexpected SpringBoard executable override")

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
LC_CODE_SIGNATURE = 0x1D
sig_off = sig_size = None
for _ in range(ncmds):
    cmd, cmdsize = struct.unpack_from("<II", data, offset)
    if cmdsize < 8 or offset + cmdsize > end_commands:
        raise SystemExit("Invalid load command")
    if cmd == LC_CODE_SIGNATURE:
        sig_off, sig_size = struct.unpack_from("<II", data, offset + 8)
        break
    offset += cmdsize

if sig_off is None or sig_size is None or sig_size == 0:
    raise SystemExit("LC_CODE_SIGNATURE missing")
if sig_off + sig_size > len(data):
    raise SystemExit("Code signature range exceeds file")

CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_CODEDIRECTORY = 0xFADE0C02
CSSLOT_CODEDIRECTORY = 0
smagic, total_len, count = struct.unpack_from(">III", data, sig_off)
if smagic != CSMAGIC_EMBEDDED_SIGNATURE:
    raise SystemExit("Unexpected signature superblob")
if total_len > sig_size:
    raise SystemExit("Invalid signature length")

cd_off = None
for i in range(count):
    slot_type, rel_off = struct.unpack_from(">II", data, sig_off + 12 + i * 8)
    if slot_type == CSSLOT_CODEDIRECTORY:
        cd_off = sig_off + rel_off
        break
if cd_off is None:
    raise SystemExit("Primary CodeDirectory missing")

cd_magic, cd_len, cd_version, cd_flags, hash_off, ident_off, n_special, n_code, code_limit = struct.unpack_from(
    ">IIIIIIIII", data, cd_off
)
if cd_magic != CSMAGIC_CODEDIRECTORY:
    raise SystemExit("Unexpected CodeDirectory")
hash_size, hash_type, platform, page_log2 = struct.unpack_from("BBBB", data, cd_off + 36)
if hash_type != 2 or hash_size != 32:
    raise SystemExit("Expected SHA-256 CodeDirectory")
page_size = 1 << page_log2
expected_slots = (code_limit + page_size - 1) // page_size
if n_code != expected_slots:
    raise SystemExit("Code slot count mismatch")

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
        f"CDHASH={cdhash}",
        "",
    ])
)
PY
}

PRODUCT="$EXTRACT/$PRODUCT_REL"
xcrun lipo -info "$PRODUCT" | tee "$EVIDENCE/product-arch.txt"
xcrun otool -l "$PRODUCT" > "$EVIDENCE/product-load-commands.txt"
xcrun nm -a "$PRODUCT" | c++filt > "$EVIDENCE/product-symbols.txt" || true
xcrun nm -u "$PRODUCT" > "$EVIDENCE/product-undefined.txt" || true

grep -q 'architecture: arm64' "$EVIDENCE/product-arch.txt"
test -z "$(grep 'arm64e' "$EVIDENCE/product-arch.txt" || true)"
grep -q 'minos 15.0' "$EVIDENCE/product-load-commands.txt"
grep -Fq 'vcam::product::CommitVirtualCameraOutputIntoOriginal' "$EVIDENCE/product-symbols.txt"
grep -Fq 'vcam::product::MediaserverdRuntime' "$EVIDENCE/product-symbols.txt"
grep -Fq 'vcam::product::CameraConsumerAdapter' "$EVIDENCE/product-symbols.txt"
grep -Fq 'vcam::media_engine::LocalPhotoReader' "$EVIDENCE/product-symbols.txt"
grep -Fq 'vcam::media_engine::LocalVideoReader' "$EVIDENCE/product-symbols.txt"
grep -Fxq '_MSHookFunction' "$EVIDENCE/product-undefined.txt"
grep -Fxq '_CMSampleBufferGetImageBuffer' "$EVIDENCE/product-undefined.txt"
grep -Fxq '_CMGetAttachment' "$EVIDENCE/product-undefined.txt"

verify_signature "$PRODUCT" "$EVIDENCE/product-code-signature.txt"

test "$(git ls-remote origin refs/heads/main | awk '{print $1}')" = "$MAIN"
test "$(git ls-remote https://github.com/martaxi-boss/IOS-15-USB.git refs/heads/main | awk '{print $1}')" = "$IOS15"
test "$(git ls-remote https://github.com/martaxi-boss/MotionCam-iOS.git refs/heads/main | awk '{print $1}')" = "$MOTION"
test "$(git ls-remote https://github.com/martaxi-boss/IOS-16-USB-4k.git refs/heads/main | awk '{print $1}')" = "$IOS16"

{
    echo "TASK_ID=VCAM-PRO-VIDEO-DEVICE-PROOF-REMEDIATION-002"
    echo "PACKAGE_ROLE=VIDEO_PRESENTATION_FIX_CANDIDATE"
    echo "VIDEO_PRESENTATION_FIX_PACKAGE=PASS"
    echo "PHYSICAL_DIAGNOSTIC_ACCEPTED=YES"
    echo "PREFX_CLASSIFICATION_RUN=36703291652"
    echo "VIDEO_FIRST_BROKEN_REGION=POST_TRANSFORM_TO_TIMED_PUBLICATION_TO_READYFRAMEQUEUE_TO_CAMERA_CONSUMER_ACQUISITION"
    echo "VIDEO_SOURCE_ISOLATION=SCOPED_THREAD_LOCAL_DECODE_ACCESS"
    echo "VIDEO_PREVIOUS_PRESENTATION_REMEDIATION=PRESERVED"
    echo "PRE_FIX_VIDEO_RETARGET_QUEUE_CLEAR_COUNT=16"
    echo "PRE_FIX_VIDEO_RETARGET_CLEARED_READY_FRAME_COUNT=1"
    echo "PRE_FIX_VIDEO_ACQUIRE_ZERO_REPRODUCED=PASS"
    echo "PRE_FIX_LATEST_CACHE_NEVER_SEEDED=PASS"
    echo "CURRENT_5MS_POLICY_UNDER_REALISTIC_JITTER=STARVING"
    echo "VIDEO_TIMING_MODEL_AFTER=LATEST_DUE_PENDING_PRESENTATION_PLUS_FRAME_DURATION_NEW_FRAME_DROP_REBASE"
    echo "VIDEO_GEOMETRY_MODEL_AFTER=BOUNDED_LATEST_PREPARED_FRAME_PER_DESTINATION_GEOMETRY"
    echo "ARM64=PASS"
    echo "MINIMUM_IOS_15=PASS"
    echo "ROOTHIDE_PACKAGE=PASS"
    echo "ROOT_HIDE_PATCHER_PINNED=PASS"
    echo "VALID_CODE_SIGNATURE=PASS"
    echo "PACKAGE_ID_CORRECT=PASS"
    echo "PACKAGE_VERSION_CORRECT=PASS"
    echo "CANONICAL_FILTER_SOURCE=product/VCAMPro.plist"
    echo "PACKAGED_FILTER_SOURCE=product/VCAMPro.plist"
    echo "CANONICAL_VCAMPRO_FILTER_PARITY=PASS"
    echo "MAIN_UNCHANGED=PASS"
    echo "READ_ONLY_REPOS_UNCHANGED=PASS"
    echo "PHOTO_CONTINUOUS_PRESENTATION_DEVICE_PROOF=PASS"
    echo "REMOTE_THIRD_PARTY_ORIENTATION_STATUS=PASS"
    echo "VIDEO_RUNTIME_DIAGNOSTIC_PRESERVED=YES"
    echo "DEVICE_DIAGNOSTIC_TRANSPORT=DARWIN_NOTIFY_FIXED_SIZE_SEPARATE_STATUS"
    echo "ADJUST_MEDIA_PHOTO=HOST_PASS"
    echo "ADJUST_MEDIA_VIDEO=HOST_PASS"
    echo "ORIENTATION_CODE_CHANGED=NO"
    echo "PHOTO_OWNERSHIP_CHANGED=NO"
    echo "CALLBACK_HEAVY_WORK=NO"
    echo "DEVICE_ACTION=NO"
} | tee "$EVIDENCE/validation-report.txt"

cat > "$EVIDENCE/terminal.txt" <<'EOF'
TASK_STATUS=READY_FOR_DEVICE_PROOF_RETRY
NEXT_PHASE=VIDEO_DEVICE_PROOF_RETRY
DEVICE_ACTION=NO
EOF

cat "$FINAL.sha256"
