# VCAM PRO — Frame Engine Stage D1 Proof 001

## Status

**STAGE D1 — LOCAL PRODUCER PIPELINE COMPOSITION: BUILD + HOST TEST PASS**

**DEVICE NOT USED**

**NO PIXEL TRANSFORM**

**NO PRODUCER SCHEDULER**

**NO CAMERA TIMING**

**NO PRODUCTION CVPIXELBUFFERPOOL**

**NO INJECTOR**

**FRAME SUBSTITUTION PROHIBITED**

---

## 1. Exact baseline

Approved main:

`01895cac4dcf2f530d2c42feba4942449a3f97bb`

Branch:

`builder/frame-engine-stage-d1-001`

Contract:

`docs/design/FRAME_ENGINE_CONTRACT_001.md`

Contract blob:

`d34bb302d2c5d077119651a5053cc68fb105b1e9`

Existing Stage A/B/C1 production source remained unchanged.

Latest functional tested head:

`3fcd802f54c874fb49825448fbe16b1826605181`

Final cleanup/evidence reconciliation is validated again by pull_request CI on the final branch head. The proof records the latest functional tested SHA; the terminal Builder return records the immutable final-head SHA/run metadata to avoid a self-referential commit loop.

---

## 2. File set

Production:
- `src/media_engine/FramePipelinePump.h`
- `src/media_engine/FramePipelinePump.cpp`

Tests:
- `tests/media_engine/frame_pipeline_stage_d1_tests.mm`

CI:
- `.github/workflows/frame-engine-stage-d1-ci.yml`

Evidence/state:
- `docs/proofs/FRAME_ENGINE_STAGE_D1_001.md`
- `PROJECT_STATE.md`

---

## 3. Composition architecture

Stage D1 composes only approved public components:

`LocalVideoReader -> FrameNormalizer -> ReadyFrameQueue`

`FramePipelinePump` receives explicit references to:
- `FrameEngineState`
- `LocalVideoReader`
- `FrameNormalizer`
- `ReadyFrameQueue`

and a caller-supplied `NormalizationTarget`.

No singleton or global mutable state exists.

---

## 4. pumpOnce semantics

Primary API:

`FramePipelinePump::pumpOnce()`

Each call performs at most:
- one `LocalVideoReader::readNext()`
- one `FrameNormalizer::prepare()`
- one `ReadyFrameQueue::publish()`

CI statically verifies exactly one direct call site for each operation.

The pump contains:
- no recursion
- no internal frame loop
- no sleep/retry
- no producer thread
- no scheduler
- no condition-variable worker

The source explicitly documents that a future camera/injector callback must never call `pumpOnce()`.

Future consumer path remains:

`ReadyFrameQueue::tryAcquire()`

---

## 5. Result mapping

Pipeline status distinguishes:
- Published
- TransformRequired
- QueueDropped
- EndOfStream
- LoopRestarted
- NotReady
- ReaderFailed
- Cancelled
- NormalizationRejected

Reader mapping:
- EndOfStream -> EndOfStream
- LoopRestarted -> LoopRestarted
- NotReady -> NotReady
- Failed -> ReaderFailed
- Cancelled -> Cancelled

Reader failure is not collapsed into EOS.

Normalizer mapping:
- ReadyPassthrough -> queue publish
- TransformRequired -> TransformRequired with exact requirement preserved
- InvalidFrame / GenerationMismatch / TimelineMismatch / UnsupportedTarget / MissingRequiredColorMetadata -> NormalizationRejected

Queue mapping:
- Published -> Published
- DroppedInvalid / DroppedStale / DroppedFullLeased -> QueueDropped with exact publish result preserved

Every non-Published result means:

**NO NEW VIRTUAL FRAME**

Future injector consequence remains:

**REAL CAMERA FALLBACK**

---

## 6. Queue context

Publish uses:
- current mediaGeneration
- current timelineEpoch
- minimumSequence unset

No temporal staleness window is invented.

No camera clock or camera PTS is created.

---

## 7. Compatible-frame path

For `ReadResultKind::Frame`:
1. SourceVideoInfo supplies naturalSize and preferredTransform.
2. SourceGeometry is built from those values.
3. Current generation/epoch come from FrameEngineState.
4. FrameNormalizer performs admission.
5. Only ReadyPassthrough can publish.
6. The admitted PreparedFrame is moved into ReadyFrameQueue.

No pixel data is modified.

---

## 8. Timing / identity proof

For an admitted published frame the pump result records the exact:
- FrameIdentity
- FrameTiming

before queue ownership transfer.

The first deterministic source frame has:

`sourcePTS == kCMTimeZero`

The acquired queue lease exposes the same FrameIdentity:
- sequence
- mediaGeneration
- timelineEpoch

