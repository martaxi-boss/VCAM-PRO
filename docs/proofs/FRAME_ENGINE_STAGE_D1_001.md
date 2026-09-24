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

`82f3a1a13e9a9baa79f2b7528e3f096f8eef9804`

Final documentation/state reconciliation is validated again by pull_request CI on the final branch head.

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

The ordinary H.264 fixture decodes with color metadata present, so it cannot prove missing-metadata rejection.

The production pump therefore factors its already-used frame-processing path into a private helper called by `pumpOnce()`. A test-only friend invokes that same private path with an in-memory 420v PreparedFrame with no:
- color primaries
- transfer function
- YCbCr matrix

Target policy:

`ColorMetadataPolicy::RequirePresent`

Observed result:
- NormalizationRejected
- MissingRequiredColorMetadata
- TransformRequirement::None
- queue unchanged

No public API was added for this test seam.

A short test-only JPEG fixture exploration was added and then removed again because it was redundant; final proof relies on the deterministic in-memory missing-metadata frame.

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

Canonical functional Run #4:

`36072914281`

Head:

`82f3a1a13e9a9baa79f2b7528e3f096f8eef9804`

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

Canonical functional Run #4:

`36072914281`

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

Run #1:
`36072570380`

Result:
- A/B/C1 PASS
- D1 compiled
- 18 / 19 D1 tests PASS
- RequirePresent missing-metadata fixture assumption failed because H.264 decode contained metadata

Deterministic D1-local fix:

`1cd867a00f26a6124c6693a69d03c642068b949b`

Run #2:
`36072732048` — SUCCESS

Additional test-only fixture exploration:
- `bc0c580a42d51b37fe6f5ca8286b690c73b673bb`
- `82f3a1a13e9a9baa79f2b7528e3f096f8eef9804`

The redundant metadata-sparse file fixture was removed; the deterministic in-memory test remains the final proof.

Run #4:
`36072914281` — SUCCESS

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

`10838264071`

Digest:

`sha256:c3e8cda4cecb97483a22cf6d600957d7db16080762301de07ba193c11761cf29`

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
