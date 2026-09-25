# VCAM PRO — Frame Engine Stage C1 Proof 001

## Status

**STAGE C1 — BOUNDED READY QUEUE / NORMALIZATION ADMISSION: BUILD + HOST TEST PASS**

**DEVICE NOT USED**

**A9 720P30 DEVICE PERFORMANCE NOT MEASURED**

**NO PIXEL TRANSFORM**

**NO PRODUCTION CVPIXELBUFFERPOOL**

**NO INJECTOR**

**FRAME SUBSTITUTION PROHIBITED**

---

## 1. Exact baseline

Approved main baseline:

`f6a5089d6d3b27c53e2b394fe2c5fabb0e221280`

Branch:

`builder/frame-engine-stage-c1-001`

Approved contract:

`docs/design/FRAME_ENGINE_CONTRACT_001.md`

Contract blob:

`d34bb302d2c5d077119651a5053cc68fb105b1e9`

The contract was not modified.

Stage A and Stage B production source were not modified.

Functional + CI-tested Stage C1 head:

`dbe825c608ae9f175a0492d5386c770cf33dec54`

The final documentation/state reconciliation commit is reported by PR metadata and the terminal Builder return. A commit cannot embed its own SHA in its own content without changing that SHA.

---

## 2. Stage C decomposition rationale

The approved contract defines Stage C as including:

- explicit orientation state;
- target-size policy;
- target pixel-format parameter;
- color metadata handling;
- bounded Ready Frame Queue;
- measured buffer reuse/pool if justified.

The same contract keeps VTPixelTransferSession and VTPixelRotationSession as candidate-only until target behavior is proven.

Because the physical iOS 15.8.8 target is not available, Stage C1 deliberately implements only:

1. bounded Ready Frame Queue;
2. explicit normalization target;
3. normalization admission;
4. zero-copy passthrough when no pixel transform is needed.

Stage C1 does not select or implement a pixel transform primitive.

---

## 3. File set

Production:

- `src/frame_engine/ReadyFrameQueue.h`
- `src/frame_engine/ReadyFrameQueue.cpp`
- `src/media_engine/FrameNormalizer.h`
- `src/media_engine/FrameNormalizer.cpp`

Tests:

- `tests/frame_engine/ready_frame_queue_stage_c1_tests.cpp`
- `tests/media_engine/frame_normalizer_stage_c1_tests.cpp`

CI:

- `.github/workflows/frame-engine-stage-c1-ci.yml`

Evidence/state:

- `docs/proofs/FRAME_ENGINE_STAGE_C1_001.md`
- `PROJECT_STATE.md`

No Stage A/B production implementation file was changed.

No Stage A/B workflow was changed.

---

## 4. ReadyFrameQueue capacity contract

`ReadyFrameQueue` is created with an explicit caller-supplied capacity.

Rules:

- capacity must be greater than zero;
- zero capacity is rejected;
- capacity never grows dynamically;
- tests use small capacities only as fixtures;
- no product capacity is selected by Stage C1.

A9 optimal queue capacity remains:

**NOT YET MEASURED**

---

## 5. Queue ownership

Every queue entry owns a full `PreparedFrame`.

The queue does not store:

- borrowed CVPixelBuffer storage;
- CMSampleBuffer;
- decoder-owned raw pointers.

PreparedFrame continues to own its CVPixelBuffer according to the Stage A ownership contract.

Removing an entry releases the queue's PreparedFrame ownership normally.

---

## 6. Consumer lease tracking

`ReadyFrameLease` encapsulates a Stage A `FrameLease`.

Logical queue tracking is separate from Core Foundation/Core Video retain counts.

Each queue entry has explicit atomic logical state:

- leased;
- consumed.

The implementation does not use `CFGetRetainCount`.

A ReadyFrameLease:

- owns its own FrameLease;
- keeps CVPixelBuffer storage alive;
- can survive removal of the queue entry;
- marks the logical entry consumed/released automatically on destruction.

An outstanding lease remains valid after generation/epoch purge removes its queue entry.

---