Stage A FrameLease intentionally does not expose timing, so D1 correlates the published sourcePTS to the acquired lease through the exact preserved FrameIdentity without modifying Stage A.

---

## 9. Consumer fast-path proof

A dedicated test performs producer publication first.

The consumer section then calls only:

`ReadyFrameQueue::tryAcquire(context)`

No reader, normalizer, or pump call occurs during acquisition.

Result:

**PASS**

---

## 10. Transform-required behavior

Host tests prove:
- width mismatch -> TransformRequired / Size
- height mismatch -> TransformRequired / Size
- pixel-format mismatch -> TransformRequired / PixelFormat
- non-identity preferredTransform -> TransformRequired / Orientation

In every case:
- queue remains unchanged
- no virtual frame is published
- no transform API is called

---

## 11. RequirePresent rejection

The ordinary encoded H.264 fixture decodes with complete color metadata on the GitHub-hosted macOS runner, even when source-buffer color attachments are removed before writing. A diagnostic run observed:

- color primaries present = 1
- transfer function present = 1
- YCbCr matrix present = 1

Therefore D1 uses a separate deterministic **test-only passthrough local MOV fixture** for the negative RequirePresent path.

That fixture is created with:

- 420v CVPixelBuffers;
- no color primaries attachment;
- no transfer-function attachment;
- no YCbCr-matrix attachment;
- `AVAssetWriterInput(outputSettings:nil, sourceFormatHint:...)`;
- CMSampleBuffer append without an H.264 encode step;
- no download and no network.

The fixture is then opened through the real `LocalVideoReader`, and the test calls the real `FramePipelinePump::pumpOnce()`.

Run #14 observed from the decoded source frame:

- color primaries present = 0
- transfer function present = 0
- YCbCr matrix present = 0

Target policy:

`ColorMetadataPolicy::RequirePresent`

Observed pipeline result:

- `FramePipelinePumpStatus::NormalizationRejected`;
- `NormalizationStatus::MissingRequiredColorMetadata`;
- `TransformRequirement::None`;
- queue unchanged;
- no output frame published.

This is a full local-file reader -> pump -> normalizer admission -> no-publish proof for the missing-metadata path.

No test-only production API or friend access is required.

---

## 12. Reader terminal/failure behavior

Host tests prove:
- loop-disabled completion -> EndOfStream, no new publish
- loop-enabled completion -> LoopRestarted
- stopped reader -> Cancelled
- a deterministic reader-state failure path -> ReaderFailed, not EOS

No terminal/failure path manufactures a frame.

---

## 13. Bounded queue / all-leased behavior

Capacity-1 tests prove:
- repeated compatible publication never grows queue above capacity
- holding the only entry leased causes the next compatible publication to return:
  - QueueDropped
  - DroppedFullLeased

The producer does not wait.
The held lease remains valid.

---

## 14. Generation / epoch invalidation

Media replacement:
- old frame published
- replacement media increments mediaGeneration
- acquire under new context rejects/purges old queued frame

Timeline change:
- frame published
- pause/resume advances timelineEpoch
- acquire under new epoch rejects/purges old queued frame

Both PASS.

---

## 15. Stage D1 tests

Canonical functional pull_request Run #14:

`36073999128`

Head:

`3fcd802f54c874fb49825448fbe16b1826605181`

Result:

**19 / 19 PASS — 0 failures**

Coverage:
1. compatible 420v publishes/acquires
2. compatible 420f publishes/acquires
3. published sourcePTS correlates with acquire
4. identity survives complete pipeline
5. pixel buffer remains valid through queue lease
6. width mismatch -> transform required
7. height mismatch -> transform required
8. pixel-format mismatch -> transform required
9. non-identity transform -> transform required
10. RequirePresent missing metadata -> no publish
11. EOS without loop -> no publish
12. LoopRestarted propagated
13. Cancelled propagated
14. ReaderFailed propagated
15. queue remains bounded
16. fully leased queue drops without blocking
17. media replacement invalidates queued generation
18. timeline epoch invalidates queued frame
19. consumer fast path is queue only

---

## 16. Regression matrix

Canonical functional pull_request Run #14:

`36073999128`

Stage A:
**13 / 13 PASS**

Stage B:
**10 / 10 PASS**

Stage C1 queue:
**18 / 18 PASS**

Stage C1 normalizer:
**17 / 17 PASS**

Stage D1:
**19 / 19 PASS**

---

## 17. Iteration history

Initial implementation:

`e78c0aef4917acd7784be86575a5bf1948db8754`

Run #1 / `36072570380`:

- A/B/C1 PASS;
- D1 compiled;
- 18 / 19 D1 tests PASS;
- the initial RequirePresent negative fixture assumption failed because decoded H.264 carried color metadata.

Early D1-local remediation/exploration commits:

