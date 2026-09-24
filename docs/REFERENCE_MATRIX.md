# VCAM PRO Reference Matrix

| Repository | Target | Source available | Media source | Injection model | Rootful / rootless | Frame engine evidence | Useful concepts | Rejected / not adopted | Compatibility pending |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `martaxi-boss/MotionCam-iOS` | README/Makefile indicate iOS 14+ style target; arm64/arm64e build settings | Yes, source available at `5ede3a1973a01cb13fe7f3ab562b47513feec1b1` | Local gallery via `UIImagePickerController`; local decode with `AVAssetReader` | Process-local capture callback substitution; process-local state | Current docs/package path are not VCAM PRO's final rootless design | `CMSampleBuffer`, `CVPixelBuffer`, local reader/playback concepts | Gallery, picker, reader, playback, loop, simple UI | Process-local `g_vcamEnabled`, process-local `MediaManager`, per-app hooks as final architecture, current filter as final filter | Entire central architecture and iOS 15.8.8 target behavior |
| `martaxi-boss/IOS-15-USB` | No current GitHub target evidence | **No — current repository empty** | Unknown from current repo | Unknown from current repo | Unknown from current repo | Unknown from current repo | Historical hypotheses may guide research only | Any claim that historical package evidence is current GitHub source | Everything; current repo provides no implementation evidence |
| `martaxi-boss/IOS-16-USB-4k` | Package metadata includes `iphoneos-arm64`, firmware >= 15.0 | Binary/package/static-analysis artifacts at `cc20d787070c67565173d4a46c218e2549cecc93`; no reusable closed implementation | Not adopted as a product decision | Recovered filter/analysis involves `mediaserverd`; static frame-buffer evidence exists | Rootless `/var/jb` layout | CoreMedia/CoreVideo/VideoToolbox, `CVPixelBufferPool`, decode/transfer/rotation evidence | Central-injection research clues, buffer-pool concepts, Darwin notification concept, rootless layout | OBS/PC/USB/Wi-Fi/backend/login/wallet/plans/licensing/anti-debug/obfuscation/commercial components; proprietary binary implementation | All iOS 15.8.8 behavior, internals, threading, lifetime, timing, safety |
| `martaxi-boss/VCAM-PRO` | iPhone 6s Plus / A9 / arm64 / iOS 15.8.8 / Dopamine / rootless | Documentation only in this phase | Local gallery by design | Central point to be proven; `mediaserverd` only a candidate hypothesis | Rootless target | Dedicated adaptive Media Engine / Frame Engine planned | Original local architecture informed by references | No proprietary/binary implementation or external streaming/backend dependencies | Full build/runtime/device proof |

## Evidence rule

Reference repositories are READ ONLY.

Their evidence may shape experiments, but it does not automatically become a VCAM PRO compatibility claim.

In particular, iOS 16 package evidence must not be promoted to iOS 15.8.8 compatibility until the same concept is verified for iOS 15.8.8 / arm64 / iPhone 6s Plus and validated on the real device.
