#!/usr/bin/env python3

import hashlib
import struct
import sys
from pathlib import Path

if len(sys.argv) != 3:
    raise SystemExit("usage: verify_macho_signature.py DYLIB EVIDENCE")

path = Path(sys.argv[1])
evidence = Path(sys.argv[2])
data = path.read_bytes()

if len(data) < 32:
    raise SystemExit("Mach-O too small")

magic, = struct.unpack_from("<I", data, 0)
if magic != 0xFEEDFACF:
    raise SystemExit(f"Unexpected Mach-O magic: 0x{magic:08x}")

_, _, _, _, ncmds, sizeofcmds, _, _ = struct.unpack_from(
    "<IiiIIIII", data, 0
)
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

super_magic, total_len, count = struct.unpack_from(">III", data, sig_off)
if super_magic != CSMAGIC_EMBEDDED_SIGNATURE:
    raise SystemExit(
        f"Unexpected signature superblob magic: 0x{super_magic:08x}"
    )
if total_len > sig_size or total_len < 12 + count * 8:
    raise SystemExit("Invalid signature superblob length")

cd_off = None
for i in range(count):
    slot_type, rel_off = struct.unpack_from(
        ">II", data, sig_off + 12 + i * 8
    )
    if rel_off >= total_len:
        raise SystemExit("Signature blob offset out of range")
    if slot_type == CSSLOT_CODEDIRECTORY:
        cd_off = sig_off + rel_off
        break

if cd_off is None:
    raise SystemExit("Primary CodeDirectory missing")
if cd_off + 44 > sig_off + total_len:
    raise SystemExit("Truncated CodeDirectory header")

(
    cd_magic,
    cd_len,
    cd_version,
    cd_flags,
    hash_off,
    ident_off,
    n_special,
    n_code,
    code_limit,
) = struct.unpack_from(">IIIIIIIII", data, cd_off)

if cd_magic != CSMAGIC_CODEDIRECTORY:
    raise SystemExit(f"Unexpected CodeDirectory magic: 0x{cd_magic:08x}")
if cd_len < 44 or cd_off + cd_len > sig_off + total_len:
    raise SystemExit("Invalid CodeDirectory length")

hash_size, hash_type, platform, page_log2 = struct.unpack_from(
    "BBBB", data, cd_off + 36
)
if hash_type != 2 or hash_size != 32:
    raise SystemExit(
        f"Expected SHA-256 CodeDirectory, got type={hash_type} size={hash_size}"
    )
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
    "\n".join(
        [
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
        ]
    )
)

print(evidence.read_text(), end="")