## 7. Non-blocking consumer proof

Consumer acquisition is:

`tryAcquire(context)`

The consumer path uses:

`std::mutex + std::try_to_lock`

It does not:

- wait for producer;
- wait for decode;
- wait for refill;
- sleep;
- spin;
- retry.

If the queue mutex is already owned, acquisition returns immediately as:

`AcquireResultKind::Contended`

A dedicated host test holds the bookkeeping mutex and confirms the consumer returns Contended rather than waiting for the lock.

---

## 8. Acquire result model

Acquisition distinguishes:

- Acquired
- Empty
- NoEligibleFrame
- Contended

Every non-Acquired state means:

**NO VIRTUAL FRAME**

No synthetic frame or black frame is generated.

Future injector fail-open consequence remains:

**REAL CAMERA FALLBACK**

No injector exists in C1.

---

## 9. Acquire context / staleness

`QueueContext` includes:

- currentMediaGeneration;
- currentTimelineEpoch;
- optional minimumSequence.

`minimumSequence` is caller-defined.

Stage C1 does not invent:

- millisecond stale windows;
- camera timing;
- camera timebase mapping.

Frames below the supplied sequence boundary are stale/ineligible.

---

## 10. Generation / epoch filtering

A frame is queue-eligible only if:

- validity is Ready;
- PreparedFrame invariants hold;
- orientation state is Normalized;
- mediaGeneration matches;
- timelineEpoch matches;
- sequence is not below optional minimumSequence.

Context cleanup deterministically purges obsolete entries.

Explicit APIs also exist to purge by:

- current media generation;
- current media generation + timeline epoch;
- full caller context including staleness.

Outstanding leases continue to own their pixel storage independently.

---

## 11. Full queue policy

Before admitting a producer frame, C1 removes entries that are:

- logically consumed;
- generation-ineligible;
- epoch-ineligible;
- stale by caller minimumSequence;
- otherwise ineligible for the current context.

If the queue remains full:

- the oldest unleased queue entry is reclaimed to favor the new current-context frame;
- if every remaining entry is leased, the producer frame is dropped.

Producer result:

`DroppedFullLeased`

Producer never waits for a future consumer.

Capacity never expands.

---

## 12. Empty/starved behavior

An empty queue returns:

`AcquireResultKind::Empty`

immediately.

A queue with no currently eligible unleased frame returns:

`AcquireResultKind::NoEligibleFrame`

immediately.

No black frame.

No synthetic frame.

No wait.

---

## 13. NormalizationTarget

`NormalizationTarget` represents:

- target width;
- target height;
- target pixel format;
- orientation requirement;
- color metadata policy.

Supported C1 target pixel formats:

- 420v — `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`
- 420f — `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`

No universal winner is selected.

Target size is caller-configurable.

---

## 14. Orientation admission

Stage C1 does not rotate pixels.

The supported C1 canonical orientation requirement is:

`UprightIdentityTransform`

A passthrough is admitted only when source preferredTransform is identity.

A non-identity transform returns:

- `NormalizationStatus::TransformRequired`
- `TransformRequirement::Orientation`

No frame is produced.

The output is marked `OrientationState::Normalized` only when no pixel orientation transform is required and the frame already satisfies the canonical target.

---

## 15. Size admission

If actual PreparedFrame dimensions exactly equal target width/height, C1 can continue admission.

If width or height differs:

- status = TransformRequired;
- requirement = Size;
- no output frame.

No scaling.

No crop.

No resampling.

---

## 16. Pixel-format admission

If actual PreparedFrame pixel format equals target pixel format, C1 can continue admission.

If not:

- status = TransformRequired;
- requirement = PixelFormat;
- no output frame.

C1 does not convert:

- 420v -> 420f;
- 420f -> 420v;
- YUV -> BGRA;
- BGRA -> YUV.

No intermediate pixel format is introduced.

---

## 17. Color metadata policy

Implemented policies:

- PreserveSource
- RequirePresent

PreserveSource copies the source semantic metadata into the passthrough PreparedFrame using the existing Stage A ownership rules.