- `1cd867a00f26a6124c6693a69d03c642068b949b`;
- `bc0c580a42d51b37fe6f5ca8286b690c73b673bb`;
- `82f3a1a13e9a9baa79f2b7528e3f096f8eef9804`.

Run #4 / `36072914281` reached 19 / 19 using a deterministic composition-boundary missing-metadata frame.

A stricter end-to-end remediation then required the negative case to pass through the real local reader and `pumpOnce()`:

- `b28704bb3f84416c0dbe6eca914d54b9b2c7b2b6` — switched the RequirePresent test toward the real local pipeline;
- `c174227eb2e55fca2167a399c9b0701d2387eddc` — removed the superseded in-memory helper;
- `c097b923e64c22ab3bd5528930076b1db6505f82` — recorded that H.264 decode still returned primaries/transfer/matrix as present;
- `3fcd802f54c874fb49825448fbe16b1826605181` — added a passthrough 420v local MOV fixture without color tags.

Final functional pull_request Run #14 / `36073999128`:

**SUCCESS**

Results:

- Stage A: 13 / 13 PASS;
- Stage B: 10 / 10 PASS;
- Stage C1 queue: 18 / 18 PASS;
- Stage C1 normalizer: 17 / 17 PASS;
- Stage D1: 19 / 19 PASS;
- RequirePresent missing-metadata local pipeline: PASS;
- iOS arm64 compile: PASS;
- minimum iOS: 15.0;
- negative checks: PASS.

No history rewrite was used.

---

## 18. iOS arm64 compile

Archive:

`libVCAMFrameEngineStageD1.a`

Production objects:
- PreparedFrame.o
- FrameEngineState.o
- LocalVideoReader.o
- ReadyFrameQueue.o
- FrameNormalizer.o
- FramePipelinePump.o

Architecture:

**arm64**

Minimum iOS on FramePipelinePump:

**15.0**

arm64e:

**NOT PRESENT**

---

## 19. Artifact

Functional artifact:

`vcam-frame-engine-stage-d1-static`

Artifact ID:

`10839920201`

Digest:

`sha256:af147e51d89ab3fb2e9f84ae1bdd66b5de1d4701e51fa4180a202b69305786b4`

CI-only; not a release.

---

## 20. Forbidden boundary

Stage D1 production checks reject:
- VTDecompression
- VTPixelTransfer
- VTPixelRotation
- VideoToolbox transform use
- CoreImage
- Metal
- vImage / Accelerate transforms
- AVCapture
- Photos
- UIKit
- MSHookFunction
- MSHookMessageEx
- mediaserverd
- NSURLSession
- socket/network APIs
- CVPixelBufferPool
- std::thread
- dispatch worker construction
- display-link/host-time scheduling

Expected Stage B AVAssetReader references remain present in the combined archive.

Result:

**PASS**

---

## 21. Explicit non-effects

Stage D1 did not:
- modify Stage A/B/C1 production source
- modify the Frame Engine contract
- rotate/scale/crop pixels
- convert 420v/420f
- select a transform primitive
- create production CVPixelBufferPool
- create a producer scheduler
- create camera timing
- implement injector integration
- access mediaserverd
- touch the iPhone
- substitute camera frames

---

## 22. Device/runtime state

**DEVICE GATE: HOLD — AWAITING PHYSICAL DEVICE**

**MEDIASERVERD LOAD: NOT YET PROVEN**

**FRAME SUBSTITUTION: PROHIBITED**

**IOS 15.8.8 RUNTIME: NOT YET PROVEN**

**A9 720P30 DEVICE PERFORMANCE: NOT YET MEASURED**

**PUBLIC RELEASE: NO**

---

## 23. References

READ ONLY and unchanged:
- MotionCam-iOS @ `5ede3a1973a01cb13fe7f3ab562b47513feec1b1`
- IOS-15-USB — EMPTY
- IOS-16-USB-4k @ `cc20d787070c67565173d4a46c218e2549cecc93`

---

## 24. Result

**FRAME ENGINE IMPLEMENTATION: STAGE D1 — LOCAL PRODUCER PIPELINE COMPOSITION**

**LOCAL PRODUCER PIPELINE: AVASSETREADER -> NORMALIZATION ADMISSION -> READY QUEUE — BUILD/HOST TEST PASS**

**NORMALIZATION: ADMISSION + PASSTHROUGH ONLY**

**PIXEL TRANSFORMS: NOT STARTED**

**PRODUCER SCHEDULER: NOT STARTED**

**CAMERA TIMING: UNKNOWN / NOT STARTED**

**CVPIXELBUFFERPOOL: NOT STARTED / DEFERRED TO MEASUREMENT**

**DEVICE GATE: HOLD — AWAITING PHYSICAL DEVICE**

**FRAME SUBSTITUTION: PROHIBITED**

**PUBLIC RELEASE: NO**

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

