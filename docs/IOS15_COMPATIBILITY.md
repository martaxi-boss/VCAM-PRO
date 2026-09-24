# iOS 15.8.8 Compatibility Matrix

## Target

- iPhone 6s Plus
- Apple A9
- arm64
- iOS 15.8.8
- Dopamine
- rootless

Compatibility is a target, not a claim of current support.

## Legend

- **VERDE** — sufficiently proven for the normative target with direct target-appropriate evidence.
- **AMARELO** — plausible or partially supported, but target-specific build/runtime/device proof is incomplete.
- **VERMELHO** — not safe to accept as compatible at this stage; critical target runtime evidence is missing.

No runtime item is marked VERDE in this foundation.

## Matrix

| Area | Status | Current evidence | Required proof |
| --- | --- | --- | --- |
| Public AVFoundation APIs | AMARELO | MotionCam source uses the public media stack | Build and exercise the exact VCAM PRO path on iOS 15.8.8 |
| CoreMedia / CoreVideo | AMARELO | Present in reference evidence | Validate exact sample/pixel-buffer contract on target |
| Local gallery access | AMARELO | MotionCam demonstrates gallery/media selection | Validate chosen API and permissions on target |
| `AVAssetReader` decode | AMARELO | Present in MotionCam source | Validate codec coverage, timing, loop behavior, and A9 resource use |
| arm64 / A9 | AMARELO | Normative hardware target; reference evidence is arm64-oriented | Native build plus sustained real-device execution |
| iOS 15.8.8 | VERMELHO | No VCAM PRO runtime proof exists | Real-device proof on exact OS target |
| Dopamine / rootless | AMARELO | Normative target; iOS 16 reference has `/var/jb` layout | Validate package paths, loader behavior, permissions, and runtime on target |
| Packaging | AMARELO | Rootless packaging concepts exist in reference | Produce and install VCAM PRO package on target |
| MobileSubstrate-style injection | AMARELO | References use/declare substrate-style injection | Validate actual loader compatibility on target jailbreak |
| VideoToolbox decode | AMARELO | iOS 16 evidence includes `VTDecompressionSession` | Validate availability, codecs, hardware path, resource use, and fallback on A9 |
| VideoToolbox transfer | AMARELO | iOS 16 evidence includes `VTPixelTransferSession` | Validate target availability and output compatibility |
| VideoToolbox rotation | AMARELO | iOS 16 evidence includes `VTPixelRotationSession` | Validate target availability and orientation semantics |
| `mediaserverd` central injection | VERMELHO | iOS 16 filter/analysis references it | Identify exact iOS 15.8.8 hook point and prove stability/fail-open behavior |
| Private hooks / internals | VERMELHO | No target proof exists | Discover and validate exact target symbols/callbacks |
| IOSurface data plane | AMARELO | Architecturally appropriate; reference evidence contains IOSurface-related buffer properties | Validate ownership, sharing, synchronization, and lifetime on target |
| Darwin-notification control plane | AMARELO | iOS 16 evidence contains Darwin notification primitives | Validate delivery, lifecycle, races, and naming on target |
| `CMSampleBuffer` lifetime | VERMELHO | Reference evidence alone is insufficient | Prove retain/release and callback lifetime rules at target injection point |
| `CVPixelBuffer` compatibility | AMARELO | Strong reference evidence exists | Verify dimensions, planes, strides, pool attributes, IOSurface properties, and ownership |
| Threading | VERMELHO | No central target injection proof exists | Identify callback thread/queue and prove non-blocking behavior |
| Memory | VERMELHO | No VCAM PRO runtime exists | Measure pools, allocations, decoder footprint, leaks, and sustained use |
| Timing | VERMELHO | No target injector proof exists | Validate PTS/cadence, stale-frame rules, and consumer behavior |
| Pixel formats | AMARELO | Reference code/evidence uses pixel buffers and format queries | Match actual consumer format instead of assuming one fixed format |
| Color attachments | AMARELO | iOS 16 evidence references primaries/transfer/YCbCr matrix keys | Verify propagation/normalization on target |
| 720p / 30 fps | AMARELO | Defined first performance target | Sustained device proof |
| 1080p / 30 fps | AMARELO | Defined second performance target | Attempt after 720p/30 is stable |
| 4K | VERMELHO | Not an initial requirement | No promotion planned in the initial phase |

## Promotion rule

An item becomes VERDE only when the evidence matches the normative target and the claimed behavior. Evidence from iOS 16, another device, a simulator, or static binary inspection is not interchangeable with iOS 15.8.8 / iPhone 6s Plus runtime proof.

## IOS-15-USB evidence boundary

The current `IOS-15-USB` GitHub repository is empty.

Historical Owner-provided investigation may be used only as:

**HISTORICAL / NON-CURRENT-GITHUB EVIDENCE**

It must never be represented as current repository source.
