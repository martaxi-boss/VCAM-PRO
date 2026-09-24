# VCAM PRO — Central Injection Research: iOS 15

## 0. Purpose and evidence discipline

This document answers one bounded research question:

> What is the most plausible and safe central point for a first injection proof on iPhone 6s Plus / A9 / arm64 / iOS 15.8.8 / Dopamine / rootless, and what evidence is still missing before code?

This is a research artifact. It does **not** implement an injector, a tweak, a media engine, IPC, gallery access, frame substitution, or a device proof.

Material conclusions use these labels:

- **FACT** — directly supported by the cited current source or repository evidence.
- **INFERENCE** — a reasoned conclusion from facts, not direct proof.
- **UNKNOWN** — not established by the currently authorized evidence.

The normative target remains:

- iPhone 6s Plus
- Apple A9
- arm64
- iOS 15.8.8
- Dopamine
- rootless

No item in this report is a device-runtime PASS.

---

## 1. Exact evidence baseline

### VCAM PRO

**FACT**

Research baseline:

`martaxi-boss/VCAM-PRO` `main` @

`6e2e30e1242f47fed702e0af1cab51137eb6f77a`

The research branch was created exactly from that commit:

`builder/central-injection-research-001`

### Reference repositories

**FACT**

- `martaxi-boss/MotionCam-iOS` — `main` @ `5ede3a1973a01cb13fe7f3ab562b47513feec1b1`
- `martaxi-boss/IOS-15-USB` — repository empty; no branch and no HEAD
- `martaxi-boss/IOS-16-USB-4k` — `main` @ `cc20d787070c67565173d4a46c218e2549cecc93`

All three are READ ONLY.

### Official upstream snapshots consulted

**FACT**

Current upstream heads observed during this research:

- Dopamine `opa334/Dopamine`, default branch `3.x`: `1a54e76d515ff5916b64e44d6afbb57d2bc89ee9`
- ElleKit `tealbathingsuit/ellekit`, `main`: `1017a0d09606ea49ba8bc4d6cccc530d372e640e`

Theos and Apple documentation were also consulted as primary documentation sources.

---

## 2. Dopamine / rootless injection findings

### 2.1 Target and packaging model

**FACT**

The current Dopamine README describes Dopamine as rootless and includes iOS 15 in its supported arm64 range. This supports using Dopamine/rootless as a legitimate research environment for the normative iOS 15.8.8 arm64 target. [D1]

**FACT**

Theos rootless packaging uses `THEOS_PACKAGE_SCHEME=rootless`, installs under the rootless prefix `/var/jb`, uses rootless-aware rpaths, and sets package architecture to `iphoneos-arm64`. Theos also states that the rootless scheme supports iOS 15+. [T1] [T2]

**Research classification:** **VERDE** for packaging existence/adequacy to continue research. This is not a successful package-install proof on the target device.

### 2.2 Current Dopamine process-injection layer

**FACT**

Current Dopamine source contains a system process-injection layer named `systemhook.dylib`. Its spawn path inserts `DYLD_INSERT_LIBRARIES=/usr/lib/systemhook.dylib` into spawned processes unless injection is disabled by policy/safe-mode conditions. [D2]

**FACT**

Dopamine's current `systemhook` code contains explicit process exclusions for stability and a safe-mode path. On iOS 15, the source uses the available `_posix_spawn_with_filter` / `_execve_with_filter` path rather than the iOS 16+ instruction-replacement path. [D3]

**FACT**

When tweak loading is enabled, current Dopamine `systemhook` attempts to load:

`/var/jb/usr/lib/TweakLoader.dylib`

inside the process. [D3]

**FACT**

Dopamine's user-facing tweak-injection state maps to a jailbreak safe-mode marker and requires a userspace reboot to apply the global setting change. [D4]

### 2.3 ElleKit loader layer

**FACT**

ElleKit describes itself as a C/Objective-C hooker and a Substrate/libhooker API reimplementation, with arm64 iOS 15 support in its tested configurations. [E1]

**FACT**

ElleKit's package metadata declares:

- `Provides: mobilesubstrate (= 99)`
- replacement/conflict relationships involving historical hooking packages
- description: tweak injection libraries and loader

