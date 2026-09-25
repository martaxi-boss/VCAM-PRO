# VCAM PRO — Frame Engine Stage D2 001

## Scope

**VALIDATION ONLY. PRODUCTION SOURCE UNCHANGED.**

Stage D2 attempts to falsify the already-integrated Frame Engine invariants without adding product functionality and without using the target device.

Exact approved base:

`e080c21028db3d6420dc771e6b82303111227c30`

Branch:

`builder/frame-engine-stage-d2-001`

Validated pre-documentation head:

`fa5808ff6cb79896d02faf4bc43d8073676eeb6c`

Canonical validation run for that head:

- GitHub Actions Run ID: `36120770707`
- event: `push`
- result: **SUCCESS**
- artifact name: `vcam-frame-engine-stage-d2-validation`
- artifact ID: `10858420273`
- artifact digest: `sha256:018703cbb0eb1a3097f8251d38568c34c609e24f552c4d814dd664b5dd1cc01a`

Final PR validation after documentation/state reconciliation:

- GitHub Actions Run ID: `36121381148`
- event: `pull_request`
- head: `1249b5073096527c74e33fbb7b06da43acf9df57`
- result: **SUCCESS**
- artifact name: `vcam-frame-engine-stage-d2-validation`
- artifact ID: `10858126450`
- artifact digest: `sha256:2826553506b1b907d64ad1c59c5ae5645a66fbeaa41eb72049dbb5f914579c4d`

The same head also received successful Stage A, Stage B, Stage C1, and Stage D1 pull-request workflows.

## Production blob lock

The D2 CI records and checks these exact Git blobs at both the start and end of the run:

| Production file | Locked blob |
| --- | --- |
| `src/frame_engine/PreparedFrame.h` | `54ef2dcf4479756cec3e76dfecf5b67fd3e679af` |
| `src/frame_engine/PreparedFrame.cpp` | `8bf72637c70b91c9d1f56af6ca0d63c0beadfe4b` |
| `src/frame_engine/FrameEngineState.h` | `ed003b56c6ad6fa4252471bd82c1bd757c4e8433` |
| `src/frame_engine/FrameEngineState.cpp` | `996beb57cffb71e31d9a7c896af6637dff137e7a` |
| `src/frame_engine/ReadyFrameQueue.h` | `b7afe3ab62a63cfc580528ee2c92280797779f18` |
| `src/frame_engine/ReadyFrameQueue.cpp` | `efa8583e9770807aae9b33affd927b3aa8c0d525` |
| `src/media_engine/LocalVideoReader.h` | `b390c57ef6a0ae9874adb6e85e4ae6301da94869` |
| `src/media_engine/LocalVideoReader.mm` | `1c4f99f8b3bfa37f9e41424cb31de7bddc9dfcea` |
| `src/media_engine/FrameNormalizer.h` | `e2a77f0124fca0246a88ce9db7289f1fda50d75f` |
| `src/media_engine/FrameNormalizer.cpp` | `b3b5bdd6896a04528565676330b78235da1137b6` |
| `src/media_engine/FramePipelinePump.h` | `b917f7c08d769f78243b85c2aa09aaa9d9679a76` |
| `src/media_engine/FramePipelinePump.cpp` | `ff0e01f7a2cff1af042ae355faba032faeea5304` |

Result:

**PRODUCTION SOURCE CHANGED = NO**

Frame Engine contract blob remained:

`d34bb302d2c5d077119651a5053cc68fb105b1e9`

## Regression matrix

Run `36120770707` validated:

| Suite | Result |
| --- | --- |
| Stage A | **13 / 13 PASS** |
| Stage B | **10 / 10 PASS** |
| Stage C1 queue | **18 / 18 PASS** |
| Stage C1 normalizer | **17 / 17 PASS** |
| Stage D1 | **19 / 19 PASS** |
| D2 consumer isolation | **5 / 5 PASS** |
| D2 queue/concurrency stress | **8 / 8 PASS** |
| D2 pipeline soak / fail-open / 720p30 smoke | **5 / 5 PASS** |

## Consumer isolation architecture

The dedicated consumer slice test compiles and links only:

- `PreparedFrame.cpp`
- `ReadyFrameQueue.cpp`
- `consumer_fast_path_stage_d2_tests.cpp`

The critical consumer operation remains:

`ReadyFrameQueue::tryAcquire()`

The consumer test covers:

- publish and acquire;
- valid queue lease;
- live `CVPixelBuffer`;
- Empty;
- NoEligibleFrame;
- generation mismatch;
- epoch mismatch;
- minimumSequence stale rejection.

