# VCAM PRO — Frame Engine Stage B Proof 001

## Status

**STAGE B — LOCAL AVASSETREADER VIDEO PATH: BUILD + HOST TEST PASS**

**DEVICE NOT USED**

**A9 720P30 DEVICE PERFORMANCE NOT MEASURED**

**READY FRAME QUEUE NOT IMPLEMENTED**

**NORMALIZATION NOT IMPLEMENTED**

**INJECTOR NOT IMPLEMENTED**

**FRAME SUBSTITUTION PROHIBITED**

---

## 1. Exact baseline

Approved `main` baseline:

`ba167fa420de42ec98c98f67288fc5bea3747d32`

Branch:

`builder/frame-engine-stage-b-001`

Approved Frame Engine contract:

`docs/design/FRAME_ENGINE_CONTRACT_001.md`

Expected/observed contract blob:

`d34bb302d2c5d077119651a5053cc68fb105b1e9`

The contract was not modified by Stage B.

Functional + CI-tested Stage B SHA:

`b02f338206b82527e2c388065a6f34520f151c42`

The final documentation reconciliation commit is reported by PR metadata and the terminal Builder report. A commit cannot embed its own SHA in its own content without changing that SHA.

---

## 2. Stage B file set

Production:

- `src/media_engine/LocalVideoReader.h`
- `src/media_engine/LocalVideoReader.mm`

Tests:

- `tests/media_engine/local_video_reader_stage_b_tests.mm`

CI:

- `.github/workflows/frame-engine-stage-b-ci.yml`

Evidence/state:

- `docs/proofs/FRAME_ENGINE_STAGE_B_001.md`
- `PROJECT_STATE.md`

Stage A production source was not changed.

Stage A workflow was not changed.

---

## 3. Architecture boundary

Stage B lives only in:

`src/media_engine/`

AVFoundation does not enter:

`src/frame_engine/`

The public interface is C++17.

The Objective-C++ implementation is private behind PIMPL.

Framework boundary used by Stage B:

- Foundation
- AVFoundation
- CoreFoundation
- CoreMedia
- CoreVideo
- CoreGraphics

No private framework is used.

---

## 4. Reader public API

`vcam::media_engine::LocalVideoReader` exposes:

- explicit local-file `open(filesystemPath, config)`;
- `start()`;
- one-result-at-a-time `readNext()`;
- deterministic `stop()`;
- source metadata access;
- explicit last-error reporting.

Read results distinguish:

- Frame
- EndOfStream
- LoopRestarted
- NotReady
- Failed
- Cancelled

No CMSampleBuffer is exposed through the public contract.

---

## 5. Local-file-only rule

Input is a filesystem path represented as `std::string`.

Before AVURLAsset creation the implementation:

1. rejects empty paths;
2. rejects URL-like strings containing `://`;
3. validates filesystem existence;
4. rejects directories;
5. constructs an `NSURL` with `fileURLWithPath`;
6. verifies `isFileURL`.

No remote URL is accepted.

No network stream is implemented.

No NSURLSession, socket, or Network.framework API is used.

---

## 6. AVAssetReader path

Open/configure performs:

1. local path validation;
2. AVURLAsset creation;
3. first video-track selection;
4. rejection of media with no video track;
5. AVAssetReader creation;
6. AVAssetReaderTrackOutput creation;
7. explicit pixel-format output settings;
8. `alwaysCopiesSampleData = NO`;
9. `canAddOutput` validation;
10. output registration;
11. source-video metadata capture;
12. FrameEngineState media replacement / reader-ready transition.

Start performs:

1. valid configured-reader check;
2. fresh FrameEngineState playback mapping;
3. `AVAssetReader startReading`;
4. return-value validation;
5. FrameEngineState transition to Reading.

No producer thread or timer is created.

---

## 7. Output pixel formats

Stage B accepts only an explicit caller choice of:

- `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` (420v)
- `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange` (420f)