Therefore a Debian dependency that says only `Depends: mobilesubstrate` does **not** prove that Cydia Substrate itself is the runtime hook implementation. [E2]

**FACT**

ElleKit's build/package layout creates `TweakLoader.dylib` as a compatibility entry to its injector and installs its rootless components under the rootless prefix. Its post-install logic explicitly recognizes Dopamine systemhooks as loading `/var/jb/usr/lib/TweakLoader.dylib`. [E3] [E4]

**FACT**

ElleKit's injector enumerates rootless tweaks under:

`/var/jb/usr/lib/TweakInject/`

and evaluates filter criteria including bundle identifiers, executable names, and classes before loading a matching tweak dylib. [E5]

### 2.4 Effective current chain for research

**FACT**

The current source supports this high-level loader chain:

```text
Dopamine process-spawn/systemhook infrastructure
        ->
/var/jb/usr/lib/TweakLoader.dylib
        ->
ElleKit injector / filter evaluation
        ->
matching rootless tweak dylib
        ->
hook implementation through ElleKit-compatible APIs
```

This is materially different from treating the package field `Depends: mobilesubstrate` as the full runtime architecture.

### 2.5 Applications versus system daemons

**FACT**

The Dopamine systemhook policy is broad and explicitly contains process-specific exclusions, demonstrating that process eligibility and stability are policy-sensitive rather than universally assumed. [D2] [D3]

**FACT**

ElleKit supports executable-name filtering, not only app bundle filtering. That mechanism is structurally capable of selecting a daemon by executable name. [E5] [E6]

**FACT**

No current Dopamine source exclusion for `mediaserverd` was identified in the inspected current systemhook policy.

**INFERENCE**

The current Dopamine + ElleKit architecture therefore makes a filtered tweak load into `mediaserverd` mechanically plausible on rootless arm64.

**UNKNOWN**

This research has **not** proven on an iPhone 6s Plus / iOS 15.8.8 device that:

- `mediaserverd` actually receives and successfully loads a VCAM test dylib;
- its sandbox/entitlement/runtime state permits the intended VCAM observation hook;
- the relevant camera callback exists in the same form as on the iOS 16 reference;
- loading a custom dylib there is stable over camera-session and daemon restart cycles.

### 2.6 Critical-process restrictions

**FACT**

Dopamine itself has process blacklists and safe-mode paths intended to preserve stability. Its source comments explicitly acknowledge processes that are problematic for injection. [D2] [D3]

**INFERENCE**

A critical service such as `mediaserverd` must be treated more conservatively than an ordinary app: first prove load, then passive reachability, then characterize lifetime/threading, and only after those gates consider frame substitution.

**UNKNOWN**

No official Dopamine source examined here states a `mediaserverd`-specific safety guarantee. Absence from a blacklist is not a safety guarantee.

---

## 3. MotionCam-iOS process-local comparison

Reference: `martaxi-boss/MotionCam-iOS` @ `5ede3a1973a01cb13fe7f3ab562b47513feec1b1`.

### Confirmed source observations

**FACT**

The current filter requests `com.apple.UIKit` and `SpringBoard` targets. [R1]

**FACT**

`Tweak.xm` contains:

- process-local global `g_vcamEnabled`;
- a `%ctor`;
- `VCamHooks`;
- local picker/UI setup;
- a hook around `captureOutput:didOutputSampleBuffer:fromConnection:`;
- substitution with a frame obtained from the local `MediaManager` when enabled. [R1]

**FACT**

`MediaManager` is a process-local singleton. It uses `AVAssetReader`, performs local playback/loop operations, handles `CMSampleBuffer` / `CVPixelBuffer`, and requests a specific bi-planar YCbCr pixel format for the current reader path. [R1]

**FACT**

Apple documents `captureOutput:didOutputSampleBuffer:fromConnection:` as an AVFoundation delegate callback invoked on the configured callback queue. Apple explicitly warns that the callback must remain efficient, and that retaining sample buffers too long can exhaust reusable pools and cause frame drops. [A1]

### Architectural consequence

**INFERENCE**