It does not compile or link:

- `LocalVideoReader`;
- `FrameNormalizer`;
- `FramePipelinePump`;
- AVFoundation.

## iOS consumer fast-path archive

CI creates:

`libVCAMConsumerFastPathD2.a`

Archive production object members:

- `PreparedFrame.o`
- `ReadyFrameQueue.o`

The archive symbol table `__.SYMDEF` is metadata, not a production object.

Observed architecture:

**Mach-O object members arm64 / non-fat archive arm64**

Minimum iOS:

**15.0**

arm64e:

**NO**

Consumer undefined-symbol inspection showed no:

- AVFoundation / AVAssetReader;
- LocalVideoReader;
- FrameNormalizer;
- FramePipelinePump;
- VideoToolbox transforms;
- AVCapture;
- MSHookFunction / MSHookMessageEx;
- mediaserverd;
- NSURLSession / socket / Network.framework APIs.

Allowed CoreFoundation/CoreMedia/CoreVideo/C++ runtime dependencies remain expected.

Therefore:

**CONSUMER AVFOUNDATION DEPENDENCY = NONE IN D2 CONSUMER ARCHIVE**

## Queue stress

Test capacities are fixtures only:

`1, 2, 3, 8`

They are not product capacity selections.

Validated operations include:

- 2,500 publish/acquire cycles per listed capacity;
- queue size never exceeding capacity;
- 1,000 repeated `DroppedFullLeased` attempts while all three entries are leased;
- release of leases followed by successful reclamation/publish;
- 500 generation churn rounds;
- 500 epoch churn rounds;
- 200 minimumSequence churn rounds;
- outstanding lease remains valid after generation purge;
- 10,000 fail-fast Empty acquires;
- stale minimumSequence returns NoEligibleFrame;
- no synthetic frame is produced.

Result:

**QUEUE STRESS = HOST PASS**

## Concurrency stress

Dedicated ReadyFrameQueue/PreparedFrame-only concurrent test:

- one producer `std::thread`;
- one consumer `std::thread`;
- fixed queue capacity: 8;
- fixed operation count: 150,000;
- fixed generation/epoch;
- no LocalVideoReader in consumer thread.

Validated:

- no deadlock/hang;
- queue never exceeds capacity;
- acquired frames match expected generation/epoch;
- acquired leases remain valid;
- producer accepts normal publish or fail-open `DroppedFullLeased`;
- consumer observes the non-blocking `tryAcquire` API and can observe Contended.

Result:

**CONCURRENCY STRESS = HOST PASS**

The test-only threads do not establish or authorize a production scheduler.

## Pipeline soak

Producer-side soak uses the integrated public APIs:

`LocalVideoReader -> FramePipelinePump -> FrameNormalizer -> ReadyFrameQueue`

Deterministic local fixtures exercise:

- 20 open/start/EOS/reopen cycles;
- media replacement and generation churn;
- 40 replacement/epoch churn cycles;
- 25 explicit loop restarts;
- stop/reopen;
- frame ownership and queue leases;
- fail-open results.

No network and no device are used.

Result:

**PIPELINE SOAK = HOST PASS**

## Fail-open matrix

D2 repeatedly validates that these conditions do not create a new virtual frame:

- queue Empty;
- generation mismatch;
- epoch mismatch;
- stale minimumSequence;
- fully leased queue / `DroppedFullLeased`;
- TransformRequired;
- MissingRequiredColorMetadata;
- EndOfStream;
- Cancelled reader;
- ReaderFailed.

No test observes:

- black fallback;
- synthetic duplicate frame;
- blocking retry;
- busy loop.

## 720p30 host smoke

A deterministic TEST-ONLY H.264 fixture is generated at:

- 1280 x 720;
- 30 fps;
- 30 frames.

The current passthrough path completes:

`local file -> AVAssetReader -> PreparedFrame -> normalization admission -> ReadyFrameQueue`

Validated:

- all 30 frames published/acquired;
- queue remains bounded;
- source PTS remains valid and non-decreasing;
- EOS is reached;
- no synthetic frame is produced.

Result:

**720P30 HOST SMOKE = PASS — NOT DEVICE PERFORMANCE PROOF**

This does **not** prove:

- A9 real-time performance;
- iPhone 6s Plus performance;
- thermal behavior;
- device 720p30;
- production queue capacity;
- production buffer-pool capacity.

`A9 720P30 DEVICE PERFORMANCE` remains:

**NOT YET MEASURED**

## ASan / UBSan

Required pure-C++ ownership/queue stress was compiled and run with:

- AddressSanitizer;
- UndefinedBehaviorSanitizer;
- `halt_on_error=1`.