There is no production default winner.

A configuration value of zero or BGRA is rejected by production open/configure.

The host fixture uses BGRA only as AVAssetWriter input for deterministic test-media creation.

That use is:

**TEST-ONLY — NOT A VCAM PRO PRODUCTION PIXEL-FORMAT DECISION**

---

## 8. Source metadata

Stage B captures:

- naturalSize;
- preferredTransform;
- source duration when available;
- requested output pixel format.

preferredTransform is metadata only.

Stage B does not rotate pixels.

Every produced PreparedFrame uses:

`OrientationState::SourceNotNormalized`

No Stage C normalization is claimed.

---

## 9. Frame production and ownership

For each valid CMSampleBuffer:

1. `CMSampleBufferGetImageBuffer` obtains the borrowed CVPixelBuffer;
2. source PTS is read from the CMSampleBuffer;
3. sample duration is read from the CMSampleBuffer;
4. a FrameIdentity is obtained from FrameEngineState;
5. propagatable CoreVideo attachments are snapshotted;
6. optional primaries / transfer / YCbCr matrix attachments are captured when present;
7. PreparedFrame is constructed;
8. PreparedFrame obtains its own strong CVPixelBuffer ownership;
9. temporary attachment ownership is released;
10. the CMSampleBuffer is released;
11. the PreparedFrame remains valid independently.

The public result therefore never depends on the internal CMSampleBuffer lifetime.

---

## 10. Timing semantics

Stage B preserves file/source timing.

For each frame:

`sourcePTS = CMSampleBufferGetPresentationTimeStamp(sample)`

`duration = CMSampleBufferGetDuration(sample)`

Stage B deliberately sets:

`presentationTimestamp = kCMTimeInvalid`

This field therefore remains:

**UNKNOWN / NOT CAMERA TIMING**

Stage B does not use:

- CACurrentMediaTime;
- CMSampleBufferSetOutputPresentationTimeStamp;
- camera timebase conversion;
- wall-clock retiming.

---

## 11. Nil-sample / EOS semantics

A nil result from `copyNextSampleBuffer` is never treated as EOS by itself.

The implementation switches on `AVAssetReader.status`.

### Completed

Only `AVAssetReaderStatusCompleted` can produce confirmed EOS semantics.

FrameEngineState is transitioned to ReaderState::Completed.

### Failed

`AVAssetReaderStatusFailed`:

- captures `AVAssetReader.error`;
- maps to ReaderErrorCode::ReadFailed;
- returns ReadResultKind::Failed;
- produces no virtual frame;
- is never treated as EOS;
- does not trigger loop.

### Cancelled

`AVAssetReaderStatusCancelled`:

- maps to ReaderState::Cancelled;
- returns ReadResultKind::Cancelled;
- is never treated as EOS;
- does not trigger loop.

### Reading / Unknown

Nil while Reading or Unknown returns:

`ReadResultKind::NotReady`

No EOS is inferred.

---

## 12. Loop semantics

Loop is allowed only when:

- AVAssetReader.status == Completed;
- FrameEngineState reader state is Completed;
- loop configuration is enabled.

Confirmed loop sequence:

1. confirmed Completed state;
2. `confirmLoopRestart()`;
3. loopIteration increments;
4. AVAssetReader and track output are reconstructed;
5. the new reader is started;
6. FrameEngineState returns to Reading;
7. `readNext` returns `LoopRestarted`.

The next call may return the first frame from the new iteration.

No recursion is used to fetch a new frame during the loop-restart call.

Loop restart does not automatically create a new timeline epoch.

---

## 13. Stop / cancel semantics

`stop()`:

- calls `cancelReading` when reader state makes cancellation appropriate;
- marks semantic reader state Cancelled;
- discards the reader instance;
- prevents further frames from that reader instance;
- requires a new successful `open()` before playback can start again.

Cancellation is not EOS.

No automatic restart occurs.

---

## 14. Media replacement