The MotionCam architecture is useful proof that local media can be transformed into sample buffers and substituted at an application-visible capture callback, but its enable state, media manager, and substitution point live in the injected process. Every process therefore carries its own state/lifetime and receives its own hook.

**INFERENCE**

That design does not by itself establish a single central injection point for all camera consumers.

**UNKNOWN**

MotionCam does not prove what private central callback `mediaserverd` exposes on iOS 15.8.8.

---

## 4. IOS-15-USB evidence boundary

Reference: `martaxi-boss/IOS-15-USB`.

**FACT**

Current GitHub state is:

**EMPTY REPOSITORY**

There is no current branch, HEAD, source tree, package metadata, binary, or documentation in the repository.

Any Owner-provided information about an older package remains:

**HISTORICAL / NON-CURRENT-GITHUB EVIDENCE**

**INFERENCE**

Historical claims can help formulate questions about iOS 15, arm64, rootless operation, `mediaserverd`, `CMSampleBuffer`, `CVPixelBuffer`, or central injection.

They cannot prove any current implementation detail or compatibility result.

---

## 5. IOS-16-USB-4k static evidence map

Reference: `martaxi-boss/IOS-16-USB-4k` @ `cc20d787070c67565173d4a46c218e2549cecc93`.

### 5.1 Package and loader evidence

**CONFIRMED STATIC EVIDENCE / FACT**

Package metadata contains:

- package `com.if-she.cydia.vcam`
- version `3.1.6`
- architecture `iphoneos-arm64`
- dependency `mobilesubstrate`
- firmware >= 15.0

The extracted package uses a rootless `/var/jb/...` layout. [R2]

**INFERENCE**

Because current ElleKit can satisfy a generic `mobilesubstrate` dependency, the package field alone cannot identify the concrete hook runtime that was active on the original device.

### 5.2 Injection filter

**CONFIRMED STATIC EVIDENCE / FACT**

The recovered filter includes:

- bundle `com.apple.mediaserverd`
- executable `mediaserverd`
- additional UIKit/SpringBoard targets. [R2]

This is the strongest current reference evidence that the proprietary iOS 16-era binary intentionally targeted a central camera-related daemon.

### 5.3 Media and buffer symbols

**CONFIRMED STATIC EVIDENCE / FACT**

Static Mach-O/symbol/string evidence includes:

- CoreMedia
- CoreVideo
- VideoToolbox
- `CMSampleBufferCreateReady`
- `CMSampleBufferGetImageBuffer`
- `CMVideoFormatDescriptionCreate`
- `CVPixelBuffer` width/height/format/base-address APIs
- `CVPixelBufferRetain` / `CVPixelBufferRelease`
- `CVPixelBufferPoolCreate`
- `CVPixelBufferPoolCreatePixelBuffer`
- `kCVPixelBufferIOSurfacePropertiesKey`
- color-primary / transfer-function / YCbCr-matrix attachment keys
- `VTDecompressionSession`
- `VTPixelTransferSession`
- `VTPixelRotationSession`
- Darwin notification primitives
- `MSHookFunction`
- `MSHookMessageEx`. [R2]

**FACT**

Apple's public CoreMedia documentation states that `CMSampleBufferGetImageBuffer` returns an image buffer the caller does not own; it must be retained explicitly if a longer-lived reference is needed. [A2]

**FACT**

Apple documents VideoToolbox as exposing decompression, pixel transfer, and pixel rotation sessions over CoreVideo pixel buffers. [A3]

**FACT**

Apple IOSurface APIs support passing an IOSurface reference to another task using a Mach port or XPC object. [A4]

### 5.4 What static evidence does not reveal

**UNKNOWN**

The inspected metadata, symbols, strings, and extracted headers do **not** identify with sufficient confidence:

- the exact private iOS camera class or C function hooked inside `mediaserverd`;
- the exact selector/callback that carries the real camera frame;
- whether the hook is before or after any specific camera processing stage;
- the callback queue/thread;
- whether the original callback owns, borrows, or transfers the `CMSampleBuffer`;
- the valid retention interval for its `CVPixelBuffer`;
- exact pixel formats/resolutions encountered on the iPhone 6s Plus;
- iOS 15.8.8 symbol/class equivalence;
- daemon restart behavior when the tweak is loaded.