Result:

**PASS**

The full local pipeline was also compiled and run with ASan/UBSan after the D2 fixture harness stopped using `CVPixelBufferPoolCreatePixelBuffer` for fixture allocation and used direct `CVPixelBufferCreate` instead.

Why this harness change was required:

An earlier D2 run aborted inside Apple's `CVPixelBufferPoolCreatePixelBuffer -> objc_msgSend` while constructing the TEST fixture, before the Frame Engine began processing it. The stack was in CoreVideo/Objective-C runtime, not in VCAM PRO production code. The validator changed only the test fixture allocator and reran the same production source under sanitizers.

Final full-pipeline sanitizer result on Run `36120770707`:

**ASAN / UBSAN = PASS**

No sanitizer suppression was added.

## ThreadSanitizer

The current macOS runner/toolchain successfully built and ran the ReadyFrameQueue concurrency stress with ThreadSanitizer.

Run `36120770707`:

- TSan build: supported;
- queue/concurrency stress: 8 / 8 PASS;
- TSan runtime result: **PASS**;
- no race report observed.

Therefore:

**TSAN = PASS**

This is host validation only and not an iOS runtime/device claim.

## Full engine iOS archive

CI creates:

`libVCAMFrameEngineStageD2.a`

Production objects:

- `PreparedFrame.o`
- `FrameEngineState.o`
- `LocalVideoReader.o`
- `ReadyFrameQueue.o`
- `FrameNormalizer.o`
- `FramePipelinePump.o`

All observed production objects are:

**Mach-O 64-bit arm64**

Archive architecture:

**arm64**

Minimum iOS:

**15.0**

arm64e:

**NO**

The full-engine archive still references the expected Stage B AVAssetReader symbols.

No forbidden transform/injector/network production symbol was observed by the D2 CI negative checks.

## Static validation

D2 rechecks that integrated production source does not introduce:

- producer `std::thread`;
- condition-variable worker;
- dispatch worker/timer;
- display-link scheduler;
- CACurrentMediaTime retiming;
- CMSampleBuffer timestamp rewrite;
- VideoToolbox transform;
- CoreImage / Metal / vImage transform;
- production CVPixelBufferPool;
- AVCapture injection;
- private hook APIs;
- network APIs;
- mediaserverd coupling.

Result:

**PASS**

## Reference repositories

References remained strict READ ONLY:

- `martaxi-boss/MotionCam-iOS` @ `5ede3a1973a01cb13fe7f3ab562b47513feec1b1`
- `martaxi-boss/IOS-15-USB` = **EMPTY**
- `martaxi-boss/IOS-16-USB-4k` @ `cc20d787070c67565173d4a46c218e2549cecc93`

## Explicit limitations

- DEVICE NOT USED.
- NOT A9 PERFORMANCE PROOF.
- iOS 15.8.8 runtime is NOT YET PROVEN.
- mediaserverd load is NOT YET PROVEN.
- NO PIXEL TRANSFORMS.
- NO transform primitive selected.
- NO producer scheduler.
- NO camera timing.
- NO production CVPixelBufferPool.
- NO injector.
- NO frame substitution.
- NO release/deployment.
- Stage C2 is NOT authorized by this validation.

## Terminal validation conclusion

Stage D2 found no production defect in the tested non-device invariants.

The evidence supports only non-device host/build validation. It does not advance Gate 1 and does not prove the target-device runtime.

**DEVICE GATE = HOLD — AWAITING PHYSICAL DEVICE**

---

## Current reference / device-policy superseding note — 2026-09-25

The historical statements above remain part of this proof record and describe the state when this proof was executed. In particular, statements that `IOS-15-USB` was empty and that the target device was not used are preserved as historical facts for this proof.

Subsequently, `martaxi-boss/IOS-15-USB` was populated as a historical READ-ONLY archive. Current reference HEAD:

`a908bccbcddb4efc072bb1bc8fbeb6ee89b1af9d`

Current project policy is:

- **STATIC FACTS -> GitHub/reference artifacts**
- **RUNTIME FACTS -> real iPhone only**
- **Gate 1 — LOAD**
- **Gate 2 — PASSIVE CONTRACT OBSERVATION**, only after Gate 1 PASS
- **Gate 3 — MINIMAL SAFE SUBSTITUTION**, only after Gate 2 PASS, with mandatory fail-open

Real-device preparation has begun, but Gate 1 load in `mediaserverd` remains **NOT YET PROVEN**.

This note does not change this proof's original result, does not convert host/build evidence into device evidence, and does not authorize substitution.

