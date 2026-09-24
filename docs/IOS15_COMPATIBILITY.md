# iOS 15.8.8 Compatibility Matrix

## Target

- iPhone 6s Plus
- Apple A9
- arm64
- iOS 15.8.8
- Dopamine
- rootless

Compatibility is a target, not a claim of current runtime support.

For the current **CENTRAL INJECTION RESEARCH** phase:

- **VERDE** — existence/adequacy is sufficiently supported to continue target-specific research.
- **AMARELO** — plausible/partially supported; exact target proof is still required.
- **VERMELHO** — insufficient basis for use in the next proof, a critical contract is unknown, or the mechanism must not yet be exercised.

A VERDE research classification is **not** a real-device runtime PASS.

Detailed evidence and source links are in `docs/research/CENTRAL_INJECTION_IOS15.md`.

## Matrix

| Area | Status | Current evidence | Required proof / boundary |
| --- | --- | --- | --- |
| Theos rootless package scheme | VERDE | Official Theos rootless scheme uses `/var/jb`, rootless rpaths and `iphoneos-arm64`; supports iOS 15+ | Future VCAM package build/install |
| Dopamine arm64 / iOS 15 research target | VERDE | Current Dopamine upstream includes iOS 15 in arm64 support range | Exact iPhone 6s Plus runtime confirmation |
| Dopamine process/systemhook propagation | VERDE | Current upstream source shows spawn-time systemhook injection policy | Observe exact installed target behavior |
| iOS 15 Dopamine spawn-hook path | VERDE | Current source has an iOS15-specific `_posix_spawn_with_filter` / `_execve_with_filter` path | Target runtime confirmation |
| Dopamine -> rootless `TweakLoader.dylib` | VERDE | Current systemhook source loads `/var/jb/usr/lib/TweakLoader.dylib` when tweak injection is enabled | Target load proof |
| ElleKit rootless tweak filtering | VERDE | Current source scans rootless TweakInject and supports Bundles/Executables filters | Target installed-version/path confirmation |
| Generic `mobilesubstrate` dependency interpretation | VERDE | ElleKit package declares `Provides: mobilesubstrate` | Do not infer Cydia Substrate runtime from dependency alone |
| Public AVFoundation sample callback | VERDE | Apple documents callback queue/lifetime/performance semantics; MotionCam uses it | Per-app only; not central architecture proof |
| CoreMedia / CoreVideo APIs | VERDE | Public Apple APIs + reference evidence | Central private callback contract still unresolved |
| `CMSampleBufferGetImageBuffer` API ownership rule | VERDE | Apple says returned image buffer is not caller-owned without explicit retain | Does not establish ownership of private central callback |
| VideoToolbox API family | VERDE | Apple documents decompression, pixel transfer and rotation; iOS16 reference links/uses these symbols | A9 performance and chosen use remain AMARELO |
| Local gallery access | AMARELO | MotionCam demonstrates local picker/media path | Outside central-injection first proof |
| `AVAssetReader` decode | AMARELO | Present in MotionCam | Outside first central proof; later A9 validation |
| arm64 / A9 runtime | AMARELO | Target architecture is supported by upstream toolchain/runtime families | Real-device execution |
| Dopamine rootless package deployment | AMARELO | Packaging/loader architecture is supported by upstream docs | Install/load proof on exact device |
| Actual VCAM dylib load in `mediaserverd` | AMARELO | Daemon filtering is mechanically plausible; iOS16 reference targets it | First LOAD proof |
| `mediaserverd` as central injection point | AMARELO | Strongest reference target evidence | Load + passive reachability + contract characterization |
| Private iOS15 hook symbol/class/selector | VERMELHO | Not identified with sufficient confidence | Exact iOS 15.8.8 discovery before hook |
| Private callback threading/reentrancy | VERMELHO | Unknown | Passive observation proof |
| `CMSampleBuffer` lifetime at central callback | VERMELHO | Public rules do not establish private callback contract | Passive observation/target characterization |
| `CVPixelBuffer` lifetime/pool reuse at central callback | VERMELHO | Static symbols show use; ownership contract unknown | Passive target proof |
| IOSurface cross-process capability | VERDE | Apple exposes Mach-port/XPC IOSurface transport | Actual VCAM data plane remains AMARELO |
| IOSurface VCAM data-plane design | AMARELO | Technically plausible public primitive | Ownership, synchronization and lifecycle design/proof |
| Darwin notification control plane | AMARELO | iOS16 static evidence includes Darwin-notification primitives | Target naming/delivery/race/lifecycle proof |
| Pixel format at central point | AMARELO | iOS16 reference queries/converts formats | Observe actual target camera formats |
| Frame dimensions at central point | AMARELO | iOS16 reference queries dimensions | Observe actual target dimensions |
| Color attachments | AMARELO | iOS16 evidence includes primaries/transfer/YCbCr matrix keys | Determine required propagation on target |
| Timing / PTS contract at central point | VERMELHO | Not established | Passive observation before any substitution |
| Memory pressure | VERMELHO | No central runtime proof | Measure only after safe passive load gate |
| 720p / 30 fps | AMARELO | First later performance target | Not part of injection-point proof |
| 1080p / 30 fps | AMARELO | Second later performance target | Attempt only after 720p stability |
| Frame substitution | VERMELHO | Critical central contracts unresolved | Explicit Supervisor authorization after passive proof |
| 4K | VERMELHO | Not an initial requirement | No initial promotion planned |

## Central-injection research result

### Leading candidate

`mediaserverd` is the **LEADING RESEARCH CANDIDATE**, not a final architecture decision.

The next proof, if authorized, must be:

**LOAD / REACHABILITY / PASSIVE OBSERVATION**

No frame substitution is justified yet.

## IOS-15-USB evidence boundary

The current `IOS-15-USB` GitHub repository remains empty.

Historical Owner-provided investigation may be used only as:

**HISTORICAL / NON-CURRENT-GITHUB EVIDENCE**

It must never be represented as current repository source or runtime proof.
