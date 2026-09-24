# VCAM PRO — Project State

## Current phase

- **PHASE:** FOUNDATION / ARCHITECTURE
- **FUNCTIONAL IMPLEMENTATION:** NOT STARTED
- **DEVICE PROOF:** NOT STARTED
- **CENTRAL INJECTION:** RESEARCH REQUIRED
- **IOS 15.8.8 COMPATIBILITY:** TARGET / NOT YET PROVEN
- **PUBLIC RELEASE:** NO

## Normative target

- iPhone 6s Plus
- Apple A9
- arm64
- iOS 15.8.8
- Dopamine
- rootless

No runtime PASS may be recorded until the relevant behavior is tested on the real target device.

## Product direction

VCAM PRO is intended to source media directly from the local iPhone gallery, decode and normalize it locally, produce camera-compatible frame buffers, and substitute frames at a central injection point that has first been validated for iOS 15.8.8.

The preferred system boundary is entirely on-device. OBS, PC transport, USB streaming, Wi-Fi streaming, external backends, external authentication, wallets, plans, subscriptions, and third-party licensing are outside the product architecture.

## Central injection decision status

`mediaserverd` is currently:

**CANDIDATE CENTRAL INJECTION POINT / RESEARCH HYPOTHESIS**

It is not yet an approved final injection point. The later research phase must establish the actual central point on iOS 15.8.8, characterize the relevant internals, and prove stability and fail-open behavior before architecture freeze.

## Reference state observed during foundation preflight

| Repository | Mutability | Observed state |
| --- | --- | --- |
| `martaxi-boss/VCAM-PRO` | Mutable project repo | Empty before bootstrap; no branch/HEAD existed |
| `martaxi-boss/MotionCam-iOS` | READ ONLY | `main` @ `5ede3a1973a01cb13fe7f3ab562b47513feec1b1` |
| `martaxi-boss/IOS-15-USB` | READ ONLY | Repository empty; no branch/HEAD |
| `martaxi-boss/IOS-16-USB-4k` | READ ONLY | `main` @ `cc20d787070c67565173d4a46c218e2549cecc93` |

## Foundation evidence summary

### MotionCam-iOS

Current source contains local gallery selection, `UIImagePickerController`, `AVAssetReader`, local playback/loop concepts, a `MediaManager`, and a process-local enable flag. Its current substitution path is process-local and is not adopted as VCAM PRO's final central architecture.

### IOS-15-USB

Current GitHub evidence is only:

**EMPTY REPOSITORY**

Any Owner-provided information about an older package is classified as:

**HISTORICAL / NON-CURRENT-GITHUB EVIDENCE**

It may guide research hypotheses around iOS 15, arm64, rootless operation, `mediaserverd`, `CMSampleBuffer`, `CVPixelBuffer`, and central injection, but it is not current-repository proof.

### IOS-16-USB-4k

Static evidence at the observed HEAD includes:

- `iphoneos-arm64`
- rootless `/var/jb/...` layout
- MobileSubstrate
- CoreMedia
- CoreVideo
- VideoToolbox
- `CMSampleBufferGetImageBuffer`
- `CVPixelBufferPool`
- `VTDecompressionSession`
- `VTPixelTransferSession`
- `VTPixelRotationSession`
- Darwin notification primitives
- a recovered filter/analysis referencing `mediaserverd`

This evidence is useful for research only. It does **not** establish iOS 15.8.8 compatibility.

## Performance targets

1. Stable 720p / 30 fps.
2. Then 1080p / 30 fps.
3. 4K is not an initial requirement.

Priority:

**STABILITY > LATENCY > QUALITY > MAXIMUM RESOLUTION**

## Next allowed phase

The next phase may be **CENTRAL INJECTION RESEARCH** only after Supervisor audit of this foundation.

No tweak, media service, injector, daemon, dylib, application, package, hook, functional Makefile, jailbreak script, functional release workflow, Objective-C code, C/C++ code, or binary belongs to this phase.
