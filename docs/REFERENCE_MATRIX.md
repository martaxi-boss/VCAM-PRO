# VCAM PRO Reference Matrix

Current reference baseline for Device Proof Policy 005.

| Repository | Current reference | Evidence type | Injection / media evidence | Useful concepts | Explicit boundary |
| --- | --- | --- | --- | --- | --- |
| `martaxi-boss/MotionCam-iOS` | `5ede3a1973a01cb13fe7f3ab562b47513feec1b1` | Source repository | Process-local capture callback substitution; local gallery; `AVAssetReader`; `CMSampleBuffer` / `CVPixelBuffer` handling | Gallery, picker, local reader/playback/loop, sample/pixel-buffer handling | Process-local hooks/state are not the final central architecture; no automatic iOS 15.8.8 central-runtime claim |
| `martaxi-boss/IOS-15-USB` | `a908bccbcddb4efc072bb1bc8fbeb6ee89b1af9d` | 31-file historical READ-ONLY archive | Historical rootless package `com.vcam.universal` 1.0.0; `iphoneos-arm64`; `mobilesubstrate`; filter names `mediaserverd`; CoreMedia/CoreVideo/VideoToolbox; `CMSampleBufferGetImageBuffer`; `CMSampleBufferCreateReady`; `CVPixelBuffer` APIs; `MSHookFunction`; `MSHookMessageEx`; Darwin-notification primitives | Rootless layout, central-targeting clues, sample/pixel-buffer handling clues, hook/control-plane research evidence | **STATIC/HISTORICAL EVIDENCE ONLY**; does not prove iOS 15.8.8 load, real callback identity, threading/lifetime/timing, safe substitution, or device stability; no proprietary implementation copy |
| `martaxi-boss/IOS-16-USB-4k` | `cc20d787070c67565173d4a46c218e2549cecc93` | Binary/package/static-analysis artifacts | Rootless layout; recovered `mediaserverd` targeting; CoreMedia/CoreVideo/VideoToolbox; buffer pools; decode/transfer/rotation; Darwin notifications | Central-injection clues, pool/normalization concepts, small-signal control-plane concepts | No iOS 15.8.8 compatibility assumption; no proprietary/commercial implementation copy |
| `martaxi-boss/VCAM-PRO` | `main` baseline `d476caacc4f557843f9551533c2fcbe7c5d40baa` before this reconciliation | Original implementation + proofs | Frame Engine through Stage D1 with Stage D2 validation; audited load-only `mediaserverd` probe built | Local Frame Engine, bounded ready queue, fail-open architecture, minimal central-load proof | Gate 1 runtime load still pending; Gate 2/3 blocked; no public release |

## Evidence rule

Reference repositories are **READ ONLY**.

**STATIC FACTS -> GitHub/reference artifacts.**

Package metadata, extracted payloads, plists, Mach-O metadata, imports/dependencies, strings, symbols, disassembly and source code are resolved from preserved repository evidence.

**RUNTIME FACTS -> real iPhone only.**

Actual dylib load, PID/process identity, callback reachability, threading/frequency/lifetime, real buffer/format/timing behavior, stability, substitution/fail-open behavior and target-device performance require device proof.

**STATIC EVIDENCE != IOS 15.8.8 RUNTIME PROOF.**

**NO PROPRIETARY IMPLEMENTATION COPY.**

## Device gates

1. **GATE 1 — LOAD:** prove VCAM PRO's audited dylib loads in `mediaserverd` on iPhone 6s Plus / iOS 15.8.8 / Dopamine rootless.
2. **GATE 2 — PASSIVE CONTRACT OBSERVATION:** after Gate 1 PASS, observe the real callback/contract without substitution.
3. **GATE 3 — MINIMAL SAFE SUBSTITUTION:** after Gate 2 PASS, perform the smallest possible substitution with mandatory fail-open to the real camera.

Gate 1 is currently **NOT PASS**.