Preserved values include:

- color primaries;
- transfer function;
- YCbCr matrix;
- attachments snapshot.

No default is invented for unknown metadata.

No Rec.709, sRGB, P3, or other profile is selected automatically.

RequirePresent admits only when the three explicit color-description fields are present.

No color conversion exists.

---

## 18. Zero-copy passthrough proof

When all admission requirements match:

- correct generation;
- correct timeline epoch;
- Ready frame;
- identity preferred transform;
- target dimensions already match;
- target pixel format already matches;
- metadata policy passes;

FrameNormalizer returns:

`NormalizationStatus::ReadyPassthrough`

The output PreparedFrame:

- points to the exact same CVPixelBuffer storage identity;
- has independent strong ownership through PreparedFrame retain semantics;
- preserves FrameIdentity;
- preserves FrameTiming;
- preserves color metadata;
- preserves attachments;
- changes orientation to Normalized only because no pixel transform was necessary.

No pixel copy is made by FrameNormalizer.

---

## 19. Transform-required behavior

TransformRequired is a normal admission result, not a fatal process failure.

It produces:

**NO FRAME**

It does not:

- create black fallback;
- call hidden transform APIs;
- rotate;
- scale;
- crop;
- resample;
- convert pixel format.

Transform technology remains deferred.

---

## 20. Buffer-pool boundary

Production Stage C1 does not create or use `CVPixelBufferPool`.

Reason:

pool size and allocation thresholds depend on target-device measurement that does not yet exist.

State:

**CVPIXELBUFFERPOOL = NOT STARTED / DEFERRED TO MEASUREMENT**

---

## 21. Threading boundary

ReadyFrameQueue bookkeeping is safe for producer/consumer concurrency through its mutex and atomic logical lease state.

Stage C1 does not create:

- producer worker;
- decoder worker;
- scheduler;
- injector thread.

Threading in tests is used only to prove fail-fast lock contention behavior.

---

## 22. Stage A regression

Latest canonical remediation Run #5:

`36069984848`

Result:

**13 / 13 PASS — 0 failures**

Stage A production source remained unchanged.

---

## 23. Stage B regression

Latest canonical remediation Run #5:

`36069984848`

Result:

**10 / 10 PASS — 0 failures**

Stage B production source remained unchanged.

LocalVideoReader remains a decode primitive and does not publish directly into ReadyFrameQueue.

No reader -> normalizer -> queue orchestration is implemented in C1.

---

## 24. Stage C1 queue tests

Result:

**18 / 18 PASS — 0 failures**

Covered:

1. capacity zero rejected;
2. publish Ready frame succeeds;
3. queue size never exceeds capacity;
4. empty acquire returns immediately;
5. matching generation/epoch acquisition;
6. old generation purge;
7. old epoch purge;
8. minimumSequence staleness;
9. invalidated frame rejection;
10. failed frame rejection;
11. lease survives queue-entry removal;
12. full queue reclaims oldest unleased frame;
13. all leased drops new producer frame;
14. release permits later reclamation;
15. consumer lock contention returns Contended;
16. repeated publish never grows past capacity;
17. explicit generation purge;
18. explicit epoch purge.

---

## 25. Stage C1 normalizer tests

Latest remediation result:

**17 / 17 PASS — 0 failures**

Covered:

1. identity + matching dimensions + 420v passthrough;
2. identity + matching dimensions + 420f passthrough;
3. same CVPixelBuffer storage identity;
4. output independent strong ownership;
5. Normalized only for compatible passthrough;
6. non-identity transform -> TransformRequired;
7. width mismatch -> TransformRequired;
8. height mismatch -> TransformRequired;
9. pixel-format mismatch -> TransformRequired;
10. invalid frame -> no output;
11. generation mismatch -> no output;
12. epoch mismatch -> no output;
13. color metadata preserved;
14. attachments preserved;
15. unknown color metadata remains unknown;
16. RequirePresent with complete color metadata -> ReadyPassthrough;
17. RequirePresent with incomplete color metadata -> MissingRequiredColorMetadata.

