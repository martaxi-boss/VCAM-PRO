# VCAM PRO — Gate 1 Automated Device Proof Runner 001

## Status

**BLOCKED AT MARKER-CAPTURE PREFLIGHT / NOT RUNTIME PROVEN**

Task:

`VCAM-PRO-GATE1-AUTOMATED-DEVICE-PROOF-RUNNER-001`

Baseline main:

`d476caacc4f557843f9551533c2fcbe7c5d40baa`

Branch:

`builder/gate1-automated-device-proof-runner-001`

This workstream is device-proof tooling only. It is not product architecture and it does not authorize Gate 2.

## Intended owner flow

The requested owner experience remains:

`install/open -> wait -> final classification -> Share Evidence`

with no NewTerm, SSH, copied commands, manual kill commands, or manual log commands.

That final installable package is **not produced by this blocked iteration** because a required PASS condition cannot currently be implemented inside the authorized dependency boundary.

## Existing load probe

The already-built probe remains unchanged:

- package: `com.vcampro.loadprobe`
- version: `0.0.1`
- target: rootless arm64 / iOS 15.0+
- filter: `mediaserverd` only
- runtime marker: `VCAM_PRO_LOAD_PROBE_001`
- marker API: `os_log_with_type()`

No load-probe source, package, filter, or installed state is modified by this branch.

## Gate 1 state-machine core

A bounded, injectable Gate 1 state-machine core exists under:

- `proofs/gate1_device_runner/core/Gate1ProofRunner.h`
- `proofs/gate1_device_runner/core/Gate1ProofRunner.cpp`
- `proofs/gate1_device_runner/tests/Gate1ProofRunnerTests.cpp`

It models:

- prerequisite validation;
- marker-capture arming;
- exact mediaserverd discovery abstraction;
- exactly one restart request per run;
- PID-before/PID-after and PID history;
- stale marker rejection;
- marker PID mismatch handling;
- bounded respawn timeout;
- bounded stability observation;
- restart-loop detection;
- final PASS / NOT_PROVEN / FAIL_LOAD_UNSTABLE;
- explicit rerun as a new bounded lifecycle;
- no Gate 2 continuation.

Host tests use injected package, process, marker, restart and monotonic-time fakes. No real daemon restart is performed in CI.

## Marker-capture preflight

The required PASS contract needs actual runtime observation of:

`VCAM_PRO_LOAD_PROBE_001`

from `mediaserverd`, correlated with the proof run.

The first public-API candidate was `OSLogStore` system scope from the privileged proof helper.

GitHub Actions run:

`36226301981`

failed at compile time with the iPhoneOS SDK declaration:

`OSLogStoreSystem ... API_UNAVAILABLE(ios, tvos, watchos)`

The branch therefore does not treat `OSLogStoreSystem` as a viable iOS backend.

The replacement preflight records the public SDK boundary without intentionally failing CI:

- `OSLogStoreCurrentProcessIdentifier` is compiled for arm64 / iOS 15.0;
- the SDK declaration for `OSLogStoreSystem` is inspected;
- CI requires that system scope remains marked unavailable on iOS;
- the resulting artifact records that a separate helper cannot use the public iOS OSLogStore API to read `mediaserverd` logs.

Apple's public OSLog documentation also describes iOS log-store access as current-process scoped, while system/local store access is a macOS facility.

References:

- https://developer.apple.com/documentation/oslog/oslogstore
- https://developer.apple.com/forums/tags/oslog

## Exact blocker

A trustworthy `GATE_1_PASS` requires cross-process observation of the existing `os_log_with_type()` marker.

Within the currently authorized scope, the runner may not solve this by:

- modifying the already-installed Load Probe to emit a file/IPC marker;
- using a private logging framework or private logd protocol;
- bundling or redistributing Apple's `/usr/bin/log`;
- depending on the Owner manually running a log command;
- weakening PASS to infer load from package files, PID change, restart success, or a marker string embedded in a binary;
- turning the proof into Gate 2-style instrumentation.

The public iOS OSLog API does not provide the required separate-helper cross-process read.

Therefore the exact blocker is:

`MARKER_CAPTURE_UNAVAILABLE_WITHIN_AUTHORIZED_PUBLIC_DEPENDENCY_BOUNDARY`

Per the task contract, this is a stop condition, not permission to widen scope.

## What remains deliberately unimplemented

Because marker capture is blocked, this branch does not produce a falsely complete device package. In particular, it does not yet add:

- final privileged iOS helper implementation;
- UI application;
- launchd/helper packaging;
- final rootless `.deb`;
- evidence share sheet;
- real package scripts;
- real mediaserverd restart implementation;
- device installation or execution.

Those pieces would only be meaningful after an authorized, reliable marker-capture mechanism exists.

## Safety and non-effects

- `/usr/bin/log` dependency: **NO**
- real device actions: **NONE**
- `mediaserverd` restarted by Builder: **NO**
- legacy VCam modified: **NO**
- `com.vcampro.loadprobe` modified: **NO**
- PR #9 modified: **NO**
- PR #10 modified: **NO**
- PR #11 modified: **NO**
- PR #12 modified: **NO**
- reference repositories modified: **NO**
- networking: **NO**
- telemetry: **NO**
- camera frameworks/hooks/frame substitution: **NO**

## Runtime status

`GATE 1 = NOT YET RUNTIME PROVEN`

Explicitly:

- NOT Gate 1 runtime PASS
- NOT Gate 2
- NOT Gate 3
- NOT camera callback observation
- NOT frame substitution
- NOT injector implementation
