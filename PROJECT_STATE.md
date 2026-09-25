# VCAM PRO — Project State

## Current phase

- **PHASE:** CENTRAL INJECTION — DEVICE GATE 1 PREPARATION
- **FUNCTIONAL IMPLEMENTATION:** FRAME ENGINE STAGE D1 IMPLEMENTED; STAGE D2 VALIDATION PASS
- **LOAD-ONLY PROBE:** BUILT / STATIC VALIDATION PASS
- **DEVICE WORK:** STARTED — PREFLIGHT / LEGACY BASELINE PREPARATION
- **GATE 1 — LOAD:** PENDING
- **GATE 2 — PASSIVE CONTRACT OBSERVATION:** BLOCKED ON GATE 1 PASS
- **GATE 3 — MINIMAL SAFE SUBSTITUTION:** BLOCKED ON GATE 2 PASS
- **FRAME ENGINE CONTRACT:** DEFINED
- **FRAME ENGINE STAGE A BUILD:** PASS
- **FRAME ENGINE STAGE B BUILD:** PASS
- **FRAME ENGINE STAGE C1 BUILD:** PASS
- **FRAME ENGINE STAGE D1 BUILD:** PASS
- **FRAME ENGINE STAGE D2 VALIDATION:** PASS
- **FRAME ENGINE DECODER:** AVASSETREADER LOCAL VIDEO — BUILD/HOST TEST PASS
- **LOCAL PRODUCER PIPELINE:** AVASSETREADER -> NORMALIZATION ADMISSION -> READY QUEUE — BUILD/HOST TEST PASS
- **CONSUMER FAST PATH:** READYFRAMEQUEUE TRYACQUIRE / DECODE-INDEPENDENT BUILD PROOF PASS
- **CONSUMER AVFOUNDATION DEPENDENCY:** NONE IN D2 CONSUMER ARCHIVE
- **READY FRAME QUEUE:** BOUNDED / BUILD-HOST TEST PASS
- **QUEUE STRESS:** HOST PASS
- **CONCURRENCY STRESS:** HOST PASS
- **ASAN / UBSAN:** PASS
- **TSAN:** PASS
- **720P30 HOST SMOKE:** PASS — NOT DEVICE PERFORMANCE PROOF
- **NORMALIZATION:** ADMISSION + PASSTHROUGH ONLY
- **PIXEL TRANSFORMS:** NOT STARTED
- **TRANSFORM PRIMITIVE:** NOT SELECTED / IOS 15.8.8 DEVICE BEHAVIOR NOT PROVEN
- **PRODUCER SCHEDULER:** NOT STARTED
- **CAMERA TIMING:** UNKNOWN / NOT STARTED
- **CVPIXELBUFFERPOOL:** NOT STARTED / DEFERRED TO MEASUREMENT
- **MEDIASERVERD LOAD:** NOT YET PROVEN
- **FRAME ACCESS:** NO RUNTIME CONTRACT PROOF
- **FRAME SUBSTITUTION:** PROHIBITED UNTIL GATES 1 AND 2 PASS
- **IOS 15.8.8 RUNTIME:** PARTIAL DEVICE PREPARATION ONLY / CENTRAL LOAD NOT PROVEN
- **A9 720P30 DEVICE PERFORMANCE:** NOT YET MEASURED
- **PUBLIC RELEASE:** NO

## Normative target

- iPhone 6s Plus
- Apple A9
- arm64
- iOS 15.8.8
- Dopamine
- rootless
- ElleKit-compatible tweak loading

Runtime claims require evidence from the real target device. Static facts must be taken from GitHub/reference artifacts instead of rediscovered manually on the phone.

## Current repository baseline

Current reconciled starting `main` for Reference Baseline + Device Proof Policy 005:

`d476caacc4f557843f9551533c2fcbe7c5d40baa`

Reference repositories are READ ONLY at:

| Repository | Current reference state |
| --- | --- |
| `martaxi-boss/MotionCam-iOS` | `main` @ `5ede3a1973a01cb13fe7f3ab562b47513feec1b1` |
| `martaxi-boss/IOS-15-USB` | historical archive @ `a908bccbcddb4efc072bb1bc8fbeb6ee89b1af9d` |
| `martaxi-boss/IOS-16-USB-4k` | `main` @ `cc20d787070c67565173d4a46c218e2549cecc93` |