### RequirePresent remediation coverage

The complete-metadata test provides all three required fields:

- color primaries;
- transfer function;
- YCbCr matrix.

Expected and observed result:

- `NormalizationStatus::ReadyPassthrough`;
- output frame present;
- all three metadata values preserved.

The incomplete-metadata test contains three independent subcases:

1. missing color primaries;
2. missing transfer function;
3. missing YCbCr matrix.

For each subcase the test requires:

- `NormalizationStatus::MissingRequiredColorMetadata`;
- `TransformRequirement::None`;
- no output frame.

This proves each required field is individually enforced and that missing metadata is not misreported as a pixel-transform requirement.

No black or synthetic frame is created.

---

## 26. CI iteration history

Initial C1 commit:

`c87aa2bd8b288b7a9c586101aedb9a9051b4c3eb`

Run #1 / `36068500697` failed at queue-test compilation because `std::optional::emplace` could not invoke a private ReadyFrameLease constructor through the library implementation.

Minimal C1 fix:

`7eb1e06c6c84726fcb47d0d4828731f5c2270329`

The fix constructs ReadyFrameLease inside ReadyFrameQueue, where access is authorized, then move-constructs the optional value.

Run #2 / `36068587719` compiled the queue but exposed two test-assumption errors: publish already performed eager context cleanup before the explicit purge assertions.

Test-only correction:

`fab38d02c2ae96f06ec0b3e9f86a416191ed379c`

The purge tests were aligned with the implemented eager context-cleanup semantics.

Run #3 / `36068657432`:

**SUCCESS**

Supervisor remediation identified one remaining coverage gap: `ColorMetadataPolicy::RequirePresent` was implemented but not directly tested.

Remediation commit:

`dbe825c608ae9f175a0492d5386c770cf33dec54`

Changes:

- added a direct RequirePresent complete-metadata PASS test;
- added a RequirePresent incomplete-metadata rejection test with independent missing-primaries, missing-transfer, and missing-matrix subcases;
- updated the CI normalizer expectation from 15 to 17 tests;
- production code remained unchanged.

Remediation Run #5 / `36069984848`:

**SUCCESS**

Results:

- Stage A: 13 / 13 PASS;
- Stage B: 10 / 10 PASS;
- Stage C1 queue: 18 / 18 PASS;
- Stage C1 normalizer: 17 / 17 PASS;
- iOS arm64 compile: PASS;
- minimum iOS: 15.0;
- negative checks: PASS.

Functional remediation artifact:

- name: `vcam-frame-engine-stage-c1-static`;
- artifact ID: `10837579053`;
- digest: `sha256:3254809a35d4608ee9ed15ba2760e362cc422d848efd0673be357e8a992a11f1`.

After this proof reconciliation, a successful `pull_request` validation is required on the final branch head. That final-head run is recorded through immutable GitHub PR run metadata and the Builder terminal report rather than creating a self-referential documentation loop.

No history rewrite was used.

---

## 27. Build environment

GitHub-hosted runner label:

`macos-latest`

Observed image:

`macos-26-arm64`

Observed toolchain:

- Xcode 26.6
- Apple clang 21.0.0
- macOS SDK 26.5
- iPhoneOS SDK 26.5

No Theos.

No signing.

No secrets.

No device.

---

## 28. iOS arm64 compile proof

Production units compiled into:

`libVCAMFrameEngineStageC1.a`

Objects:

- PreparedFrame.o — Mach-O 64-bit arm64
- FrameEngineState.o — Mach-O 64-bit arm64
- LocalVideoReader.o — Mach-O 64-bit arm64
- ReadyFrameQueue.o — Mach-O 64-bit arm64
- FrameNormalizer.o — Mach-O 64-bit arm64

Archive architecture:

**arm64**

Observed minimum OS on C1 objects:

**iOS 15.0**

arm64e:

**NOT PRESENT**

---

## 29. Static artifact

Artifact name:

`vcam-frame-engine-stage-c1-static`

Latest functional remediation artifact ID:

`10837579053`