A successful `open()` of another local video:

1. validates and configures the replacement reader first;
2. cancels/discards the old reader;
3. calls `selectOrReplaceMedia()`;
4. increments mediaGeneration;
5. creates the Stage A-defined fresh timeline epoch;
6. resets loop iteration and sequence through FrameEngineState.

PreparedFrames from the prior generation become ineligible.

---

## 15. Failure behavior

Stage B never creates a synthetic black frame.

Failure paths return no PreparedFrame.

Examples:

- missing path;
- remote/URL-like input;
- unsupported output format;
- no video track;
- reader creation failure;
- startReading failure;
- sample missing image buffer;
- AVAssetReaderStatusFailed;
- state-transition failure.

Future fail-open behavior remains:

**NO VIRTUAL FRAME => REAL CAMERA FALLBACK**

No injector exists in Stage B.

---

## 16. Host fixture

The test suite creates deterministic temporary QuickTime video files locally with:

- AVAssetWriter;
- AVAssetWriterInput;
- AVAssetWriterInputPixelBufferAdaptor;
- H.264 video;
- 64x48 test dimensions;
- 30 fps presentation timestamps;
- video only;
- no download;
- no third-party asset.

BGRA is used only as the writer-side test fixture format.

Temporary files are removed after tests.

---

## 17. Canonical CI

Workflow:

`Frame Engine Stage B CI`

Canonical successful push run:

- Run #1
- Run ID: `36066753534`
- head SHA: `b02f338206b82527e2c388065a6f34520f151c42`
- result: **SUCCESS**

All CI stages passed:

1. checkout;
2. toolchain report;
3. source negative checks;
4. Stage A host build;
5. Stage A host tests;
6. Stage B Objective-C++ host build;
7. Stage B host tests;
8. iOS Stage A compile;
9. iOS LocalVideoReader compile;
10. static archive build;
11. architecture/minimum-OS/symbol inspection;
12. artifact upload.

---

## 18. Build environment

GitHub-hosted runner label:

`macos-latest`

Actual observed image:

`macos-26-arm64`

Observed toolchain:

- Xcode 26.6
- Apple clang 21.0.0
- macOS SDK 26.5
- iPhoneOS SDK 26.5

No Theos.

No signing identity.

No secret.

No device.

---

## 19. Stage A regression

Result:

**13 / 13 PASS — 0 failures**

Passed Stage A tests:

1. PreparedFrame retains CVPixelBuffer
2. Lease survives PreparedFrame scope
3. Copy/move ownership
4. Invalidated/failed ineligible
5. First media generation
6. Media replacement invalidates old generation
7. Start and sequence rules
8. Pause/resume fresh epoch
9. Seek/reload fresh epoch
10. Loop requires completion
11. Failed reader not EOS
12. Cancelled reader not EOS
13. Playback transitions deterministic

Stage A production source was not changed by Stage B.

---

## 20. Stage B host tests

Result:

**10 / 10 PASS — 0 failures**

Passed tests:

1. Missing and remote paths fail
2. Open/start/frame 420v
3. 420f output
4. EOS without loop
5. Loop restart and iteration
6. Cancelled reader is not EOS
7. Failed reader state is not EOS
8. Media replacement invalidates old frame
9. Unsupported output format rejected
10. Read before start is NotReady

The produced PreparedFrame is inspected after `readNext()` has already released its internal CMSampleBuffer, proving the PreparedFrame-owned CVPixelBuffer remains usable.

---

## 21. iOS arm64 compile proof

Production translation units compiled for:

- C++17 / Objective-C++;
- arm64;
- iPhoneOS SDK;
- minimum iOS 15.0.

Objects:

- `PreparedFrame.o` — Mach-O 64-bit object arm64
- `FrameEngineState.o` — Mach-O 64-bit object arm64
- `LocalVideoReader.o` — Mach-O 64-bit object arm64

Static archive:

`libVCAMFrameEngineStageB.a`

Observed archive:

