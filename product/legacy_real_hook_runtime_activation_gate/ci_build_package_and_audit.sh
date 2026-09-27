#!/bin/sh
set -eu

START=5295f9a3f7bf279ef5dd34f72c0bbc11a2b1ead5
ACCEPTED_BASE=2895d40391a344dd5325affa05bda2cb0b1612bf
PR19=2475bd51953b536c32d12e37475fd32eaf7c4a67
IOS15=a908bccbcddb4efc072bb1bc8fbeb6ee89b1af9d
MOTION=5ede3a1973a01cb13fe7f3ab562b47513feec1b1
IOS16=cc20d787070c67565173d4a46c218e2549cecc93
PATCHER_SHA=80c16e08da33fecd27c0ff35777f37afd171868b

HOOK_BLOB=b3b5360757d17951b0c508ab455d7ea4ffb0d6fe
RUNTIME_BLOB=37c613ab2c0746b34a86b74e20ce8814dee0a7da
ENTRY_BLOB=0003e5e7b8d2b6973cb8feae699bd25e545e2658

ROOT="$PWD/build/legacy-real-hook-runtime-activation-visible-witness-remediation-001"
GATE=product/legacy_real_hook_runtime_activation_gate
INPUT="$ROOT/input/com.vcampro.camera_0.1.0+roothide7~realhookruntime2_iphoneos-arm64.deb"
FINAL_DIR="$ROOT/final"
FINAL="$FINAL_DIR/VCAM-PRO-RootHide-Legacy-Real-Hook-Runtime-Activation-Visible-Witness-Gate-001.deb"
EXTRACT="$ROOT/extracted-final"
EVIDENCE="$ROOT/evidence"
DYLIB_REL="usr/lib/TweakInject/VCAMProRealHookRuntimeActivationGate.dylib"
PLIST_REL="usr/lib/TweakInject/VCAMProRealHookRuntimeActivationGate.plist"
WITNESS_REL="usr/lib/TweakInject/VCAMProRealHookRuntimeWitness.dylib"
WITNESS_PLIST_REL="usr/lib/TweakInject/VCAMProRealHookRuntimeWitness.plist"

test "$(git merge-base "$START" HEAD)" = "$START"
test "$(git merge-base "$ACCEPTED_BASE" "$START")" = "$ACCEPTED_BASE"