GitHub Actions artifact ZIP digest:

`sha256:3254809a35d4608ee9ed15ba2760e362cc422d848efd0673be357e8a992a11f1`

Artifact is CI-only.

It contains the static archive, undefined-symbol summary, and host-test summaries.

It is not:

- a release;
- a dylib;
- a tweak;
- a deb;
- an IPA;
- an app bundle;
- a deployment artifact.

---

## 30. Undefined-symbol / API boundary

Expected existing Stage B AVAssetReader symbols remain present in the combined archive.

C1 CI rejects new production references to:

- VTDecompression;
- VTPixelTransfer;
- VTPixelRotation;
- VideoToolbox;
- CoreImage;
- Metal;
- vImage;
- Accelerate transforms;
- AVCapture;
- Photos;
- UIKit;
- MSHookFunction;
- MSHookMessageEx;
- mediaserverd;
- NSURLSession;
- socket/network APIs.

Result:

**PASS**

No transform primitive was selected.

---

## 31. Explicit non-effects

Stage C1 did not:

- modify Stage A production source;
- modify Stage B production source;
- modify Stage A CI;
- modify Stage B CI;
- modify the Frame Engine contract;
- implement rotation;
- implement scaling;
- implement crop;
- implement resampling;
- implement pixel-format conversion;
- use VideoToolbox transforms;
- use CoreImage;
- use Metal;
- use vImage/Accelerate transforms;
- create production CVPixelBufferPool;
- add a producer worker;
- add a scheduler;
- connect LocalVideoReader directly to the queue;
- implement injector logic;
- contact a device;
- access live camera frames;
- substitute camera frames.

---

## 32. Device/performance boundary

**DEVICE NOT USED**

**DEVICE GATE: HOLD — AWAITING PHYSICAL DEVICE**

**A9 720P30 DEVICE PERFORMANCE: NOT YET MEASURED**

**TRANSFORM PRIMITIVE: NOT SELECTED / IOS 15.8.8 DEVICE BEHAVIOR NOT PROVEN**

**MEDIASERVERD LOAD: NOT YET PROVEN**

**FRAME SUBSTITUTION: PROHIBITED**

**IOS 15.8.8 RUNTIME: NOT YET PROVEN**

---

## 33. Reference repositories

References remained READ ONLY:

- `martaxi-boss/MotionCam-iOS` @ `5ede3a1973a01cb13fe7f3ab562b47513feec1b1`
- `martaxi-boss/IOS-15-USB` — EMPTY
- `martaxi-boss/IOS-16-USB-4k` @ `cc20d787070c67565173d4a46c218e2549cecc93`

No reference repository was modified.

---

## 34. Result

**FRAME ENGINE CONTRACT: DEFINED**

**FRAME ENGINE IMPLEMENTATION: STAGE C1 — BOUNDED READY QUEUE / NORMALIZATION ADMISSION**

**FRAME ENGINE STAGE A BUILD: PASS**

**FRAME ENGINE STAGE B BUILD: PASS**

**FRAME ENGINE STAGE C1 BUILD: PASS**

**FRAME ENGINE DECODER: AVASSETREADER LOCAL VIDEO — BUILD/HOST TEST PASS**

**READY FRAME QUEUE: BOUNDED / BUILD-HOST TEST PASS**

**NORMALIZATION: ADMISSION + PASSTHROUGH ONLY**

**PIXEL TRANSFORMS: NOT STARTED**

**TRANSFORM PRIMITIVE: NOT SELECTED / IOS 15.8.8 DEVICE BEHAVIOR NOT PROVEN**

**CVPIXELBUFFERPOOL: NOT STARTED / DEFERRED TO MEASUREMENT**

**DEVICE GATE: HOLD — AWAITING PHYSICAL DEVICE**

**A9 720P30 DEVICE PERFORMANCE: NOT YET MEASURED**

**MEDIASERVERD LOAD: NOT YET PROVEN**

**FRAME SUBSTITUTION: PROHIBITED**

**IOS 15.8.8 RUNTIME: NOT YET PROVEN**

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

