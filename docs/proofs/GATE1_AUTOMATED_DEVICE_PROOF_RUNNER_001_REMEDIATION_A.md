# VCAM PRO — Gate 1 Automated Device Proof Runner 001 — Remediation A

## Status

**AUTOMATED PROOF PACKAGE IMPLEMENTATION / NOT DEVICE-RUNTIME PROVEN**

Task:

`VCAM-PRO-GATE1-AUTOMATED-DEVICE-PROOF-RUNNER-001-REMEDIATION-A`

Approved remediation start:

`84d08b0671e1c2b18e23bbfa8169a2fa2931bfe2`

The historical blocker remains preserved at:

`docs/proofs/GATE1_AUTOMATED_DEVICE_PROOF_RUNNER_001_BLOCKER.md`

That blocker is still correct for the rejected topology:

`separate helper -> system-wide OSLogStore`

Remediation A changes only marker observation topology to:

`mediaserverd-local Witness -> OSLogStoreCurrentProcessIdentifier -> bounded local evidence`

This is Gate 1 proof tooling only. It is not Gate 2.

## Existing authoritative Load Probe

The existing package remains:

- package: `com.vcampro.loadprobe`
- version: `0.0.1`
- marker: `VCAM_PRO_LOAD_PROBE_001`
- rootless dylib: `/var/jb/usr/lib/TweakInject/VCAMProLoadProbe.dylib`
- rootless plist: `/var/jb/usr/lib/TweakInject/VCAMProLoadProbe.plist`

Remediation A does not modify, replace, patch or repackage the Load Probe.

Dedicated CI compares `proofs/mediaserverd_load_probe/` against approved main
`d476caacc4f557843f9551533c2fcbe7c5d40baa` and fails if it differs.

## Witness

The proof package adds a separate:

`VCAMProGate1Witness.dylib`

with an injection filter containing only:

`mediaserverd`

On constructor entry the Witness verifies the current process is exactly
`mediaserverd`. If no valid active proof request is present, it returns without
starting proof activity.

For an active request it:

1. parses the bounded run request;
2. verifies freshness against monotonic time;
3. defers observation asynchronously on a serial queue so constructor ordering is
   not assumed;
4. uses the public iOS scope
   `OSLogStoreCurrentProcessIdentifier`;
5. searches for the exact existing marker formatted with the current
   `mediaserverd` PID;
6. requires the log entry to identify the same process/PID;
7. writes nonce-correlated local witness evidence;
8. stops after success or the finite witness timeout.

The Witness does not use `OSLogStoreSystem`, private `logd` interfaces,
`/usr/bin/log`, hooks, interposition, swizzling, camera callbacks, frames,
networking or telemetry.

## Run correlation

The coordinator creates a fresh cryptographic random nonce before the intentional
restart.

The request carries:

- schema;
- nonce;
- proof-start monotonic time;
- runner version;
- build SHA.

Witness evidence carries:

- schema;
- same nonce;
- exact marker text;
- process;
- PID;
- witness version;
- monotonic observation time.

Protocol validation rejects malformed, wrong-nonce, stale, wrong-process,
wrong-PID and wrong-marker evidence. The state machine also requires the accepted
marker PID to equal `PID_AFTER` before PASS.

## Process discovery and restart

The iOS platform implementation discovers processes with:

`sysctl(CTL_KERN, KERN_PROC, KERN_PROC_ALL)`

and accepts only exactly one process whose `p_comm` is `mediaserverd`.

The only intentional restart primitive is:

`kill(PID_BEFORE, SIGTERM)`

A platform-level one-shot guard rejects a duplicate restart request.

There is no SIGKILL fallback, `killall`, `pkill`, `ldrestart`, respring,
userspace reboot or reboot.

## Stability and classification

The retained bounded state machine records `PID_BEFORE`, waits for a different
`PID_AFTER`, tracks PID history, and then observes the new daemon for the
configured stability window.

A valid `GATE_1_PASS` requires all prerequisite, marker, nonce, PID and stability
conditions to succeed.

A stable new daemon without trustworthy marker evidence is
`GATE_1_NOT_PROVEN`.

Post-restart disappearance or PID churn is
`GATE_1_FAIL_LOAD_UNSTABLE`.

No automatic second restart exists.

## Package and Owner flow

Proof package:

`com.vcampro.gate1proofrunner`

The package is rootless and separate from the future VCAM PRO production package.

The intended Owner flow is:

`install in Sileo -> one-shot proof executes -> open VCAM PRO Gate 1 -> Share Evidence`

No NewTerm, SSH, copied shell commands, manual PID lookup, manual log collection
or manual daemon kill is required.

## Results and export

The minimal UIKit result viewer presents the final classification and details from:

- `VCAM_PRO_GATE1_RESULT.txt`
- `VCAM_PRO_GATE1_RESULT.json`

It provides `Share Evidence` through the local iOS share sheet.

Evidence remains local. There is no automatic upload, backend or telemetry.

## Rollback

Package removal removes only Gate 1 runner-owned package files and active
temporary request/witness files.

It does not:

- uninstall or modify `com.vcampro.loadprobe`;
- modify legacy VCam;
- restart `mediaserverd`;
- respring;
- reboot.

Final exported/result evidence may remain as documented evidence.

## Validation boundary

Host/CI validation can prove source behavior, correlation policy, package layout,
arm64/minimum iOS target, dependency boundaries and one-shot restart policy.

It cannot prove the real iPhone runtime load.

Therefore, until the certified iPhone executes this package:

`GATE 1 = NOT YET RUNTIME PROVEN`

## Explicit non-claims

- NOT Gate 1 runtime PASS
- NOT Gate 2
- NOT Gate 3
- NOT camera callback observation
- NOT frame substitution
- NOT injector implementation
