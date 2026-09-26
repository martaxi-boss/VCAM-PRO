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

`uikittools` is no longer a hard dependency.

`0.2.0 = SUPERSEDED_FOR_DEVICE_INSTALLATION`

## Installation/runtime separation

Maintainer scripts are best-effort, repeat-safe and terminate successfully.

The package installation does **not** execute the Gate 1 coordinator and does **not** create a proof nonce or signal `mediaserverd`.

Post-install may:

- clear stale package-owned request/witness trigger files;
- register the dormant package-owned handoff LaunchDaemon when a compatible built-in `launchctl` exists;
- register the app with an already-present `uicache`.

Missing optional tools do not fail the package transaction.

## Explicit Owner action

Opening the app does not run Gate 1.

The Owner must press:

`Run Gate 1`

The app disables duplicate Run actions while a request is active and displays a running state.

## Minimum privileged handoff

The package installs a narrow system LaunchDaemon:

`com.vcampro.gate1.handoff`

It is:

- `RunAtLoad = false`;
- `KeepAlive = false`;
- local Mach service only;
- root-owned system-domain helper;
- dormant until a Mach-service connection is requested;
- self-terminating after one proof request or a finite idle timeout;
- not a command shell and accepts no arbitrary executable/path/arguments.

The UIKit app uses public Foundation `NSXPCConnection` to request one proof run. The helper launches only the fixed existing coordinator path:

`/var/jb/usr/libexec/vcampro-gate1-coordinator`

The helper has no network transport and no polling loop.

## Runtime invariant

A single explicit Owner action can cause at most one existing coordinator execution.

The coordinator retains the accepted maximum intentional restart contract:

`kill(PID_BEFORE, SIGTERM)`

maximum:

`1`

There is no SIGKILL, killall, pkill, ldrestart, reboot, userspace reboot or SpringBoard restart fallback.

## Rollback

prerm/postrm are package-owned, best-effort, repeat-safe and do not execute Gate 1.

They may:

- unload the Gate 1-owned dormant handoff registration;
- clean active Gate 1 request/witness temporary files;
- unregister the Gate 1 viewer if an optional compatible uicache exists.

They do not alter the Load Probe or legacy VCam and do not restart mediaserverd.

## Validation boundary

Static/CI validation proves package shape, dependency policy, installation/runtime separation, two-pass script behavior, rootless payload, arm64/minimum iOS, and the existing Gate 1 invariants.

It does not certify the post-install runtime handoff on the iPhone.

Therefore:

`GATE 1 = NOT YET RUNTIME PROVEN`

Explicitly:

- NOT Gate 1 runtime PASS
- NOT Gate 2
- NOT Gate 3
