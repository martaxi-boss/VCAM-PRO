# VCAM PRO — Gate 1 Automated Device Proof Runner 001 — Marker Capture Blocker

## Status

**BLOCKED BEFORE DEVICE PACKAGE COMPLETION**

Task:

`VCAM-PRO-GATE1-AUTOMATED-DEVICE-PROOF-RUNNER-001`

Baseline:

`d476caacc4f557843f9551533c2fcbe7c5d40baa`

Branch:

`builder/gate1-automated-device-proof-runner-001`

This document records the static blocker discovered while implementing the required runtime marker observation for:

`VCAM_PRO_LOAD_PROBE_001`

No device action was performed.

## Required proof invariant

A valid `GATE_1_PASS` requires actual runtime observation of the existing Load Probe marker after the one controlled `mediaserverd` restart, correlated to the proof run, followed by a stable post-restart daemon.

The following are explicitly insufficient by themselves:

- installed package metadata;
- dylib/plist presence;
- a PID transition;
- a successful restart;
- the marker string existing in the binary.

## Existing Load Probe remains unchanged

Existing package:

`com.vcampro.loadprobe`

Version:

`0.0.1`

Expected rootless payload:

- `/var/jb/usr/lib/TweakInject/VCAMProLoadProbe.dylib`
- `/var/jb/usr/lib/TweakInject/VCAMProLoadProbe.plist`

Existing constructor emits through `os_log_with_type()` and is filtered to `mediaserverd`.

This task did not modify that package or its source.

## Public OSLogStore system-scope preflight

A narrow compile-time preflight was added for:

`[OSLogStore storeWithScope:OSLogStoreSystem error:&error]`

Target:

- iOS;
- arm64;
- deployment target 15.0;
- public SDK headers;
- no availability suppression.

GitHub Actions run:

`36226301981`

Result:

**FAILURE — EXPECTED TECHNICAL BLOCKER DISCOVERED**

Compiler diagnostic:

`'OSLogStoreSystem' is unavailable: not available on iOS`

The active iPhoneOS SDK header marks `OSLogStoreSystem` as unavailable for iOS, tvOS and watchOS.

The public iOS scope therefore cannot be used by the Gate 1 helper to obtain the system-wide unified log containing a marker emitted by another process.

The public iOS alternative, current-process scope, is insufficient because the marker is emitted by `mediaserverd`, not by the proof UI/helper process.

## Reference-repository check

Read-only references inspected:

- `martaxi-boss/MotionCam-iOS` @ `5ede3a1973a01cb13fe7f3ab562b47513feec1b1`
- `martaxi-boss/IOS-15-USB` @ `a908bccbcddb4efc072bb1bc8fbeb6ee89b1af9d`
- `martaxi-boss/IOS-16-USB-4k` @ `cc20d787070c67565173d4a46c218e2549cecc93`

Searches for reusable `os_log`, `logd`, `syslog` and ASL marker-capture machinery produced no implementation to reuse for this proof.

No reference repository was modified.

## Why implementation stops here

Under the current task authority, the remaining approaches would require at least one prohibited scope expansion:

1. use a private/unknown `logd`/unified-log client interface or entitlement;
2. bundle or reproduce proprietary Apple `log` tooling;
3. parse private unified-log storage formats directly;
4. modify the already-installed Load Probe to emit a second observable channel such as a proof file/IPC notification;
5. add in-process instrumentation/interposition to `mediaserverd`, which crosses into Gate 2-style instrumentation.

The task explicitly requires stopping rather than silently using any of those approaches.

## Partial implementation retained on branch

The branch currently contains bounded, host-testable Gate 1 state-machine work and the failed public marker-capture preflight. This partial work does **not** constitute a runnable proof package and does **not** authorize device execution.

The state-machine design preserves:

- explicit prerequisite checks;
- zero restart before prerequisites/marker capture are armed;
- exactly one intentional restart request per run;
- PID-before/PID-after history;
- stale-marker rejection;
- marker PID mismatch safety;
- bounded stability observation;
- restart-loop classification;
- explicit rerun lifecycle;
- terminal PASS / NOT_PROVEN / FAIL_LOAD_UNSTABLE states;
- no Gate 2 transition.

## Required decision before implementation can resume

A new Supervisor order must choose one of these authority changes:

- authorize a concrete iOS-15-compatible private logging mechanism after its dependency/risk is statically reviewed; or
- authorize a new version of the Load Probe that adds a narrow, local, proof-only marker channel while preserving the existing `os_log` marker; or
- authorize a different device-proof transport that still proves actual constructor execution without Gate 2 instrumentation.

Until then the correct state is:

`GATE_1_NOT_PROVEN`

Reason:

`MARKER_CAPTURE_UNAVAILABLE_WITHIN_CURRENT_SCOPE`

## Explicit non-claims

- NOT Gate 1 runtime PASS
- NOT Gate 2
- NOT Gate 3
- NOT camera callback observation
- NOT frame substitution
- NOT injector implementation

## Device / legacy safety

- DEVICE ACTIONS: NONE
- legacy VCam modified: NO
- `com.vcampro.loadprobe` modified: NO
- PR #9 modified: NO
- PR #10 modified: NO
- PR #11 modified: NO
- PR #12 modified: NO