**INFERENCE**

The combination of a `mediaserverd` filter, frame-buffer APIs, buffer pools, VideoToolbox operations, attachment keys, and hook primitives is consistent with a design that observes and/or transforms video frames inside that daemon.

That remains an inference. This report does not reconstruct the proprietary implementation.

---

## 6. iOS 16 -> iOS 15 research compatibility matrix

In this section:

- **VERDE** = enough primary/current evidence that the mechanism exists and is appropriate to continue target-specific research.
- **AMARELO** = plausible and supported in part, but exact target proof is still required.
- **VERMELHO** = insufficient basis for use in the next proof, known mismatch, or a missing critical contract.

**VERDE does not mean real-device runtime PASS.**

| Mechanism / contract | Status | Evidence | Remaining gate |
| --- | --- | --- | --- |
| Theos rootless packaging | VERDE | Official Theos rootless scheme uses `/var/jb`, rootless rpaths, `iphoneos-arm64`, iOS 15+ | Build/install proof later |
| Dopamine iOS 15 arm64 research target | VERDE | Current Dopamine upstream includes iOS 15 in arm64 support range | Exact iPhone 6s Plus runtime confirmation |
| Dopamine systemhook process propagation | VERDE | Current source shows spawn-time systemhook injection architecture | Observe exact target device behavior |
| Dopamine -> `TweakLoader.dylib` loading | VERDE | Current systemhook source explicitly loads rootless TweakLoader when enabled | Confirm on exact installed Dopamine version |
| ElleKit rootless tweak loader/filter model | VERDE | Current source implements rootless TweakInject plus Bundles/Executables filtering | Confirm installed version/path on target |
| Generic `mobilesubstrate` dependency meaning | VERDE | ElleKit package explicitly provides `mobilesubstrate` compatibility | None for dependency interpretation |
| Public CoreMedia/CoreVideo types/APIs | VERDE | Apple public APIs plus both references | Target-specific format/lifetime proof |
| AVFoundation per-app sample callback semantics | VERDE | Apple public documentation + MotionCam source | Not a central-point proof |
| VideoToolbox API family | VERDE | Apple public framework docs and iOS16 symbols | A9 performance/behavior remains AMARELO |
| IOSurface cross-task transport capability | VERDE | Apple documents Mach-port/XPC representation | Actual VCAM data-plane ownership/synchronization remains AMARELO |
| Darwin notifications as control-plane primitive | AMARELO | iOS16 static evidence contains primitives | Names, delivery, races, target lifecycle |
| `mediaserverd` as central research target | AMARELO | iOS16 filter directly targets it; loader architecture makes daemon targeting plausible | Load/reachability proof on iOS 15.8.8 |
| Actual VCAM tweak load in `mediaserverd` | AMARELO | Mechanically plausible from current Dopamine/ElleKit source | Passive device load proof |
| Exact private hook symbol/class/selector | VERMELHO | Not identified with confidence | Static/runtime discovery for exact iOS 15.8.8 build |
| Private callback threading | VERMELHO | Unknown | Passive observation only |
| `CMSampleBuffer` callback ownership/lifetime at central point | VERMELHO | Public API rules exist, but central private callback contract is unknown | Passive observation + target contract characterization |
| `CVPixelBuffer` lifetime at central point | VERMELHO | Static use evidence only | Determine retain/release and pool reuse contract |
| Pixel format at central point | AMARELO | Static format-query/conversion evidence | Observe actual target formats |
| Frame dimensions at central point | AMARELO | Static width/height queries | Observe actual target dimensions |
| Timing/PTS contract at central point | VERMELHO | Not established | Passive observation of original frames |
| Safe frame substitution | VERMELHO | Required contracts above unresolved | Do not attempt in first proof |
| A9 performance for any central hook | AMARELO | Target selected; no runtime measurement | Device proof after passive safety gates |

---

## 7. Candidate injection-point comparison

