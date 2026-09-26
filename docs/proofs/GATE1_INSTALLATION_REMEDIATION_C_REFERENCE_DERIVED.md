# VCAM PRO — Gate 1 Installation Remediation C — Reference-Derived

## Scope

Task:

`VCAM-PRO-GATE1-INSTALLATION-REMEDIATION-C-REFERENCE-DERIVED`

This remediation changes package installation behavior and the explicit post-install privilege handoff only. The accepted Gate 1 state machine, Witness, nonce/PID correlation, current-process OSLogStore observation, one-SIGTERM maximum, stability policy, result classifications and Share Evidence behavior remain unchanged.

## Package formula

Device-install candidate:

- package: `com.vcampro.gate1proofrunner`
- version: `0.2.1`
- architecture: `iphoneos-arm64`
- minimum iOS: 15.0
- dependencies: `firmware (>= 15.0), mobilesubstrate`
- rootless payload: `/var/jb/...`

`uikittools` is not a hard dependency.

`0.2.0 = SUPERSEDED_FOR_DEVICE_INSTALLATION`

## Installation/runtime separation

Maintainer scripts use reference-style best-effort behavior:

- `set +e`;
- guarded optional operations;
- `rm -f` for stale Gate 1-owned trigger state;
- final `exit 0`.

Installation never executes the Gate 1 coordinator, creates a proof nonce or signals `mediaserverd`.

If a compatible rootless `uicache` already exists, app registration/unregistration is best-effort. No package dependency is added for it.

The postinst may normalize the package-owned coordinator ownership/mode, but it does not execute it.

## Explicit Owner action

Opening `VCAM PRO Gate 1` does not run Gate 1.

The Owner must press:

`Run Gate 1`

While the one explicit run is active, the Run button is disabled. There is no automatic retry.

## Minimum privileged handoff

No persistent daemon, Mach service, polling worker or network service is used.

The existing coordinator remains at:

`/var/jb/usr/libexec/vcampro-gate1-coordinator`

The package stores it root-owned with mode `4755`.

The app performs one local `posix_spawn` of that fixed path only after the Owner presses `Run Gate 1`.

The coordinator immediately fails closed with status 77 before any Gate 1 activity unless:

`geteuid() == 0`

This handoff is statically grounded in RootHide's own bootstrap implementation:

- `roothide/Bootstrap-basebin@c66454cdeb9c1c4dfefd62500fc54e5f458e1a61/bootstrap/fixsuid.c`
- `roothide/Bootstrap-basebin@c66454cdeb9c1c4dfefd62500fc54e5f458e1a61/launchdhook/main.m`

Those sources explicitly detect `S_ISUID/S_ISGID` executables and apply the file UID/GID through spawn persona attributes.

An intermediate LaunchDaemon/NSXPC approach was rejected during Remediation C because iPhoneOS compilation proved:

`NSXPCListener initWithMachServiceName:` is unavailable on iOS.

That rejected path is not present in the terminal package topology.

Static support is not device certification; the real iPhone must still prove the post-install handoff and Gate 1 runtime result.

## Runtime invariant

The existing accepted coordinator/Witness engine remains in place:

- mediaserverd-local Witness;
- `OSLogStoreCurrentProcessIdentifier`;
- exact `VCAM_PRO_LOAD_PROBE_001` marker;
- nonce/PID/PID_AFTER correlation;
- maximum one `kill(PID_BEFORE, SIGTERM)`;
- bounded stability observation;
- PASS / NOT_PROVEN / FAIL_LOAD_UNSTABLE;
- `gate2_attempted=NO`.

No SIGKILL fallback, killall, pkill, ldrestart, reboot, userspace reboot or SpringBoard restart exists.

## RootHide two-pass safety

Repeated installation/conversion is treated as normal:

- stale request/witness files use `rm -f`;
- coordinator mode normalization is idempotent and best-effort;
- optional uicache is guarded;
- no append-only installation state is created;
- no proof execution occurs on either pass;
- scripts terminate successfully when optional registration is absent.

## Rollback

prerm/postrm remain package-owned, repeat-safe and non-blocking.

They may clear Gate 1 request/witness temporary state and best-effort unregister the Gate 1 viewer.

They do not execute Gate 1, restart mediaserverd, alter `com.vcampro.loadprobe`, touch legacy VCam, reboot or respring.

Final result/evidence files may remain for audit/export.

## Existing Load Probe

`proofs/mediaserverd_load_probe/` remains byte-for-byte unchanged against approved main:

`d476caacc4f557843f9551533c2fcbe7c5d40baa`

## Runtime status

`GATE 1 = NOT YET RUNTIME PROVEN`

Explicitly:

- NOT Gate 1 runtime PASS
- NOT Gate 2
- NOT Gate 3
