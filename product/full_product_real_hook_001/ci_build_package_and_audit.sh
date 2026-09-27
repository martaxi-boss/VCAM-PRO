#!/bin/sh
set -eu

START=710ed97c9957d3564c838c5feba479a5b59affb1
MAIN=d476caacc4f557843f9551533c2fcbe7c5d40baa
IOS15=a908bccbcddb4efc072bb1bc8fbeb6ee89b1af9d
MOTION=5ede3a1973a01cb13fe7f3ab562b47513feec1b1
IOS16=cc20d787070c67565173d4a46c218e2549cecc93
PATCHER_SHA=80c16e08da33fecd27c0ff35777f37afd171868b
HOOK_BLOB=b3b5360757d17951b0c508ab455d7ea4ffb0d6fe

ROOT="$PWD/build/full-product-real-hook-001"
SCOPE=product/full_product_real_hook_001
INPUT="$ROOT/input/com.vcampro.camera_0.1.0+roothide8~fullrealhook1_iphoneos-arm64.deb"
FINAL_DIR="$ROOT/final"
FINAL="$FINAL_DIR/VCAM-PRO-RootHide-Full-Product-Real-Hook-001.deb"
EXTRACT="$ROOT/extracted-final"
EVIDENCE="$ROOT/evidence"
DYLIB_REL="usr/lib/TweakInject/VCAMPro.dylib"
PLIST_REL="usr/lib/TweakInject/VCAMPro.plist"
WITNESS_REL="usr/lib/TweakInject/VCAMProFullProductRealHookWitness.dylib"
WITNESS_PLIST_REL="usr/lib/TweakInject/VCAMProFullProductRealHookWitness.plist"

mkdir -p "$EVIDENCE"

test "$(git merge-base "$START" HEAD)" = "$START"