| Candidate | Scope | Evidence | Technical advantages | Risks | State-sharing implications | Fail-open implications | Current compatibility | Proof required |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| A. Per-app AVFoundation sample-buffer callback | One injected consumer process at a time | MotionCam source + Apple public callback | Public callback semantics; lower blast radius; useful control experiment | Not system-wide; app coverage varies; duplicated state; callback must remain efficient | State is naturally process-local unless IPC is added | Easy to call original callback/frame in each app | Public API path is understood; architecture is not central | App-level device proof only if later needed as comparison |
| B. `mediaserverd` | Potentially central camera-service scope | iOS16 recovered filter explicitly targets daemon; current Dopamine/ElleKit architecture supports executable filtering | One central state boundary may cover multiple consumers; avoids per-app media/state duplication | Critical daemon; exact hook point/thread/lifetime unknown; failure can affect system camera | Central injector can consume one shared control/data-plane state later | Must default to no-op/original behavior on every uncertainty | **AMARELO**; strongest central evidence, no iOS15 runtime proof | Load -> passive reachability -> contract characterization |
| C. Other central point | Not established | No additional central point was identified with sufficient evidence | N/A | Inventing one would violate evidence discipline | N/A | N/A | UNKNOWN | Do not create a candidate merely to fill the table |

### Leading research candidate

**INFERENCE — LEADING RESEARCH CANDIDATE: `mediaserverd`**

Reason:

1. the iOS16 reference explicitly targets `mediaserverd`;
2. the same binary has strong CoreMedia/CoreVideo/VideoToolbox and hook-related static evidence;
3. current Dopamine + ElleKit sources make executable-filtered daemon tweak loading plausible in a rootless arm64 environment;
4. a daemon-level point is architecturally more central than the MotionCam per-app callback.

This does **not** make `mediaserverd` the final architecture.

**UNKNOWN**

The exact iOS 15.8.8 camera callback inside `mediaserverd` remains unidentified, so there is not yet enough evidence to write a frame-substitution hook safely.

---

## 8. Unresolved unknowns before functional code

The following remain hard technical unknowns:

1. exact `mediaserverd` binary/process identity and lifecycle on iOS 15.8.8 as seen on the target device;
2. whether a minimal filtered dylib actually loads successfully in that daemon under the installed Dopamine/ElleKit versions;
3. the exact private function/class/selector that sees the relevant camera video frame on iOS 15.8.8;
4. whether one callback covers all desired camera consumers or only a subset of capture modes;
5. callback thread/queue and reentrancy rules;
6. sample-buffer ownership and valid retain duration;
7. pixel-buffer ownership/pool reuse behavior;
8. actual width/height/pixel-format combinations on iPhone 6s Plus;
9. color attachments that consumers require;
10. presentation/decode timestamp expectations;
11. daemon behavior during camera start/stop, app switching, lock/unlock, and daemon restart;
12. any target-specific injection exclusions not visible from current upstream source alone.

Until these are resolved, frame substitution remains a hard stop.

---

## 9. Safe first runtime-proof design — future order only

This section designs the proof. **Nothing here is implemented by this research task.**

### Gate 0 — target identity and recovery preparation

Before any future test:

- record exact iOS build, Dopamine version, ElleKit version, target process path/name, and rootless loader paths;
- confirm a recovery path that can disable/remove only the test tweak without changing unrelated jailbreak state;
- confirm the real camera works before the proof.

If these are not known, stop.

### Gate 1 — LOAD proof

Goal: prove only that a minimal VCAM research dylib can be loaded into the candidate process.

Future proof properties:

- filter only the intended candidate process;
- constructor/init performs no hook and no camera modification;
- emit a single bounded proof marker containing process identity and proof build identifier;
- no media engine;
- no gallery;
- no IPC;
- no frame allocation;
- no frame substitution.

PASS requires:

- unambiguous evidence that the dylib loaded in `mediaserverd`;
- daemon remains alive/stable;
- ordinary camera consumers still work exactly as before;
- no unexpected crash/restart loop.

A daemon crash/restart is a FAIL, not a signal to keep retrying.

### Gate 2 — REACHABILITY / PASSIVE OBSERVATION

Only after the exact iOS 15.8.8 target callback/symbol is positively identified.

