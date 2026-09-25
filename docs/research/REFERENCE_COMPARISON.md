# Reference Comparison — VCAM PRO Foundation

## Scope

This document preserves the GitHub evidence used at the time of the VCAM PRO foundation research. It does not transfer implementation, ownership, licensing, or compatibility claims from a reference project.

Historical foundation baseline:

- MotionCam-iOS: `5ede3a1973a01cb13fe7f3ab562b47513feec1b1`
- IOS-15-USB: **EMPTY REPOSITORY**
- IOS-16-USB-4k: `cc20d787070c67565173d4a46c218e2549cecc93`

## Current superseding reference note — 2026-09-25

The baseline above is preserved as historical evidence. At that time `IOS-15-USB` was empty.

The repository was subsequently populated as a historical READ-ONLY archive. Current reference HEAD:

`a908bccbcddb4efc072bb1bc8fbeb6ee89b1af9d`

The current archive contains 31 preserved files and provides static historical evidence for `com.vcam.universal` 1.0.0, `iphoneos-arm64`, `mobilesubstrate`, rootless layout, a `mediaserverd`-targeting filter, CoreMedia/CoreVideo/VideoToolbox use, sample/pixel-buffer APIs, Darwin notifications and hook primitives.

This superseding evidence does **not** prove iOS 15.8.8 runtime compatibility, the actual callback contract, threading/lifetime/timing, or safe substitution. No proprietary implementation may be copied into VCAM PRO.

The historical performance labels “Gate 1 = stable 720p30” and “Gate 2 = 1080p30” below are not the current device-gate numbering. Current device gates are:

1. **Gate 1 — LOAD**
2. **Gate 2 — PASSIVE CONTRACT OBSERVATION**
3. **Gate 3 — MINIMAL SAFE SUBSTITUTION**

**STATIC FACTS -> GitHub/reference artifacts.**

**RUNTIME FACTS -> real iPhone only.**

## Historical foundation comparison

| Dimension | MotionCam-iOS | IOS-15-USB | IOS-16-USB-4k | VCAM PRO decision |
| --- | --- | --- | --- | --- |
| Architecture evidence | Open source tweak with UI, process-local state, media manager, and capture callback substitution | No current GitHub source | Binary/package with static-analysis evidence | Separate Control, Media Engine/Frame Engine, and minimal Injector |
| Target evidence | iOS 14+ style project; arm64/arm64e build settings | None in current repo | `iphoneos-arm64`; firmware >= 15.0 | Normative first target: iPhone 6s Plus / A9 / arm64 / iOS 15.8.8 / Dopamine / rootless |
| Source available | Yes | No | No reusable closed implementation source; binary/static artifacts only | All future implementation must be original in VCAM-PRO |
| Media source | Local saved-photo/video picker | Unknown | Not adopted from binary evidence | Local gallery |
| Decode path | `AVAssetReader` | Unknown | Static evidence includes `VTDecompressionSession` | Start from local/public decode design; use VideoToolbox only when target-validated |
| Playback | Start/stop and loop concepts | Unknown | Binary behavior not used as a product contract | Play/Pause/Loop belongs in Control/Media Engine |
| Injection model | Per-process capture callback substitution | Historical claims may be research hints only | Recovered filter/analysis references `mediaserverd` | Research the actual central point; do not freeze `mediaserverd` before iOS 15.8.8 proof |
| Frame representation | `CMSampleBuffer` + `CVPixelBuffer` | Historical claims may mention these only as non-current evidence | `CMSampleBufferGetImageBuffer`, pixel buffers, pools | Use CoreMedia/CoreVideo contracts, adapting to real consumer requirements |
| Resolution handling | Current manager contains fixed/default resolution behavior | Unknown | Static analysis alone does not prove consumer adaptation | Never hard-code one permanent resolution |
| Pixel format | Current reader requests a specific YCbCr format | Unknown | Format-query/pool evidence exists | Match or normalize against the real consumer contract |
| Color metadata | Not a complete central architecture | Unknown | Image-buffer primaries/transfer/YCbCr matrix evidence | Preserve/normalize attachments deliberately |
| Rotation / transfer | Basic asset-transform handling | Unknown | `VTPixelRotationSession`, `VTPixelTransferSession` | Frame Engine owns crop/scale/rotation/transfer work |
| Rootful/rootless | Existing project docs are not the VCAM PRO rootless target | No current evidence | Rootless `/var/jb` package layout | Rootless is mandatory for Dopamine target |
| Control plane | Process-local globals/UI | Unknown | Darwin notification primitives exist | Validate small cross-process state/signaling; Darwin notification is a candidate |
| Data plane | Process-local media manager | Unknown | IOSurface/pixel-buffer related evidence exists | Validate IOSurface/shared-buffer or equivalent data plane; never send heavy frames through Darwin notifications |
| Failsafe | Falls through to original frame path when not substituting, but not a complete central-service policy | Unknown | Static evidence cannot prove fail-open behavior | Mandatory fail-open to real frame for every unavailable/invalid/stale case |
| Performance | No accepted A9 proof | None | No accepted A9/iOS 15 proof | Gate 1 = stable 720p30; Gate 2 = 1080p30; 4K not initial |
| Provenance | Source is reference material | No current source | Closed/binary evidence only | No proprietary dylib, converted disassembly implementation, credentials, secrets, backend, or commercial components copied |

