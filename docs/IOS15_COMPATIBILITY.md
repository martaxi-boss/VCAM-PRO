# iOS 15.8.8 Compatibility Matrix

## Target

- iPhone 6s Plus
- Apple A9
- arm64
- iOS 15.8.8
- Dopamine
- rootless

Compatibility is a target, not a claim of complete current runtime support.

For research classification:

- **VERDE** — existence/adequacy is sufficiently supported to continue target-specific work.
- **AMARELO** — plausible/partially supported; exact target proof is still required.
- **VERMELHO** — insufficient basis for the next runtime proof, a critical contract is unknown, or the mechanism must not yet be exercised.

A VERDE classification is **not** a real-device runtime PASS.

## Evidence boundary

**STATIC FACTS -> GitHub/reference artifacts.**

Use preserved package metadata, extracted payloads, plists, Mach-O, imports/dependencies, strings, symbols, disassembly and source repositories.

**RUNTIME FACTS -> real iPhone only.**

Actual load, PID/process identity, callback reachability, callback threading/frequency/lifetime, real buffer/format/timing behavior, stability, substitution/fail-open behavior and target-device performance require the iPhone.

## Matrix

| Area | Status | Current evidence | Required proof / boundary |
| --- | --- | --- | --- |
| Theos rootless package scheme | VERDE | Official Theos rootless scheme uses `/var/jb`, rootless rpaths and `iphoneos-arm64`; supports iOS 15+ | Package/install behavior still requires the target device where relevant |
| Dopamine arm64 / iOS 15 research target | VERDE | Upstream supports iOS 15 in its arm64 range | Exact target runtime behavior |
| Dopamine process/systemhook propagation | VERDE | Upstream source shows spawn-time systemhook injection policy | Observe exact installed target behavior |
| Dopamine -> rootless `TweakLoader.dylib` | VERDE | Upstream source loads `/var/jb/usr/lib/TweakLoader.dylib` when tweak injection is enabled | Target load proof |
| ElleKit rootless tweak filtering | VERDE | Source supports rootless TweakInject and Bundles/Executables filters | Exact installed-version/runtime behavior |
| Generic `mobilesubstrate` dependency interpretation | VERDE | ElleKit can provide `mobilesubstrate` compatibility | Dependency alone does not identify the historical runtime loader |
| Public AVFoundation sample callback | VERDE | Apple documentation + MotionCam source | Per-app evidence only; not central architecture proof |
| CoreMedia / CoreVideo APIs | VERDE | Public Apple APIs + MotionCam + IOS-15/IOS-16 static reference evidence | Private central callback contract still unresolved |
| `CMSampleBufferGetImageBuffer` ownership rule | VERDE | Apple API semantics plus static reference use | Does not establish ownership/lifetime of the real private callback |
| VideoToolbox API family | VERDE | Apple APIs plus IOS-15/IOS-16 static dependencies/symbols | A9 performance and chosen runtime use remain target-dependent |
| IOS-15-USB historical package identity | VERDE | Archive @ `a908bccbcddb4efc072bb1bc8fbeb6ee89b1af9d`: `com.vcam.universal` 1.0.0 / `iphoneos-arm64` / `mobilesubstrate` | Historical/static fact only |
| IOS-15-USB historical Mach-O | VERDE | arm64; minimum iOS 14.0; SDK 16.4 | Does not prove iOS 15.8.8 runtime compatibility |
| IOS-15-USB `mediaserverd` filter | VERDE | Preserved plist explicitly names `mediaserverd` | Static targeting intent only; no load proof |
| IOS-15-USB frame/hook evidence | VERDE | CoreMedia/CoreVideo/VideoToolbox, `CMSampleBuffer`, `CVPixelBuffer`, `MSHookFunction`, `MSHookMessageEx`, Darwin notification primitives | Does not identify the real callback contract or prove safe behavior |
| Local gallery access | AMARELO | MotionCam demonstrates a local picker/media path | Outside Gate 1 |
| `AVAssetReader` decode | AMARELO | MotionCam + VCAM PRO Frame Engine build/host validation | Runtime/performance proof later |
| arm64 / A9 runtime | AMARELO | Toolchain/runtime families support target architecture; device preparation has started | Relevant behavior must be measured on real device |
| Dopamine rootless VCAM package deployment | AMARELO | Packaging/loader architecture and load-probe package are built | Gate 1 target install/load proof |
| Actual VCAM PRO dylib load in `mediaserverd` | AMARELO | Audited load-only probe built; historical IOS-15 and IOS-16 filters target the daemon | **Gate 1 — LOAD** |
| `mediaserverd` as central injection point | AMARELO | Strong static reference evidence, but no target load/callback proof | Gate 1 then Gate 2 |
| Private iOS 15 callback/symbol/class/selector | VERMELHO | Static hook symbols/disassembly do not identify the actual target callback with sufficient confidence | **Gate 2 — PASSIVE CONTRACT OBSERVATION** |
| Private callback threading/reentrancy | VERMELHO | Unknown | Gate 2 |
| `CMSampleBuffer` lifetime at central callback | VERMELHO | Public ownership rules do not establish private callback lifetime | Gate 2 |
| `CVPixelBuffer` lifetime/pool reuse at central callback | VERMELHO | Static symbols show use; runtime ownership contract unknown | Gate 2 |
| IOSurface data plane | AMARELO | Public cross-process primitive + static reference clues | Runtime architecture/ownership/synchronization proof later |
| Darwin notification control plane | AMARELO | IOS-15 and IOS-16 static evidence includes Darwin-notification primitives | Naming/delivery/race/lifecycle must be validated if adopted |
| Pixel format at central point | AMARELO | Static references query/operate on pixel formats | Gate 2 observation |
| Frame dimensions at central point | AMARELO | Static references query dimensions | Gate 2 observation |
| Color attachments | AMARELO | Static evidence includes image-buffer metadata keys | Determine actual target requirements in Gate 2 |
| Timing / PTS contract at central point | VERMELHO | Not established statically | Gate 2 |
| Memory pressure | VERMELHO | No central runtime proof | Measure only after safe runtime gates |
| 720p / 30 fps | AMARELO | VCAM PRO host smoke PASS, not device performance proof | Later target-device performance validation |
| 1080p / 30 fps | AMARELO | Later performance target | Only after 720p stability |
| Frame substitution | VERMELHO | Critical central contracts unresolved | **Gate 3 only after Gate 2 PASS** |
| 4K | VERMELHO | Not an initial requirement | No initial promotion planned |

## IOS-15-USB current evidence boundary

Current reference:

`martaxi-boss/IOS-15-USB@a908bccbcddb4efc072bb1bc8fbeb6ee89b1af9d`

The repository is a valid static historical reference containing 31 preserved files, including the original historical package, extracted payload, recovered dylib/plists, SHA-256 evidence, package metadata, Mach-O metadata, dynamic dependencies, strings, symbols, disassembly and audit documentation.

Archive-derived findings are **STATIC/HISTORICAL**.

They do not prove:

- that the historical package loads on the present target;
- that VCAM PRO's load probe loads on iOS 15.8.8;
- the real central callback;
- callback threading/lifetime/timing;
- safe frame substitution;
- target-device performance.

## Simplified device gates

### Gate 1 — LOAD

Prove the audited VCAM PRO load probe loads in `mediaserverd` on the target. No callback hook required.

### Gate 2 — PASSIVE CONTRACT OBSERVATION

Only after Gate 1 PASS. Passively characterize the real target callback/contract with no substitution.

### Gate 3 — MINIMAL SAFE SUBSTITUTION

Only after Gate 2 PASS. Perform the smallest possible virtual-frame substitution with mandatory fail-open to the real camera.

Current state:

**GATE 1 = NOT YET PROVEN.**