Future passive hook behavior:

- observe the candidate call;
- immediately preserve/original behavior;
- do not replace, mutate, delay, decode, scale, or retain frame data beyond documented/characterized lifetime;
- use bounded/rate-limited telemetry such as invocation count and non-sensitive structural metadata needed to establish format/timing;
- do not log frame contents.

PASS requires repeated camera start/stop cycles with:

- callback reachability proven;
- original camera output unchanged;
- no daemon crash/restart;
- no visible camera regression;
- no sustained blocking;
- enough observations to characterize thread/queue, buffer format, and timing.

If the exact callback is not positively identified, do **not** hook a guessed symbol.

### Gate 3 — hard stop before frame substitution

Frame substitution remains prohibited until all of the following have been proven:

- Gate 1 load proof passes repeatedly;
- Gate 2 passive reachability passes repeatedly;
- exact callback/thread context is known;
- sample-buffer and pixel-buffer ownership/lifetime rules are known;
- pixel formats and dimensions are characterized;
- timing expectations are characterized;
- original behavior remains intact with the passive hook;
- a deterministic fail-open path has been demonstrated;
- Supervisor explicitly authorizes the next proof.

### Recovery rule

If the candidate daemon crashes, restarts unexpectedly, or camera behavior changes:

1. mark the proof failed;
2. stop further injection attempts;
3. use the prepared Dopamine/ElleKit-safe recovery path to prevent the test tweak from loading again;
4. restore/confirm normal camera behavior;
5. collect only the minimal crash/log evidence required for diagnosis;
6. return to Supervisor review.

No crash loop is acceptable.

---

## 10. Fail-open contract

The previously approved fail-open contract remains unchanged.

**FACT / REQUIRED DESIGN CONTRACT**

- VCAM unavailable -> original behavior;
- state absent -> original behavior;
- unknown callback -> original behavior;
- observation/proof component absent -> original behavior;
- invalid/unrecognized buffer -> original behavior;
- late/stale future virtual frame -> real/original frame;
- error -> original behavior.

A future injector must never require `mediaserverd` or another camera pipeline to block while waiting for media, IPC, decode, or a virtual frame.

---

## 11. Explicit hard stops

Stop the next phase before frame substitution if any of the following is true:

- test dylib cannot load cleanly in the candidate process;
- candidate daemon crashes or restarts unexpectedly;
- exact callback/symbol remains ambiguous;
- passive hook changes real camera behavior;
- callback threading/reentrancy is unknown;
- sample-buffer or pixel-buffer lifetime is unknown;
- format/timing contract is unknown;
- proof requires proprietary implementation reconstruction;
- proof requires broad, unfiltered injection merely to “see what happens”;
- fail-open cannot be demonstrated;
- device state cannot be safely recovered;
- a conclusion depends only on the empty IOS-15-USB repository or on historical unverified claims.

---

## 12. Provenance / no-copy statement

VCAM PRO does not copy the proprietary iOS16 reference implementation.

This research used only:

- repository/package metadata;
- file/filter paths;
- public symbol names;
- classes/selectors/strings where statically visible;
- framework dependencies;
- current open-source upstream loader/hooking architecture;
- public Apple/Theos API documentation.

No proprietary dylib, disassembly-to-source translation, credentials, backend, commercial logic, anti-debug logic, or closed implementation was copied into VCAM PRO.

The future implementation must be original.

---

## 13. Sources

### Official upstream — Dopamine

- **[D1]** Dopamine README @ `1a54e76d515ff5916b64e44d6afbb57d2bc89ee9`  
  https://github.com/opa334/Dopamine/blob/1a54e76d515ff5916b64e44d6afbb57d2bc89ee9/README.md
- **[D2]** Dopamine `BaseBin/systemhook/src/common/common.c` @ same commit  
  https://github.com/opa334/Dopamine/blob/1a54e76d515ff5916b64e44d6afbb57d2bc89ee9/BaseBin/systemhook/src/common/common.c
- **[D3]** Dopamine `BaseBin/systemhook/src/main.c` @ same commit  
  https://github.com/opa334/Dopamine/blob/1a54e76d515ff5916b64e44d6afbb57d2bc89ee9/BaseBin/systemhook/src/main.c