**arm64**

Observed minimum OS from LocalVideoReader.o:

**iOS 15.0**

arm64e:

**NOT PRESENT**

---

## 22. Static artifact

Artifact:

`vcam-frame-engine-stage-b-static`

Artifact ID:

`10836856154`

GitHub Actions artifact ZIP digest:

`sha256:4be0c3b9c6515a83dbe3bcccdca519a217c0597130f92ca9eeee203a89b8b23a`

Artifact contents are CI-only and include:

- `libVCAMFrameEngineStageB.a`
- `undefined-symbols.txt`
- Stage A test summary
- Stage B test summary

This artifact is not a release, package, dylib, tweak, IPA, app bundle, or deployment.

---

## 23. Undefined-symbol / API boundary

Expected Stage B symbols were observed, including:

- AVAssetReader
- AVAssetReaderTrackOutput
- AVURLAsset
- CoreVideo pixel-buffer ownership APIs
- CoreFoundation
- CoreMedia
- Objective-C runtime
- C++ runtime

Archive/source checks reject:

- AVCapture
- Photos
- UIKit
- VideoToolbox
- VTDecompressionSession
- VTPixelTransferSession
- VTPixelRotationSession
- MSHookFunction
- MSHookMessageEx
- Logos `%hook`
- mediaserverd
- NSURLSession
- socket/network symbols
- Network.framework
- audio reader paths

Result:

**PASS**

---

## 24. Explicit non-effects

Stage B did **not**:

- modify Stage A production code;
- modify the Frame Engine contract;
- use remote URLs;
- use network APIs;
- implement audio;
- implement a Ready Frame Queue;
- implement backpressure;
- create a producer thread;
- prefetch frames;
- implement scale/crop;
- rotate pixels;
- normalize color/pixel layout;
- create CVPixelBufferPool in production;
- use VideoToolbox;
- create an injector;
- add hooks;
- reference mediaserverd;
- contact a device;
- install a package;
- access live camera frames;
- substitute camera frames.

---

## 25. Device/performance boundary

**DEVICE NOT USED**

**DEVICE GATE: HOLD — AWAITING PHYSICAL DEVICE**

**A9 720P30 DEVICE PERFORMANCE: NOT YET MEASURED**

The host fixture is a correctness smoke test only.

It is not evidence of sustained A9 performance.

**MEDIASERVERD LOAD: NOT YET PROVEN**

**IOS 15.8.8 RUNTIME: NOT YET PROVEN**

**FRAME SUBSTITUTION: PROHIBITED**

---

## 26. Reference repositories

References remained READ ONLY:

- `martaxi-boss/MotionCam-iOS` @ `5ede3a1973a01cb13fe7f3ab562b47513feec1b1`
- `martaxi-boss/IOS-15-USB` — EMPTY
- `martaxi-boss/IOS-16-USB-4k` @ `cc20d787070c67565173d4a46c218e2549cecc93`

No reference implementation was modified.

---

## 27. Result

**FRAME ENGINE CONTRACT: DEFINED**

**FRAME ENGINE IMPLEMENTATION: STAGE B — LOCAL AVASSETREADER VIDEO PATH**

**FRAME ENGINE STAGE A BUILD: PASS**

**FRAME ENGINE STAGE B BUILD: PASS**

**FRAME ENGINE DECODER: AVASSETREADER LOCAL VIDEO — BUILD/HOST TEST PASS**

**READY FRAME QUEUE: NOT STARTED**

**NORMALIZATION: NOT STARTED**

**DEVICE GATE: HOLD — AWAITING PHYSICAL DEVICE**

**A9 720P30 DEVICE PERFORMANCE: NOT YET MEASURED**

**MEDIASERVERD LOAD: NOT YET PROVEN**

**FRAME SUBSTITUTION: PROHIBITED**

**IOS 15.8.8 RUNTIME: NOT YET PROVEN**

**PUBLIC RELEASE: NO**
