#!/usr/bin/env python3
from pathlib import Path
import os
import re
import stat
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
    if "--auto" in text:
        raise SystemExit(f"{script.name}: automatic Gate 1 execution token")
    if re.search(
        r"(^|\n)\s*(?:\"?\$COORDINATOR\"?|/var/jb/usr/libexec/"
        r"vcampro-gate1-coordinator)(?:\s|$)",
        text,
    ):
        raise SystemExit(f"{script.name}: executes coordinator")
    if re.search(
        r"SIGTERM|SIGKILL|killall|pkill|ldrestart|userspace|reboot|SpringBoard",
        text,
        re.IGNORECASE,
    ):
        raise SystemExit(f"{script.name}: forbidden runtime restart token")
    if "launchctl" in text:
        raise SystemExit(f"{script.name}: unexpected service-control dependency")
    if ">>" in text:
        raise SystemExit(f"{script.name}: append-only state is not repeat-safe")
    subprocess.run(["/bin/sh", "-n", str(script)], check=True)

with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    for path in [
        root / "var/jb/usr/bin",
        root / "var/jb/usr/libexec",
        root / "var/jb/Applications/VCAMProGate1.app",
        root / "var/tmp",
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

    coordinator = root / "var/jb/usr/libexec/vcampro-gate1-coordinator"
    fake_executable(coordinator)
    fake_executable(root / "var/jb/usr/bin/uicache")

    replacements = [
        ("/var/jb", str(root / "var/jb")),
        ("/var/tmp", str(root / "var/tmp")),
    ]

    transformed = {}
    for source in SCRIPTS:
        text = source.read_text()
        for old, new in replacements:
            text = text.replace(old, new)
        target = root / source.name
        target.write_text(text)
        target.chmod(0o755)
        transformed[source.name] = target

    for _ in range(2):
        subprocess.run(
            ["/bin/sh", str(transformed["postinst"])],
            check=True,
            env={**os.environ, "PATH": "/usr/bin:/bin"},
        )

    mode = coordinator.stat().st_mode
    if not (mode & stat.S_ISUID):
        raise SystemExit("postinst did not preserve/normalize setuid coordinator")

    for script_name in ["prerm", "postrm"]:
        for _ in range(2):
            subprocess.run(
                ["/bin/sh", str(transformed[script_name]), "remove"],
                check=True,
                env={**os.environ, "PATH": "/usr/bin:/bin"},
            )

print("POSTINST_DOES_NOT_RUN_GATE1=PASS")
print("MAINTAINER_SCRIPTS_DO_NOT_RESTART_MEDIASERVERD=PASS")
print("MAINTAINER_SCRIPTS_REPEAT_SAFE=PASS")
print("ROOT_HIDE_TWO_PASS_STATIC_HARNESS=PASS")
