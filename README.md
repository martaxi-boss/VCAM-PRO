# VCAM PRO

VCAM PRO is an on-device virtual-camera research and implementation project for jailbroken iOS.

## Current phase

- **PHASE:** CENTRAL INJECTION — DEVICE GATE 1 PREPARATION
- **FUNCTIONAL IMPLEMENTATION:** FRAME ENGINE THROUGH STAGE D1 + STAGE D2 VALIDATION; LOAD-ONLY PROBE BUILT
- **DEVICE WORK:** STARTED — RUNTIME PREPARATION / LEGACY ISOLATION
- **GATE 1 — LOAD:** PENDING
- **GATE 2 — PASSIVE CONTRACT OBSERVATION:** BLOCKED ON GATE 1 PASS
- **GATE 3 — MINIMAL SAFE SUBSTITUTION:** BLOCKED ON GATE 2 PASS
- **PUBLIC RELEASE:** NO

The Frame Engine has progressed through Stage D1 local producer-pipeline composition with Stage D2 non-device validation. A minimal audited load-only probe for `mediaserverd` has also been built. Neither result proves that VCAM PRO currently loads in `mediaserverd` on the target device.

## Official first target

- iPhone 6s Plus
- Apple A9
- arm64
- iOS 15.8.8
- Dopamine
- rootless

This target is normative. Runtime compatibility is not considered proven until the relevant behavior is validated on the real target device.

## Evidence policy

VCAM PRO separates static/reference facts from runtime facts.

**STATIC FACTS -> GitHub/reference artifacts**

Use GitHub and preserved reference artifacts for facts already available from:

- package metadata and extracted payloads;
- plists and filesystem layout;
- Mach-O metadata;
- imports and dynamic dependencies;
- strings and symbols;
- disassembly;
- source repositories.

**RUNTIME FACTS -> real iPhone only**

Use the real iPhone only for runtime-only evidence such as:

- actual dylib load and process/PID identity;
- real callback reachability;
- callback threading, frequency and lifetime;
- actual buffer format, dimensions and timing;
- crash/stability behavior;
- substitution and fail-open behavior;
- target-device performance.

The iPhone must not be used to rediscover static facts already preserved in GitHub.

## Simplified device gates

### Gate 1 — LOAD

Prove on iPhone 6s Plus / iOS 15.8.8 / Dopamine rootless that VCAM PRO's audited load probe loads in `mediaserverd`.

PASS requires runtime evidence tied to `mediaserverd`. No callback hook is required.

### Gate 2 — PASSIVE CONTRACT OBSERVATION

Only after Gate 1 PASS.

Observe the real callback/contract passively and characterize only runtime facts that static evidence cannot establish.

No frame replacement or substitution is permitted.

### Gate 3 — MINIMAL SAFE SUBSTITUTION

Only after Gate 2 PASS.

Perform the smallest possible virtual-frame substitution. Fail-open to the real camera is mandatory. No broad expansion is permitted before this succeeds.

## Product objective

The intended local pipeline is:

```text
LOCAL GALLERY
    ->
VCAM PRO CONTROL
    ->
LOCAL MEDIA ENGINE
    ->
FRAME ENGINE
    ->
COREMEDIA / COREVIDEO / VIDEOTOOLBOX
    ->
CENTRAL INJECTOR TO BE VALIDATED
    ->
CAMERA PIPELINE
    ->
CAMERA CONSUMERS
```

VCAM PRO is intended to operate locally on the iPhone and must not depend on:

- OBS;
- a PC;
- USB streaming;
- Wi-Fi streaming;
- an external backend.

## Architecture direction

The product is designed around three separate responsibilities:

1. **VCAM PRO CONTROL** — gallery selection, ON/OFF, Play/Pause, Loop, media selection, and state presentation.
2. **VCAM PRO MEDIA ENGINE / FRAME ENGINE** — local decode, timing, frame queueing, `CVPixelBuffer` handling, normalization, crop/scale/rotation, format/color handling, buffer reuse, and VideoToolbox where validated.
3. **VCAM PRO INJECTOR** — a minimal component at a central injection point that must first be proven for iOS 15.8.8. It consumes prepared frames, substitutes only when safe, and fails open to the real camera.

`mediaserverd` is the leading central research candidate, but Gate 1 load on the target device is still **NOT PROVEN**.

## Initial performance targets

1. Stable 720p / 30 fps.
2. Then 1080p / 30 fps.
3. 4K is not an initial requirement.

Priority order:

**STABILITY > LATENCY > QUALITY > MAXIMUM RESOLUTION**

These are Frame Engine performance targets, not the numbering of the device gates above.

## Read-only reference repositories

The following repositories are technical references only and are **READ ONLY** for VCAM PRO work:

- `martaxi-boss/MotionCam-iOS` @ `5ede3a1973a01cb13fe7f3ab562b47513feec1b1`
- `martaxi-boss/IOS-15-USB` @ `a908bccbcddb4efc072bb1bc8fbeb6ee89b1af9d`
- `martaxi-boss/IOS-16-USB-4k` @ `cc20d787070c67565173d4a46c218e2549cecc93`

`IOS-15-USB` is now a 31-file historical archive containing the preserved package, extracted payload, recovered dylib/plists, hashes, Mach-O evidence, dynamic dependencies, strings, symbols, disassembly and audit documentation. Its evidence is static/historical reference evidence, not iOS 15.8.8 runtime proof.

Reference material may inform investigation, but closed/binary implementation, credentials, secrets, backend components, commercial components, or proprietary dylibs must not be copied into VCAM PRO.

## Legacy policy

`com.vcam.universal` is legacy/reference material and is not part of VCAM PRO.

Current device evidence has shown an installed legacy payload capable of contaminating Gate 1. The legacy installation may be manipulated only as much as required to establish an uncontaminated Gate 1 baseline. The phone is not to be used for additional static reverse engineering of that package.

## Source of truth

GitHub is the technical source of truth for the project.

All new implementation belongs exclusively in `martaxi-boss/VCAM-PRO`. Reference repositories remain READ ONLY.