## MotionCam-iOS

### Use as reference

- local gallery;
- `UIImagePickerController`;
- `AVAssetReader`;
- playback;
- loop;
- simple UI.

### Do not adopt as final architecture

- process-local state;
- process-local `g_vcamEnabled`;
- process-local `MediaManager`;
- hooks only per application/process;
- current filter as the final VCAM PRO architecture.

## IOS-15-USB — historical foundation baseline

GitHub evidence at the time of this foundation comparison:

**EMPTY REPOSITORY**

Any historical audit of an older .deb must be labeled:

**HISTORICAL / NON-CURRENT-GITHUB EVIDENCE**

Permitted research hypotheses only:

- iOS 15;
- arm64;
- rootless;
- `mediaserverd`;
- `CMSampleBuffer`;
- `CVPixelBuffer`;
- central injection.

These were not facts about the repository at that historical baseline.

### Current IOS-15-USB superseding evidence

Current archive HEAD:

`a908bccbcddb4efc072bb1bc8fbeb6ee89b1af9d`

Current static evidence includes:

- historical package `com.vcam.universal` 1.0.0 / `iphoneos-arm64` / `mobilesubstrate`;
- rootless package/payload layout;
- arm64 Mach-O, minimum iOS 14.0, SDK 16.4;
- filter entries naming `mediaserverd`;
- CoreMedia/CoreVideo/VideoToolbox;
- `CMSampleBufferGetImageBuffer` and `CMSampleBufferCreateReady`;
- `CVPixelBuffer` APIs;
- `MSHookFunction` and `MSHookMessageEx`;
- Darwin-notification primitives.

**STATIC EVIDENCE != IOS 15.8.8 RUNTIME PROOF.**

## IOS-16-USB-4k

At the observed HEAD, repository evidence includes:

- `iphoneos-arm64`;
- rootless `/var/jb`;
- MobileSubstrate;
- CoreMedia;
- CoreVideo;
- VideoToolbox;
- `CMSampleBufferGetImageBuffer`;
- `CVPixelBufferPool`;
- `VTDecompressionSession`;
- `VTPixelTransferSession`;
- `VTPixelRotationSession`;
- Darwin notification primitives;
- `mediaserverd` in recovered filter/analysis.

This evidence justifies experiments. It does not prove that the same internals, symbols, callback behavior, threading, lifetime, timing, or service behavior are safe on iOS 15.8.8.

### Explicitly rejected

VCAM PRO will not inherit:

- OBS;
- PC dependency;
- USB streaming;
- Wi-Fi streaming;
- backend;
- login;
- wallet;
- plans;
- licensing;
- anti-debug behavior;
- obfuscation;
- proprietary/commercial components.

## VCAM PRO

Implementation must be original.

Target:

- iPhone 6s Plus;
- A9;
- arm64;
- iOS 15.8.8;
- Dopamine;
- rootless.

Performance plan:

1. stable 720p / 30 fps;
2. then 1080p / 30 fps;
3. 4K is not an initial requirement.

Priority:

**STABILITY > LATENCY > QUALITY > MAXIMUM RESOLUTION**

## Historical foundation research conclusion

The foundation directs the next supervised phase to:

1. preserve the useful local-gallery and local-media concepts;
2. build toward a dedicated adaptive Frame Engine;
3. investigate the iOS 16 central-service evidence without assuming cross-version compatibility;
4. prove the real iOS 15.8.8 central injection point on the target device;
5. separate the control plane from the heavy frame data plane;
6. keep the injector minimal and fail open to the real camera.

No functional implementation begins until the Supervisor audits this foundation.


## Current policy superseding the foundation phase

VCAM PRO now has original Frame Engine implementation through Stage D1 with Stage D2 validation and a built load-only `mediaserverd` probe.

Current device work has started, but **Gate 1 is not PASS**.

The normative progression is:

1. Gate 1 — prove the audited VCAM PRO dylib loads in `mediaserverd`;
2. Gate 2 — after Gate 1 PASS, passively observe the real callback/contract with no substitution;
3. Gate 3 — after Gate 2 PASS, perform the smallest safe substitution with mandatory fail-open.

The historical foundation evidence above remains intact as chronology; this section supplies the current reference/device-proof policy.