changed="$(git diff --name-only "$START"..HEAD)"
printf '%s\n' "$changed" | while IFS= read -r item; do
    test -n "$item" || continue
    case "$item" in
        product/full_product_real_hook_001/*|src/product/VCAMProEntry.mm|docs/CANONICAL_PROJECT_STATE.md|.github/workflows/full-product-real-hook-001-ci.yml)
            ;;
        *)
            echo "Unauthorized mutation: $item"
            exit 1
            ;;
    esac
done

src_changed="$(git diff --name-only "$START"..HEAD -- src)"
test "$src_changed" = "src/product/VCAMProEntry.mm"
test "$(git hash-object src/product/ReferenceCameraHook.mm)" = "$HOOK_BLOB"
git diff --quiet "$START"..HEAD -- src/product/ReferenceCameraHook.mm

test "$(git ls-remote origin refs/heads/main | awk '{print $1}')" = "$MAIN"
test "$(git ls-remote https://github.com/martaxi-boss/IOS-15-USB.git refs/heads/main | awk '{print $1}')" = "$IOS15"
test "$(git ls-remote https://github.com/martaxi-boss/MotionCam-iOS.git refs/heads/main | awk '{print $1}')" = "$MOTION"
test "$(git ls-remote https://github.com/martaxi-boss/IOS-16-USB-4k.git refs/heads/main | awk '{print $1}')" = "$IOS16"

python3 - <<'PY'
from pathlib import Path

scope = Path("product/full_product_real_hook_001")
build = (scope / "build_full_product_real_hook_input.sh").read_text()
entry = Path("src/product/VCAMProEntry.mm").read_text()
hook = Path("src/product/ReferenceCameraHook.mm").read_text()
adapter = Path("src/product/CameraConsumerAdapter.cpp").read_text()
state = Path("src/product/ProductControlState.h").read_text()
host = Path("src/product/SpringBoardControlHost.mm").read_text()
gallery = Path("src/control/InternalGalleryViewController.mm").read_text()
proof = (scope / "FullProductRealHookProof.mm").read_text()
proof_state = (scope / "FullProductRealHookProofState.h").read_text()
witness = (scope / "FullProductRealHookWitness.mm").read_text()

required_sources = (
    "LocalVideoReader.mm",
    "LocalPhotoReader.mm",
    "PreparedFrame.cpp",
    "FrameEngineState.cpp",
    "ReadyFrameQueue.cpp",
    "FrameTimelineScheduler.cpp",
    "MonotonicHostClock.cpp",
    "FrameNormalizer.cpp",
    "FrameTransformer.mm",
    "FramePipelinePump.cpp",
    "FramePipelinePumpTimed.cpp",
    "ProducerWakeupController.cpp",
    "ProducerWakeupDriver.mm",
    "InternalGalleryMediaSession.mm",
    "InternalGalleryViewController.mm",
    "ControlStateCache.cpp",
    "CameraConsumerAdapter.cpp",
    "SharedControlStore.mm",
    "SharedMediaStager.mm",
    "ProductControlOwner.mm",
    "SpringBoardControlHost.mm",
    "MediaserverdRuntime.mm",
    "ReferenceCameraHook.mm",
    "VCAMProEntry.mm",
    "FullProductRealHookProof.mm",
)
for token in required_sources:
    if token not in build:
        raise SystemExit(f"Missing full-product source: {token}")

for forbidden in (
    "ReferenceCameraHookInstallationReadinessStub.mm",
    "ReferenceCameraHookReachabilityStub.mm",
    "ReferenceCameraHookRuntimeGateStub.mm",
    "MSHookFunctionStub",
):
    if forbidden in build:
        raise SystemExit(f"Forbidden build input: {forbidden}")

if entry.count("InstallReferenceCameraHook()") != 1:
    raise SystemExit("Real hook install attempt count is not exactly one")
for token in (
    "ResetFullProductRealHookProofState()",
    "runtime.start()",
    "InstallReferenceCameraHook()",
    "PublishFullProductRealHookInstallProof()",
    "StartSpringBoardControlHost()",
):
    if token not in entry:
        raise SystemExit(f"Missing startup token: {token}")
if entry.index("ResetFullProductRealHookProofState()") > entry.index("runtime.start()"):
    raise SystemExit("Proof state is not cleared before runtime attempt")
if entry.index("runtime.start()") > entry.index("InstallReferenceCameraHook()"):
    raise SystemExit("Hook install precedes runtime start")
if entry.index("if (hookInstalled)") > entry.index("PublishFullProductRealHookInstallProof()"):
    raise SystemExit("Proof publish is not gated on hook success")

required_hook = (
    "CMSampleBufferGetImageBuffer",
    "HookedCMSampleBufferGetImageBuffer",
    "MSHookFunction",
    "gOriginalCMSampleBufferGetImageBuffer",
    "observeRealCameraBuffer",
    "decideCameraBuffer",
)
for token in required_hook:
    if token not in hook:
        raise SystemExit(f"Frozen real-hook token missing: {token}")

if 'bool enabled = false;' not in state:
    raise SystemExit("VCAM is not disabled by default")
if "decision.pixelBuffer = original;" not in adapter:
    raise SystemExit("Camera adapter fail-open original assignment missing")

for token in (
    "StartSpringBoardControlHost",
    "ProductControlOwner",
    "VCAMInternalGalleryViewController",
    "colorWithWhite:0.1",
):
    if token not in host:
        raise SystemExit(f"Black Product Control token missing: {token}")

for token in (
    "Select Media",
    "Change",
    "Clear",
    "Play",
    "Pause",
    "Resume",
    "Loop",
    "VCAM ON",
):
    if token not in gallery:
        raise SystemExit(f"Product Control action missing: {token}")

if '"com.vcampro.gate.full-product-real-hook.001"' not in proof_state:
    raise SystemExit("Full-product proof identity missing")
if proof_state.count("com.vcampro.gate.full-product-real-hook.001") != 1:
    raise SystemExit("Full-product proof identity duplicated")

for token in (
    "notify_set_state",
    "notify_post",
    "runtime.start=PASS",
    "real-reference-hook-install=PASS",
    "original-trampoline=NON_NULL",
    "callback=NOT_EXERCISED",
    "frame-substitution=INACTIVE",
):
    if token not in proof:
        raise SystemExit(f"Proof publisher token missing: {token}")

for token in (
    "VCAM REAL HOOK INSTALL PASS",
    "runtime.start=PASS",
    "real-reference-hook-install=PASS",
    "original-trampoline=NON_NULL",
    "callback=NOT_EXERCISED",
    "frame-substitution=INACTIVE",
    "vcam_full_product_real_hook_state_is_valid_fresh",
):
    if token not in witness:
        raise SystemExit(f"Visible witness token missing: {token}")

for forbidden in (
    "HookedCMSampleBufferGetImageBuffer(",
    "CMSampleBufferGetImageBuffer(",
    "MSHookFunction(",
):
    if forbidden in proof or forbidden in witness:
        raise SystemExit(f"Synthetic callback/provider invocation found: {forbidden}")

print("FULL_PRODUCT_COMPONENTS_PRESENT=PASS")
print("LOCAL_VIDEO_READER_PRESENT=PASS")
print("LOCAL_PHOTO_READER_PRESENT=PASS")
print("FRAME_ENGINE_A_F2_PRESENT=PASS")
print("INTERNAL_GALLERY_PRESENT=PASS")
print("SHARED_CONTROL_STORE_PRESENT=PASS")
print("SHARED_MEDIA_STAGER_PRESENT=PASS")
print("REAL_HOOK_INSTALL_ATTEMPT_COUNT=ONE")
print("SYNTHETIC_CALLBACK_TEST_ABSENT=PASS")
print("FRAME_SUBSTITUTION_INACTIVE_BY_DEFAULT=PASS")
print("FAIL_OPEN_BEHAVIOR_PRESERVED=PASS")
print("BLACK_VCAM_PRODUCT_CONTROL_PRESENT=PASS")
PY

sh "$SCOPE/build_full_product_real_hook_input.sh"

mkdir -p "$EVIDENCE"

test -f "$INPUT"
test "$(dpkg-deb -f "$INPUT" Package)" = "com.vcampro.camera"
test "$(dpkg-deb -f "$INPUT" Version)" = "0.1.0+roothide8~fullrealhook1"
test "$(dpkg-deb -f "$INPUT" Architecture)" = "iphoneos-arm64"

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
test "$(dpkg-deb -f "$FINAL" Version)" = "0.1.0+roothide8~fullrealhook1"
test "$(dpkg-deb -f "$FINAL" Architecture)" = "iphoneos-arm64e"
test ! -e "$EXTRACT/var/jb"

for item in "$DYLIB_REL" "$PLIST_REL" "$WITNESS_REL" "$WITNESS_PLIST_REL"; do
    test -f "$EXTRACT/$item"
done

data_files="$(find "$EXTRACT/usr/lib/TweakInject" -type f | sed "s#^$EXTRACT/##" | sort)"
expected_files="$(printf '%s\n%s\n%s\n%s\n' "$DYLIB_REL" "$PLIST_REL" "$WITNESS_REL" "$WITNESS_PLIST_REL" | sort)"
test "$data_files" = "$expected_files"

python3 - <<'PY'
from pathlib import Path
import plistlib

root = Path("build/full-product-real-hook-001/extracted-final")
tweak = root / "usr/lib/TweakInject"

with (tweak / "VCAMPro.plist").open("rb") as f:
    product = plistlib.load(f)
with (tweak / "VCAMProFullProductRealHookWitness.plist").open("rb") as f:
    witness = plistlib.load(f)

if product != {"Filter": {"Executables": ["SpringBoard", "mediaserverd"]}}:
    raise SystemExit(product)
if witness != {"Filter": {"Executables": ["SpringBoard"]}}:
    raise SystemExit(witness)

expected_postinst = "#!/bin/sh\nset -e\n\nexit 0\n"
if (root / "DEBIAN/postinst").read_text() != expected_postinst:
    raise SystemExit("Unexpected maintainer script")

print("VISIBLE_WITNESS_SPRINGBOARD_ONLY=PASS")
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

magic, total_len, count = struct.unpack_from(">III", data, sig_off)
if magic != CSMAGIC_EMBEDDED_SIGNATURE:
    raise SystemExit(f"Unexpected signature superblob magic: 0x{magic:08x}")
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

DYLIB="$EXTRACT/$DYLIB_REL"
WITNESS="$EXTRACT/$WITNESS_REL"

xcrun lipo -info "$DYLIB" | tee "$EVIDENCE/product-arch.txt"
xcrun otool -l "$DYLIB" > "$EVIDENCE/product-load-commands.txt"
xcrun otool -L "$DYLIB" > "$EVIDENCE/product-linked-libraries.txt"
xcrun nm -a "$DYLIB" | c++filt > "$EVIDENCE/product-symbols.txt" || true
xcrun nm -u "$DYLIB" > "$EVIDENCE/product-undefined.txt" || true
strings "$DYLIB" > "$EVIDENCE/product-strings.txt"

grep -q 'architecture: arm64' "$EVIDENCE/product-arch.txt"
test -z "$(grep 'arm64e' "$EVIDENCE/product-arch.txt" || true)"
grep -q 'minos 15.0' "$EVIDENCE/product-load-commands.txt"
grep -Fq 'vcam::product::ProductControlOwner' "$EVIDENCE/product-symbols.txt"
grep -Fq 'vcam::product::StartSpringBoardControlHost()' "$EVIDENCE/product-symbols.txt"
grep -Fq 'vcam::product::SharedMediaStager' "$EVIDENCE/product-symbols.txt"
grep -Fq 'vcam::product::CameraConsumerAdapter' "$EVIDENCE/product-symbols.txt"
grep -Fq 'vcam::product::MediaserverdRuntime' "$EVIDENCE/product-symbols.txt"
grep -Fq 'VCAMProInitialize' "$EVIDENCE/product-symbols.txt"
grep -Fq 'vcam::product::InstallReferenceCameraHook()' "$EVIDENCE/product-symbols.txt"
grep -Fq 'HookedCMSampleBufferGetImageBuffer' "$EVIDENCE/product-symbols.txt"
grep -Fq 'gOriginalCMSampleBufferGetImageBuffer' "$EVIDENCE/product-symbols.txt"
grep -Fq '_OBJC_CLASS_$_VCAMInternalGalleryViewController' "$EVIDENCE/product-symbols.txt"
grep -Fxq '_MSHookFunction' "$EVIDENCE/product-undefined.txt"
grep -Fxq '_CMSampleBufferGetImageBuffer' "$EVIDENCE/product-undefined.txt"

for forbidden in     ReferenceCameraHookInstallationReadinessStub     ReferenceCameraHookReachabilityStub     ReferenceCameraHookRuntimeGateStub     MSHookFunctionStub     hookselftest     'dummy hook provider'; do
    test -z "$(grep -Fi "$forbidden" "$EVIDENCE/product-symbols.txt" "$EVIDENCE/product-strings.txt" || true)"
done

xcrun lipo -info "$WITNESS" | tee "$EVIDENCE/witness-arch.txt"
xcrun otool -l "$WITNESS" > "$EVIDENCE/witness-load-commands.txt"
xcrun otool -L "$WITNESS" > "$EVIDENCE/witness-linked-libraries.txt"
strings "$WITNESS" > "$EVIDENCE/witness-strings.txt"

grep -q 'architecture: arm64' "$EVIDENCE/witness-arch.txt"
grep -q 'minos 15.0' "$EVIDENCE/witness-load-commands.txt"
grep -Fq 'VCAM REAL HOOK INSTALL PASS' "$EVIDENCE/witness-strings.txt"
grep -Fq 'runtime.start=PASS' "$EVIDENCE/witness-strings.txt"
grep -Fq 'real-reference-hook-install=PASS' "$EVIDENCE/witness-strings.txt"
grep -Fq 'original-trampoline=NON_NULL' "$EVIDENCE/witness-strings.txt"
grep -Fq 'callback=NOT_EXERCISED' "$EVIDENCE/witness-strings.txt"
grep -Fq 'frame-substitution=INACTIVE' "$EVIDENCE/witness-strings.txt"
test -z "$(grep -Ei 'AVFoundation|CoreMedia|CoreVideo|VideoToolbox|Photos|PhotosUI' "$EVIDENCE/witness-linked-libraries.txt" || true)"

verify_signature "$DYLIB" "$EVIDENCE/product-code-signature.txt"
verify_signature "$WITNESS" "$EVIDENCE/witness-code-signature.txt"

{
    echo "TASK_ID=VCAM-PRO-FULL-PRODUCT-REAL-HOOK-001-REMEDIATION-A"
    echo "STARTING_HEAD=$START"
    echo "REFERENCE_CAMERA_HOOK_SOURCE_BLOB=$HOOK_BLOB"
    echo "ROOT_HIDE_PATCHER_SHA=$PATCHER_SHA"
    echo "FULL_PRODUCT_COMPONENTS_PRESENT=PASS"
    echo "LOCAL_VIDEO_READER_PRESENT=PASS"
    echo "LOCAL_PHOTO_READER_PRESENT=PASS"
    echo "FRAME_ENGINE_A_F2_PRESENT=PASS"
    echo "INTERNAL_GALLERY_PRESENT=PASS"
    echo "SHARED_CONTROL_STORE_PRESENT=PASS"
    echo "SHARED_MEDIA_STAGER_PRESENT=PASS"
    echo "PRODUCT_CONTROL_OWNER_LINKED=PASS"
    echo "SPRINGBOARD_CONTROL_HOST_LINKED=PASS"
    echo "CAMERA_CONSUMER_ADAPTER_LINKED=PASS"
    echo "MEDIASERVERD_RUNTIME_LINKED=PASS"
    echo "VCAMPRO_ENTRY_LINKED=PASS"
    echo "REAL_REFERENCE_HOOK_LINKED=PASS"
    echo "READINESS_STUB_ABSENT=PASS"
    echo "HOOK_REACHABILITY_STUB_ABSENT=PASS"
    echo "RUNTIME_GATE_STUB_ABSENT=PASS"
    echo "MSHOOKFUNCTION_REFERENCE_PRESENT=PASS"
    echo "CMSAMPLEBUFFER_TARGET_REFERENCE_PRESENT=PASS"
    echo "REAL_REPLACEMENT_SYMBOL_PRESENT=PASS"
    echo "ORIGINAL_TRAMPOLINE_STORAGE_PRESENT=PASS"
    echo "VISIBLE_WITNESS_PRESENT=PASS"
    echo "VISIBLE_WITNESS_SPRINGBOARD_ONLY=PASS"
    echo "REAL_HOOK_INSTALL_ATTEMPT_COUNT=ONE"
    echo "SYNTHETIC_CALLBACK_TEST_ABSENT=PASS"
    echo "FRAME_SUBSTITUTION_INACTIVE_BY_DEFAULT=PASS"
    echo "FAIL_OPEN_BEHAVIOR_PRESERVED=PASS"
    echo "BLACK_VCAM_PRODUCT_CONTROL_PRESENT=PASS"
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
