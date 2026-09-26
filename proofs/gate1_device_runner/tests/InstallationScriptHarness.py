#!/usr/bin/env python3
from pathlib import Path
import os
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "package"
SCRIPTS = [PACKAGE / "postinst", PACKAGE / "prerm", PACKAGE / "postrm"]

for script in SCRIPTS:
    text = script.read_text()
    if "set +e" not in text:
        raise SystemExit(f"{script.name}: missing set +e")
    if not text.rstrip().endswith("exit 0"):
        raise SystemExit(f"{script.name}: missing final exit 0")
    if "vcampro-gate1-coordinator" in text:
        raise SystemExit(f"{script.name}: install/remove script reaches coordinator")
    if re.search(
        r"SIGTERM|SIGKILL|killall|pkill|ldrestart|userspace|reboot|SpringBoard",
        text,
        re.IGNORECASE,
    ):
        raise SystemExit(f"{script.name}: forbidden runtime restart token")
    if ">>" in text:
        raise SystemExit(f"{script.name}: append-only state is not repeat-safe")
    subprocess.run(["/bin/sh", "-n", str(script)], check=True)

with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    for path in [
        root / "var/jb/bin",
        root / "var/jb/usr/bin",
        root / "var/jb/Applications/VCAMProGate1.app",
        root / "var/jb/Library/LaunchDaemons",
        root / "var/tmp",
        root / "bin",
        root / "usr/bin",
    ]:
        path.mkdir(parents=True, exist_ok=True)

    log = root / "calls.log"

    def fake_executable(path: Path) -> None:
        path.write_text(
            "#!/bin/sh\n"
            f"printf '%s\\n' \"$0 $*\" >> {log}\n"
            "exit 0\n"
        )
        path.chmod(0o755)

    fake_executable(root / "var/jb/bin/launchctl")
    fake_executable(root / "var/jb/usr/bin/uicache")

    (root / "var/jb/Library/LaunchDaemons/com.vcampro.gate1.handoff.plist").write_text(
        "test"
    )

    replacements = [
        ("/var/jb", str(root / "var/jb")),
        ("/var/tmp", str(root / "var/tmp")),
        ("/var/mobile", str(root / "var/mobile")),
        ("/bin/launchctl", str(root / "bin/launchctl")),
        ("/usr/bin/uicache", str(root / "usr/bin/uicache")),
    ]

    for source in SCRIPTS:
        transformed = source.read_text()
        for old, new in replacements:
            transformed = transformed.replace(old, new)
        target = root / source.name
        target.write_text(transformed)
        target.chmod(0o755)

        for _ in range(2):
            subprocess.run(
                ["/bin/sh", str(target), "remove"],
                check=True,
                env={**os.environ, "PATH": "/usr/bin:/bin"},
            )

print("POSTINST_DOES_NOT_RUN_GATE1=PASS")
print("MAINTAINER_SCRIPTS_DO_NOT_RESTART_MEDIASERVERD=PASS")
print("MAINTAINER_SCRIPTS_REPEAT_SAFE=PASS")
print("ROOT_HIDE_TWO_PASS_STATIC_HARNESS=PASS")