- **[D4]** Dopamine `Application/Dopamine/Jailbreak/DOEnvironmentManager.m` @ same commit  
  https://github.com/opa334/Dopamine/blob/1a54e76d515ff5916b64e44d6afbb57d2bc89ee9/Application/Dopamine/Jailbreak/DOEnvironmentManager.m

### Official upstream — ElleKit

- **[E1]** ElleKit README @ `1017a0d09606ea49ba8bc4d6cccc530d372e640e`  
  https://github.com/tealbathingsuit/ellekit/blob/1017a0d09606ea49ba8bc4d6cccc530d372e640e/README.md
- **[E2]** ElleKit `packaging/control` @ same commit  
  https://github.com/tealbathingsuit/ellekit/blob/1017a0d09606ea49ba8bc4d6cccc530d372e640e/packaging/control
- **[E3]** ElleKit `Makefile` @ same commit  
  https://github.com/tealbathingsuit/ellekit/blob/1017a0d09606ea49ba8bc4d6cccc530d372e640e/Makefile
- **[E4]** ElleKit `packaging/postinst` @ same commit  
  https://github.com/tealbathingsuit/ellekit/blob/1017a0d09606ea49ba8bc4d6cccc530d372e640e/packaging/postinst
- **[E5]** ElleKit `injector/injector.c` @ same commit  
  https://github.com/tealbathingsuit/ellekit/blob/1017a0d09606ea49ba8bc4d6cccc530d372e640e/injector/injector.c
- **[E6]** ElleKit `launchd/Tweak.swift` @ same commit  
  https://github.com/tealbathingsuit/ellekit/blob/1017a0d09606ea49ba8bc4d6cccc530d372e640e/launchd/Tweak.swift

### Official documentation — Theos

- **[T1]** Rootless  
  https://theos.dev/docs/rootless
- **[T2]** Packaging  
  https://theos.dev/docs/packaging

### Official documentation — Apple

- **[A1]** AVFoundation — `captureOutput:didOutputSampleBuffer:fromConnection:`  
  https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutputsamplebufferdelegate/captureoutput(_:didoutput:from:)
- **[A2]** CoreMedia — `CMSampleBufferGetImageBuffer`  
  https://developer.apple.com/documentation/coremedia/cmsamplebuffergetimagebuffer(_:)
- **[A3]** VideoToolbox  
  https://developer.apple.com/documentation/videotoolbox
- **[A4]** IOSurface functions / Mach-port transport  
  https://developer.apple.com/documentation/iosurface/iosurface-functions

### READ ONLY project references

- **[R1]** `martaxi-boss/MotionCam-iOS` @ `5ede3a1973a01cb13fe7f3ab562b47513feec1b1` — `Tweak.xm`, `MediaManager.m`, `VCam.plist`
- **[R2]** `martaxi-boss/IOS-16-USB-4k` @ `cc20d787070c67565173d4a46c218e2549cecc93` — package metadata, recovered filter, Mach-O dependency/symbol/metadata/string analysis
- **[R3]** `martaxi-boss/IOS-15-USB` — current GitHub repository empty

---

## Research conclusion

**FACT**

A per-app AVFoundation callback is documented and demonstrated by MotionCam, but it is process-local.

**FACT**

The iOS16 reference intentionally filters for `mediaserverd` and contains substantial frame-buffer / VideoToolbox / hook static evidence.

**FACT**

Current Dopamine + ElleKit upstream sources provide a rootless arm64 process/tweak loader architecture capable of executable-filtered tweak loading in principle.

**INFERENCE**

`mediaserverd` is therefore the **LEADING RESEARCH CANDIDATE** for a central proof on iOS 15.8.8.

**UNKNOWN**

The exact iOS 15.8.8 frame callback and its threading/lifetime/format/timing contract are not yet known.

Therefore the next authorized functional phase, if approved by the Supervisor, should be a **LOAD / REACHABILITY / PASSIVE OBSERVATION PROOF only**. Frame substitution must remain prohibited until that proof passes and the unknown contracts are resolved.
