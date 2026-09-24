# VCAM PRO

VCAM PRO is an on-device virtual-camera research project for jailbroken iOS.

## Current phase

- **PHASE:** FOUNDATION / ARCHITECTURE
- **FUNCTIONAL IMPLEMENTATION:** NOT STARTED
- **DEVICE PROOF:** NOT STARTED
- **PUBLIC RELEASE:** NO

This phase establishes documentation and research boundaries only. It does not implement a tweak, injector, media service, daemon, application, package, hook, or release workflow.

## Official first target

- iPhone 6s Plus
- Apple A9
- arm64
- iOS 15.8.8
- Dopamine
- rootless

This target is normative. Runtime compatibility is not considered proven until validated on the real target device.

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

`mediaserverd` is currently a **CANDIDATE CENTRAL INJECTION POINT / RESEARCH HYPOTHESIS**. It is not an approved final injection point.

## Initial performance targets

1. Stable 720p / 30 fps.
2. Then 1080p / 30 fps.
3. 4K is not an initial requirement.

Priority order:

**STABILITY > LATENCY > QUALITY > MAXIMUM RESOLUTION**

## Read-only reference repositories

The following repositories are technical references only and are **READ ONLY** for VCAM PRO work:

- `martaxi-boss/MotionCam-iOS`
- `martaxi-boss/IOS-15-USB`
- `martaxi-boss/IOS-16-USB-4k`

All new implementation must live exclusively in:

`martaxi-boss/VCAM-PRO`

Reference material may inform investigation, but closed/binary implementation, credentials, secrets, backend components, commercial components, or proprietary dylibs must not be copied into VCAM PRO.

## Source of truth

GitHub is the technical source of truth for the project.

The Supervisor controls project progression. After this foundation is completed, no later phase begins until the Supervisor audits it.