## IOS-15-USB current reference

`IOS-15-USB` is no longer empty. At the current reference HEAD it is a 31-file historical READ-ONLY archive.

Static archive evidence establishes, among other facts:

- historical package `com.vcam.universal`, version `1.0.0`;
- architecture `iphoneos-arm64`;
- dependency `mobilesubstrate`;
- rootless package/payload layout;
- arm64 Mach-O with minimum iOS 14.0 and SDK 16.4;
- filter data explicitly naming `mediaserverd`;
- CoreMedia/CoreVideo/VideoToolbox dependencies;
- static `CMSampleBuffer` / `CVPixelBuffer` API evidence;
- `MSHookFunction` / `MSHookMessageEx` symbol evidence;
- Darwin notification primitive evidence.

These facts are historical/static only. They do **not** prove current iOS 15.8.8 load, the real callback contract, threading/lifetime/timing behavior, or safe substitution.

No proprietary binary/code from the archive may be incorporated into VCAM PRO.

## Device proof policy

### STATIC FACTS -> GitHub/reference artifacts

Use package metadata, extracted files, plists, Mach-O, imports/dependencies, strings, symbols, disassembly and source repositories.

### RUNTIME FACTS -> real iPhone only

Use the target device for actual load, PID/process identity, callback reachability, real threading/frequency/lifetime, buffer format/timing, stability, substitution/fail-open and target-device performance.

Avoid long manual NewTerm investigations that merely rediscover preserved static evidence.

## Simplified device gates

### Gate 1 — LOAD

Prove that the audited VCAM PRO load probe loads in `mediaserverd` on the normative target.

PASS requires runtime evidence tied to `mediaserverd`. No callback hook is required.

**CURRENT: PENDING**

### Gate 2 — PASSIVE CONTRACT OBSERVATION

Only after Gate 1 PASS.

Passively establish the actual target callback/contract and runtime properties not available from static evidence.

No substitution.

**CURRENT: BLOCKED**

### Gate 3 — MINIMAL SAFE SUBSTITUTION

Only after Gate 2 PASS.

Perform the smallest possible virtual-frame substitution with mandatory fail-open to the real camera.

**CURRENT: BLOCKED**

## Load-only probe

Source location:

`proofs/mediaserverd_load_probe/`

The probe is intentionally limited to a C dylib constructor that:

1. reads process identity;
2. returns unless the process is exactly `mediaserverd`;
3. emits one bounded unified-log marker containing process name and PID.

Marker:

`VCAM_PRO_LOAD_PROBE_001`

Injection filter:

**Executable = mediaserverd only**

No hook, camera callback, frame access, IPC, media engine, frame production, frame conversion, or frame substitution exists in this implementation.

Historical build provenance:

- successful GitHub Actions run ID: `36055302355`;
- package: `com.vcampro.loadprobe_0.0.1_iphoneos-arm64.deb`;
- SHA-256: `d97e5be4c96a005d3fc630dfed7aeac837939e4843b912c7686803ad75061f62`;
- rootless payload paths:
  - `/var/jb/usr/lib/TweakInject/VCAMProLoadProbe.dylib`
  - `/var/jb/usr/lib/TweakInject/VCAMProLoadProbe.plist`

Detailed build evidence:

`docs/proofs/MEDIASERVERD_LOAD_PROBE_001.md`

The successful build does not prove that the dylib loads in `mediaserverd` on iOS 15.8.8.

## Legacy isolation boundary

`com.vcam.universal` is legacy/reference material, not part of VCAM PRO.

Current device evidence has shown an installed legacy payload that can contaminate Gate 1. Legacy manipulation is limited to what is required for an uncontaminated Gate 1 baseline. Do not use the phone for additional static reverse engineering of the historical package.

## Provenance

VCAM PRO implementation remains original.

Reference repositories remain READ ONLY. Static reference concepts may inform experiments, but no proprietary implementation is copied.

## Public release

**NO**

No public release is authorized. Gate 1 remains pending.
