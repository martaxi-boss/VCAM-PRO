# VCAM PRO Architecture

## 1. Objective

VCAM PRO is designed around one on-device flow:

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
VALIDATED CENTRAL INJECTOR
    ->
CAMERA PIPELINE
    ->
CAMERA CONSUMERS
```

The first normative target is iPhone 6s Plus / A9 / arm64 / iOS 15.8.8 / Dopamine / rootless.

This document defines responsibilities and research boundaries. It does not claim runtime compatibility.

## 2. VCAM PRO CONTROL

Responsibilities:

- UI;
- local-gallery selection;
- ON/OFF;
- Play/Pause;
- Loop;
- media replacement;
- state presentation.

The control component must not become the heavy video-processing path.

## 3. VCAM PRO MEDIA ENGINE

Responsibilities:

- local-media access;
- `AVAssetReader` or another validated decoder;
- timing;
- frame queueing;
- `CVPixelBuffer` handling;
- normalization;
- scale/crop;
- rotation;
- resolution and pixel-format handling;
- color metadata;
- buffer reuse;
- VideoToolbox where validated.

Heavy decode/conversion work belongs here, not in the injector.

## 4. Frame Engine

The Frame Engine must not permanently assume 1920x1080 or a fixed pixel format.

Where applicable it must adapt to the active consumer contract:

- width;
- height;
- pixel format;
- color primaries;
- transfer function;
- YCbCr matrix;
- attachments;
- orientation;
- timing.

### Initial A9 performance goals

- first gate: stable 720p / 30 fps;
- second gate: 1080p / 30 fps;
- 4K: not an initial requirement.

Priority order:

**STABILITY > LATENCY > QUALITY > MAXIMUM RESOLUTION**

## 5. VCAM PRO INJECTOR

The injector must be minimal.

Responsibilities:

- execute only at a central point that has been validated for iOS 15.8.8;
- consume ready virtual frames;
- verify compatibility;
- substitute only when safe;
- fail open to the real camera.

The injector must not decode media, perform sustained heavy frame processing, or block indefinitely waiting for another component.

## 6. Control plane

The control plane carries small state and commands, for example:

- enabled/disabled state;
- selected-media state;
- Play/Pause;
- Loop;
- lifecycle/error state;
- notifications.

Darwin notifications are a research candidate because they appear in the iOS 16 reference evidence. The exact mechanism remains subject to target validation.

## 7. Data plane

The data plane carries heavy frame data separately from the control plane.

Research candidates include:

- IOSurface-backed buffers;
- shared pixel-buffer pools;
- another validated low-overhead mechanism appropriate to the proven process boundary.

Large video frames must not be transported through Darwin notifications.

## 8. Central injection research

`mediaserverd` is currently:

**CANDIDATE CENTRAL INJECTION POINT / RESEARCH HYPOTHESIS**

Reasons to investigate it:

- the iOS 16 reference contains recovered filter/analysis evidence involving `mediaserverd`;
- the same reference contains CoreMedia/CoreVideo/VideoToolbox frame-buffer evidence;
- a central point could avoid duplicated process-local state and per-app injection.

Reasons it is not yet approved:

- iOS 15 and iOS 16 internals can differ;
- private/internal contracts can vary by build/device;
- service stability is critical;
- an invalid hook, blocking path, lifetime error, or incompatible buffer can affect the system camera service.

The later research phase must prove the real target callback/symbol path, threading, lifetime, timing, buffer requirements, and fail-open behavior on the real iPhone 6s Plus before architecture freeze.

## 9. Reference-derived concepts

### MotionCam-iOS — useful reference concepts

- local gallery selection;
- `UIImagePickerController`;
- `AVAssetReader`;
- playback;
- loop behavior;
- simple UI.

### MotionCam-iOS — not final VCAM PRO architecture

- process-local enable state;
- process-local `g_vcamEnabled`;
- process-local `MediaManager`;
- hooks only inside each application/process as the final architecture;
- the current filter as the final VCAM PRO filter.

### IOS-16-USB-4k — research evidence only

- CoreMedia/CoreVideo/VideoToolbox involvement;
- `CMSampleBufferGetImageBuffer`;
- `CVPixelBufferPool`;
- VideoToolbox decode/transfer/rotation sessions;
- Darwin notifications;
- rootless package layout;
- `mediaserverd` filter/analysis evidence.

None of the binary-derived implementation is to be copied.

## 10. External dependency boundary

VCAM PRO must not depend on:

- OBS;
- a PC;
- USB streaming;
- Wi-Fi streaming;
- a backend;
- external login;
- wallets;
- plans;
- subscriptions;
- third-party commercial licensing.

The implementation must be original and live exclusively in `martaxi-boss/VCAM-PRO`.