changed="$(git diff --name-only "$START"..HEAD)"
printf '%s\n' "$changed" | while IFS= read -r item; do
    test -n "$item" || continue
    case "$item" in
        product/legacy_real_hook_runtime_activation_gate/*|.github/workflows/legacy-real-hook-runtime-activation-gate-ci.yml)
            ;;
        *)
            echo "Unauthorized remediation mutation: $item"
            exit 1
            ;;
    esac
done

git diff --quiet "$START"..HEAD -- src
git diff --quiet "$START"..HEAD -- product/runtime_gate
git diff --quiet "$START"..HEAD -- product/hook_reachability_gate
git diff --quiet "$START"..HEAD -- product/hook_installation_readiness_gate
git diff --quiet "$START"..HEAD -- product/legacy_real_hook_linkage_gate
git diff --quiet "$START"..HEAD -- product/roothide_integration
git diff --quiet "$START"..HEAD -- product/VCAMPro.RootHideIntegration.plist

test "$(git hash-object src/product/ReferenceCameraHook.mm)" = "$HOOK_BLOB"
test "$(git hash-object src/product/MediaserverdRuntime.mm)" = "$RUNTIME_BLOB"
test "$(git hash-object src/product/VCAMProEntry.mm)" = "$ENTRY_BLOB"
test "$(git rev-parse "$ACCEPTED_BASE:src/product/ReferenceCameraHook.mm")" = "$HOOK_BLOB"
test "$(git rev-parse "$ACCEPTED_BASE:src/product/MediaserverdRuntime.mm")" = "$RUNTIME_BLOB"
test "$(git rev-parse "$ACCEPTED_BASE:src/product/VCAMProEntry.mm")" = "$ENTRY_BLOB"

python3 - <<'PY'
from pathlib import Path

hook = Path("src/product/ReferenceCameraHook.mm").read_text()
entry = Path("product/legacy_real_hook_runtime_activation_gate/RealHookRuntimeActivationGateEntry.mm").read_text()
header = Path("product/legacy_real_hook_runtime_activation_gate/RealHookRuntimeProofState.h").read_text()
witness = Path("product/legacy_real_hook_runtime_activation_gate/RealHookRuntimeWitness.mm").read_text()

required_call = """    MSHookFunction(
        reinterpret_cast<void*>(
            &CMSampleBufferGetImageBuffer),
        reinterpret_cast<void*>(
            &HookedCMSampleBufferGetImageBuffer),
        reinterpret_cast<void**>(
            &gOriginalCMSampleBufferGetImageBuffer));"""
required_return = """    return
        gOriginalCMSampleBufferGetImageBuffer !=
        nullptr;"""

if required_call not in hook:
    raise SystemExit("Frozen real hook tuple changed")
if required_return not in hook:
    raise SystemExit("Frozen real hook success predicate changed")

body = hook.split("bool InstallReferenceCameraHook() {", 1)[1]
body = body.split("\n}\n\n}  // namespace vcam::product", 1)[0]
if body.count("MSHookFunction(") != 1:
    raise SystemExit("Unexpected provider invocation count in frozen installer")
if body.count("return") != 1:
    raise SystemExit("Unexpected return count in frozen installer")

if "gOriginalCMSampleBufferGetImageBuffer" in entry:
    raise SystemExit("Gate entry must not expose original storage")
for required in (
    "MediaserverdRuntime::shared()",
    "runtime.start()",
    "InstallReferenceCameraHook()",
    "PublishRealHookInstallProof()",
):
    if required not in entry:
        raise SystemExit(f"Missing gate requirement: {required}")
if entry.count("InstallReferenceCameraHook()") != 1:
    raise SystemExit("Real hook installation must be attempted exactly once")
if entry.count("PublishRealHookInstallProof();") != 1:
    raise SystemExit("Proof publication must be attempted exactly once")
if entry.index("runtime.start()") > entry.index("InstallReferenceCameraHook()"):
    raise SystemExit("Production ordering violated")
if 'if (!runtimeStarted)' not in entry:
    raise SystemExit("Hook call is not gated on runtime.start success")
if 'if (!hookInstalled)' not in entry:
    raise SystemExit("Proof publication is not gated on hook success")
if entry.index("if (!hookInstalled)") > entry.index("PublishRealHookInstallProof();"):
    raise SystemExit("Proof publication can precede hook-success guard")
if entry.index("ResetProofState();") > entry.index("runtime.start()"):
    raise SystemExit("Proof state is not cleared before runtime attempt")

for forbidden in (
    "HookedCMSampleBufferGetImageBuffer(",
    "MSHookFunction(",
    "CMSampleBufferGetImageBuffer(",
):
    if forbidden in entry or forbidden in witness:
        raise SystemExit(f"Direct callback/provider invocation forbidden: {forbidden}")

required_header = (
    'VCAM_REAL_HOOK_RUNTIME_GATE_VERSION "0.1.0+roothide7~realhookruntime2"',
    '"com.vcampro.gate.real-hook-runtime-install.002"',
    "VCAM_REAL_HOOK_RUNTIME_GATE_FRESHNESS_SECONDS 180U",
    "VCAM_REAL_HOOK_RUNTIME_GATE_FUTURE_SKEW_SECONDS 5U",
    "VCAM_REAL_HOOK_RUNTIME_FLAG_RUNTIME_START_PASS",
    "VCAM_REAL_HOOK_RUNTIME_FLAG_REAL_HOOK_INSTALL_PASS",
    "VCAM_REAL_HOOK_RUNTIME_FLAG_ORIGINAL_TRAMPOLINE_NON_NULL",
    "VCAM_REAL_HOOK_RUNTIME_FLAG_CALLBACK_NOT_EXERCISED",
    "VCAM_REAL_HOOK_RUNTIME_FLAG_FRAME_SUBSTITUTION_INACTIVE",
)
for value in required_header:
    if value not in header:
        raise SystemExit(f"Missing proof-state contract: {value}")

required_banner = (
    "VCAM REAL HOOK INSTALL PASS",
    "runtime.start=PASS",
    "real-reference-hook-install=PASS",
    "original-trampoline=NON_NULL",
    "callback=NOT_EXERCISED",
    "frame-substitution=INACTIVE",
    "pid=%u",
    "gate/version=%s",
)
for value in required_banner:
    if value not in witness:
        raise SystemExit(f"Missing banner content: {value}")
if "vcam_real_hook_runtime_state_is_valid_fresh" not in witness:
    raise SystemExit("PASS banner is not gated on validated proof state")
if "ValidateTokenState(token);" not in witness:
    raise SystemExit("Immediate state validation after registration missing")
if "kVisibleDurationNanoseconds = 60 * NSEC_PER_SEC" not in witness:
    raise SystemExit("60-second visible duration missing")
if "kMaxPresentationAttempts = 60" not in witness:
    raise SystemExit("Bounded presentation retry missing")

print("REAL_HOOK_SUCCESS_PREDICATE_STATIC_INVARIANT=PASS")
print("PROOF_REQUIRES_RUNTIME_START=PASS")
print("PROOF_REQUIRES_REAL_HOOK_INSTALL=PASS")
print("PROOF_REQUIRES_ORIGINAL_TRAMPOLINE_NON_NULL=PASS")
print("PROOF_PUBLISHED_ONLY_AFTER_REAL_HOOK_SUCCESS=PASS")
print("PASS_BANNER_CONDITIONAL_ON_VALID_PROOF=PASS")
print("CALLBACK_DIRECT_INVOCATION_ABSENT=PASS")
print("SYNTHETIC_CALLBACK_TEST_ABSENT=PASS")
print("FRAME_SUBSTITUTION_TEST_ABSENT=PASS")
PY

python3 - <<'PY'
from pathlib import Path
needle = "com.vcampro.gate.real-hook-runtime-install.002"
matches = []
for path in Path("product").rglob("*"):
    if not path.is_file() or path.suffix not in {".h", ".mm", ".cpp", ".plist"}:
        continue
    try:
        body = path.read_text()
    except UnicodeDecodeError:
        continue
    if needle in body:
        matches.append(path.as_posix())
expected = ["product/legacy_real_hook_runtime_activation_gate/RealHookRuntimeProofState.h"]
if matches != expected:
    raise SystemExit(f"Notification identity not unique: {matches}")
print("PROOF_NOTIFICATION_IDENTITY_UNIQUE=PASS")
PY

test "$(git ls-remote origin refs/pull/19/head | awk '{print $1}')" = "$PR19"
test "$(git ls-remote https://github.com/martaxi-boss/IOS-15-USB.git refs/heads/main | awk '{print $1}')" = "$IOS15"
test "$(git ls-remote https://github.com/martaxi-boss/MotionCam-iOS.git refs/heads/main | awk '{print $1}')" = "$MOTION"
test "$(git ls-remote https://github.com/martaxi-boss/IOS-16-USB-4k.git refs/heads/main | awk '{print $1}')" = "$IOS16"

if grep -REn --exclude='ci_build_package_and_audit.sh' \
    'hookselftest|self[-_ ]?test|dummy[[:space:]_-]*hook|ReferenceCameraHook.*Stub|MSHookFunctionStub' "$GATE"; then
    echo "Synthetic hook architecture found in gate scope"
    exit 1
fi

sh "$GATE/build_runtime_activation_gate_input.sh"

mkdir -p "$EVIDENCE"
xcrun --sdk macosx clang++ -std=c++17 -Wall -Wextra -Werror -pedantic -I"$GATE" \
    "$GATE/real_hook_runtime_state_tests.cpp" \
    -o "$ROOT/real-hook-runtime-state-tests"
"$ROOT/real-hook-runtime-state-tests" | tee "$EVIDENCE/proof-state-tests.txt"

test -f "$INPUT"
test "$(dpkg-deb -f "$INPUT" Package)" = "com.vcampro.camera"
test "$(dpkg-deb -f "$INPUT" Version)" = "0.1.0+roothide7~realhookruntime2"
test "$(dpkg-deb -f "$INPUT" Architecture)" = "iphoneos-arm64"
dpkg-deb -c "$INPUT" > "$EVIDENCE/input-inventory.txt"

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
dpkg-deb -f "$FINAL" > "$EVIDENCE/final-control.txt"
dpkg-deb -c "$FINAL" > "$EVIDENCE/final-inventory.txt"

test "$(dpkg-deb -f "$FINAL" Package)" = "com.vcampro.camera"
test "$(dpkg-deb -f "$FINAL" Version)" = "0.1.0+roothide7~realhookruntime2"
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

root = Path("build/legacy-real-hook-runtime-activation-visible-witness-remediation-001/extracted-final")
tweak = root / "usr/lib/TweakInject"
with (tweak / "VCAMProRealHookRuntimeActivationGate.plist").open("rb") as f:
    activation = plistlib.load(f)
with (tweak / "VCAMProRealHookRuntimeWitness.plist").open("rb") as f:
    witness = plistlib.load(f)

if activation != {"Filter": {"Executables": ["mediaserverd"]}}:
    raise SystemExit(activation)
if witness != {"Filter": {"Executables": ["SpringBoard"]}}:
    raise SystemExit(witness)

expected_postinst = "#!/bin/sh\nset -e\n\nexit 0\n"
actual_postinst = (root / "DEBIAN/postinst").read_text()
if actual_postinst != expected_postinst:
    raise SystemExit("Maintainer script is not inert")

inventory = [
    p.relative_to(root).as_posix()
    for p in root.rglob("*")
    if p.is_file()
]
for forbidden in (
    "com.vcampro.control.plist",
    "selected-media",
    "SharedMedia",
    "Gallery",
    "WhatsApp",
    "FaceTime",
):
    if any(forbidden.lower() in p.lower() for p in inventory):
        raise SystemExit(f"Forbidden packaged payload: {forbidden}")

print("REAL_HOOK_DYLIB_FILTER_MEDIASERVERD_ONLY=PASS")
print("WITNESS_FILTER_SPRINGBOARD_ONLY=PASS")
print("INERT_MAINTAINER_SCRIPT=PASS")
print("NO_PACKAGED_CONTROL_PLIST=PASS")
print("NO_PACKAGED_SELECTED_MEDIA=PASS")
print("NO_CAMERA_WHATSAPP_FACETIME_FILTER=PASS")
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

xcrun lipo -info "$DYLIB" | tee "$EVIDENCE/dylib-arch.txt"
xcrun otool -l "$DYLIB" > "$EVIDENCE/dylib-load-commands.txt"
xcrun otool -D "$DYLIB" > "$EVIDENCE/dylib-install-name.txt"
xcrun otool -L "$DYLIB" > "$EVIDENCE/dylib-linked-libraries.txt"
xcrun nm -a "$DYLIB" | c++filt > "$EVIDENCE/dylib-symbols.txt" || true
xcrun nm -u "$DYLIB" > "$EVIDENCE/dylib-undefined.txt" || true
strings "$DYLIB" > "$EVIDENCE/dylib-strings.txt"
verify_signature "$DYLIB" "$EVIDENCE/dylib-code-signature.txt"

grep -q 'architecture: arm64' "$EVIDENCE/dylib-arch.txt"
test -z "$(grep 'arm64e' "$EVIDENCE/dylib-arch.txt" || true)"
grep -q 'minos 15.0' "$EVIDENCE/dylib-load-commands.txt"
grep -q '@loader_path/.jbroot/Library/Frameworks' "$EVIDENCE/dylib-load-commands.txt"
grep -q '@loader_path/.jbroot/usr/lib' "$EVIDENCE/dylib-load-commands.txt"
grep -q '@loader_path/VCAMProRealHookRuntimeActivationGate.dylib' "$EVIDENCE/dylib-install-name.txt"
grep -Fq 'vcam::product::InstallReferenceCameraHook()' "$EVIDENCE/dylib-symbols.txt"
grep -Fq 'HookedCMSampleBufferGetImageBuffer' "$EVIDENCE/dylib-symbols.txt"
grep -Fq 'gOriginalCMSampleBufferGetImageBuffer' "$EVIDENCE/dylib-symbols.txt"
grep -Fxq '_MSHookFunction' "$EVIDENCE/dylib-undefined.txt"
grep -Fxq '_CMSampleBufferGetImageBuffer' "$EVIDENCE/dylib-undefined.txt"
grep -Fq 'RUNTIME_START' "$EVIDENCE/dylib-strings.txt"
grep -Fq 'REAL_REFERENCE_HOOK_INSTALL' "$EVIDENCE/dylib-strings.txt"
grep -Fq 'ORIGINAL_TRAMPOLINE_NON_NULL' "$EVIDENCE/dylib-strings.txt"
test -z "$(grep -E 'ReferenceCameraHook.*Stub|hookselftest|MSHookFunctionStub' "$EVIDENCE/dylib-symbols.txt" "$EVIDENCE/dylib-strings.txt" || true)"
test -z "$(grep -E 'UIKit|PhotosUI' "$EVIDENCE/dylib-linked-libraries.txt" || true)"
test -z "$(grep -F 'path /var/jb/' "$EVIDENCE/dylib-load-commands.txt" || true)"

xcrun lipo -info "$WITNESS" | tee "$EVIDENCE/witness-arch.txt"
xcrun otool -l "$WITNESS" > "$EVIDENCE/witness-load-commands.txt"
xcrun otool -D "$WITNESS" > "$EVIDENCE/witness-install-name.txt"
xcrun otool -L "$WITNESS" > "$EVIDENCE/witness-linked-libraries.txt"
strings "$WITNESS" > "$EVIDENCE/witness-strings.txt"
verify_signature "$WITNESS" "$EVIDENCE/witness-code-signature.txt"

grep -q 'architecture: arm64' "$EVIDENCE/witness-arch.txt"
grep -q 'minos 15.0' "$EVIDENCE/witness-load-commands.txt"
grep -q '@loader_path/.jbroot/Library/Frameworks' "$EVIDENCE/witness-load-commands.txt"
grep -q '@loader_path/.jbroot/usr/lib' "$EVIDENCE/witness-load-commands.txt"
grep -q '@loader_path/VCAMProRealHookRuntimeWitness.dylib' "$EVIDENCE/witness-install-name.txt"
grep -Fq 'VCAM REAL HOOK INSTALL PASS' "$EVIDENCE/witness-strings.txt"
grep -Fq 'runtime.start=PASS' "$EVIDENCE/witness-strings.txt"
grep -Fq 'real-reference-hook-install=PASS' "$EVIDENCE/witness-strings.txt"
grep -Fq 'original-trampoline=NON_NULL' "$EVIDENCE/witness-strings.txt"
grep -Fq 'callback=NOT_EXERCISED' "$EVIDENCE/witness-strings.txt"
grep -Fq 'frame-substitution=INACTIVE' "$EVIDENCE/witness-strings.txt"
grep -Fq 'gate/version=%s' "$EVIDENCE/witness-strings.txt"
grep -Fq '0.1.0+roothide7~realhookruntime2' "$EVIDENCE/witness-strings.txt"
test -z "$(grep -Ei 'AVFoundation|CoreMedia|CoreVideo|VideoToolbox|Photos|PhotosUI' "$EVIDENCE/witness-linked-libraries.txt" || true)"
echo "WITNESS_CAMERA_FRAMEWORKS_ABSENT=PASS"

for marker in \
    PROOF_STATE_PID_REQUIRED=PASS \
    PROOF_STATE_FRESHNESS_ENFORCED=PASS \
    PROOF_STATE_FUTURE_SKEW_ENFORCED=PASS \
    STALE_PASS_REJECTED=PASS \
    INCOMPLETE_FLAGS_REJECTED=PASS \
    ZERO_PID_REJECTED=PASS; do
    grep -Fq "$marker" "$EVIDENCE/proof-state-tests.txt"
done

{
    echo "TASK_ID=VCAM-PRO-LEGACY-REAL-HOOK-RUNTIME-ACTIVATION-VISIBLE-WITNESS-REMEDIATION-001"
    echo "STARTING_HEAD=$START"
    echo "REFERENCE_CAMERA_HOOK_SOURCE_BLOB=$HOOK_BLOB"
    echo "MEDIASERVERD_RUNTIME_SOURCE_BLOB=$RUNTIME_BLOB"
    echo "VCAMPRO_ENTRY_SOURCE_BLOB=$ENTRY_BLOB"
    echo "ROOT_HIDE_PATCHER_SHA=$PATCHER_SHA"
    echo "REAL_HOOK_DYLIB_FILTER_MEDIASERVERD_ONLY=PASS"
    echo "WITNESS_FILTER_SPRINGBOARD_ONLY=PASS"
    echo "PROOF_NOTIFICATION_IDENTITY_UNIQUE=PASS"
    echo "PROOF_REQUIRES_RUNTIME_START=PASS"
    echo "PROOF_REQUIRES_REAL_HOOK_INSTALL=PASS"
    echo "PROOF_REQUIRES_ORIGINAL_TRAMPOLINE_NON_NULL=PASS"
    echo "PROOF_PUBLISHED_ONLY_AFTER_REAL_HOOK_SUCCESS=PASS"
    echo "REAL_HOOK_SUCCESS_PREDICATE_STATIC_INVARIANT=PASS"
    echo "PROOF_STATE_PID_REQUIRED=PASS"
    echo "PROOF_STATE_FRESHNESS_ENFORCED=PASS"
    echo "PROOF_STATE_FUTURE_SKEW_ENFORCED=PASS"
    echo "STALE_PASS_REJECTED=PASS"
    echo "INCOMPLETE_FLAGS_REJECTED=PASS"
    echo "ZERO_PID_REJECTED=PASS"
    echo "PASS_BANNER_CONDITIONAL_ON_VALID_PROOF=PASS"
    echo "CALLBACK_DIRECT_INVOCATION_ABSENT=PASS"
    echo "SYNTHETIC_CALLBACK_TEST_ABSENT=PASS"
    echo "FRAME_SUBSTITUTION_TEST_ABSENT=PASS"
    echo "WITNESS_CAMERA_FRAMEWORKS_ABSENT=PASS"
    echo "INERT_MAINTAINER_SCRIPT=PASS"
    echo "NO_PACKAGED_CONTROL_PLIST=PASS"
    echo "NO_PACKAGED_SELECTED_MEDIA=PASS"
    echo "NO_CAMERA_WHATSAPP_FACETIME_FILTER=PASS"
    echo "REFERENCE_CAMERA_HOOK_SOURCE_UNCHANGED=PASS"
    echo "MEDIASERVERD_RUNTIME_SOURCE_UNCHANGED=PASS"
    echo "VCAMPRO_ENTRY_SOURCE_UNCHANGED=PASS"
    echo "REAL_REFERENCE_HOOK_LINKED=PASS"
    echo "REAL_REPLACEMENT_SYMBOL_LINKED=PASS"
    echo "REAL_ORIGINAL_STORAGE_LINKED=PASS"
    echo "MSHOOKFUNCTION_REFERENCE_PRESENT=PASS"
    echo "CMSAMPLEBUFFER_TARGET_REFERENCE_PRESENT=PASS"
    echo "NO_HOOK_STUB_LINKED=PASS"
    echo "NO_SELFTEST_HOOK_PROVIDER_LINKED=PASS"
    echo "ARM64=PASS"
    echo "MINIMUM_IOS_15=PASS"
    echo "ROOTHIDE_RPATH_INSTALL_NAME=PASS"
    echo "VALID_CODE_SIGNATURE=PASS"
    echo "CODEDIRECTORY_SHA256=PASS"
    echo "CODEDIRECTORY_PAGE_HASHES=PASS"
    echo "PR19_MODIFIED=NO"
    echo "REFERENCE_REPOS_MODIFIED=NO"
    echo "MERGE_PERFORMED=NO"
    echo "RELEASE_PERFORMED=NO"
    echo "PRODUCTION_DEPLOY_PERFORMED=NO"
    echo "DEVICE_ACTION=NO"
} | tee "$EVIDENCE/validation-report.txt"

cat "$FINAL.sha256"
