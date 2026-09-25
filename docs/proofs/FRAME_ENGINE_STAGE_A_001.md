# VCAM PRO — Frame Engine Stage A Proof 001

## Status

**STAGE A — TYPES / STATE / OWNERSHIP: BUILD + TEST PASS**

**DEVICE NOT USED**

**DECODER NOT IMPLEMENTED**

**READY FRAME QUEUE NOT IMPLEMENTED**

**INJECTOR NOT IMPLEMENTED**

**FRAME SUBSTITUTION PROHIBITED**

---

## 1. Exact baseline

Approved `main` baseline:

`0717f6953b2feeae51338701d9c6a443cdd98592`

Branch:

`builder/frame-engine-stage-a-001`

Contract:

`docs/design/FRAME_ENGINE_CONTRACT_001.md`

The contract was not modified by this workstream.

Functional / CI-tested branch head:

`009b8a81c604deef6618353a1e1b5d7394767794`

The final branch HEAD after documentation reconciliation is the commit containing this proof/state reconciliation and is recorded exactly in the PR metadata and terminal Builder report. A Git commit cannot embed its own final SHA in its own file content without changing that SHA.

---

## 2. Implemented file set

Functional source:

- `src/frame_engine/PreparedFrame.h`
- `src/frame_engine/PreparedFrame.cpp`
- `src/frame_engine/FrameEngineState.h`
- `src/frame_engine/FrameEngineState.cpp`

Tests:

- `tests/frame_engine/frame_engine_stage_a_tests.cpp`

CI:

- `.github/workflows/frame-engine-stage-a-ci.yml`

Proof/state:

- `docs/proofs/FRAME_ENGINE_STAGE_A_001.md`
- `PROJECT_STATE.md`

No other Stage A implementation file is required.

---

## 3. Scope implemented

Stage A implements only:

- `PreparedFrame` representation;
- explicit retained `CVPixelBufferRef` ownership;
- explicit `FrameLease` consumer lifetime;
- media generation identity;
- timeline epoch identity;
- monotonic per-epoch sequence identity;
- loop iteration identity;
- explicit frame validity;
- optional retained color metadata / attachment snapshot;
- playback state;
- reader state and error model;
- deterministic state transitions.

It does **not** implement:

- decoder;
- media file I/O;
- AVAssetReader;
- queue/backpressure;
- producer thread;
- pixel-buffer pool;
- normalization;
- scheduler;
- injector;
- callback probing;
- camera integration;
- frame substitution.

---

## 4. PreparedFrame ownership model

`PreparedFrame` accepts a caller-supplied `CVPixelBufferRef` and immediately obtains its own retain.

At construction:

- width is read from `CVPixelBufferGetWidth`;
- height is read from `CVPixelBufferGetHeight`;
- pixel format is read from `CVPixelBufferGetPixelFormatType`.

The caller does not provide duplicate width/height/pixel-format values.

Destructor behavior:

- releases exactly the retained pixel buffer ownership;
- releases retained color metadata;
- releases retained/copy attachment metadata.

Copy behavior:

- retains independent ownership of the same CoreVideo storage;
- retains independent Core Foundation metadata ownership.

Move behavior:

- transfers ownership;
- clears the moved-from holder;
- does not add an unnecessary retain/release pair.

No persistent borrowed pixel buffer is stored.

---

## 5. Consumer lease model

`FrameLease` is a dedicated ownership type.

Acquiring a lease:

- succeeds only for an eligible Ready frame;
- retains the pixel buffer again for the lease;
- stores the immutable frame identity snapshot;
- survives destruction of the source `PreparedFrame`.

Lease destruction releases its own pixel-buffer retain automatically.

This makes a consumer lease semantically distinct from a borrowed `CVPixelBufferRef`.

---

## 6. Prepared frame contract fields

Implemented representation includes:

- owned `CVPixelBufferRef`;
- width;
- height;
- pixel format;
- source PTS;
- engine presentation timestamp;
- duration;
- orientation state;
- optional color primaries;
- optional transfer function;
- optional YCbCr matrix;
- optional retained attachment dictionary snapshot;
- sequence;
- media generation;
- timeline epoch;
- loop iteration;
- optional produced-at host-time metadata;
- validity state.

Unknown metadata remains representable as null/empty/Unknown.

No Rec.709 or consumer/camera value is invented.

---

## 7. Frame validity and eligibility

Validity states:

- Ready
- Invalidated
- Failed

A frame is eligible only if all are true:

- validity is Ready;
- pixel buffer is non-null;
- stored width matches the real pixel buffer;
- stored height matches the real pixel buffer;
- stored pixel format matches the real pixel buffer;
- media generation matches the active generation;
- timeline epoch matches the active epoch.

Invalidated or Failed frames cannot produce a consumer lease.

No black frame is generated as fallback.

---

## 8. Orientation and color metadata

Orientation states:

- Unknown
- SourceNotNormalized
- Normalized

No rotation is performed in Stage A.

Color metadata remains optional:

- color primaries;
- transfer function;
- YCbCr matrix;
- attachments snapshot.

Core Foundation ownership is explicit.

No color profile is selected automatically.

---

## 9. Playback state model

Playback states:

- Empty
- Ready
- Playing
- Paused
- Ended
- Failed

Key deterministic transitions implemented/tested:

- select/replace media -> Ready;
- start from valid Ready/Ended -> Playing + fresh timeline epoch;
- pause from Playing -> Paused without inventing a frame;
- resume from Paused -> Playing + fresh timeline epoch;
- seek/reload on valid media -> fresh timeline epoch;
- mark end -> Ended;
- playback failure -> Failed.

No timer or thread exists in the state model.

---

## 10. Reader state/error model

Reader states:

- Uninitialized
- Ready
- Reading
- Completed
- Failed
- Cancelled

Reader error codes are represented separately.

Required distinction is preserved:

**Completed != Failed != Cancelled**

A loop restart is semantically authorized only when reader state is Completed.

Failed and Cancelled are never treated as EOS.

There is no AVAssetReader object in Stage A.

---

## 11. Generation / epoch / sequence / loop rules

### Media generation

Selecting/replacing media:

- increments `mediaGeneration`;
- resets loop iteration;
- resets reader state;
- creates a fresh timeline epoch;
- resets per-epoch sequence.

Old-generation frames become ineligible.

### Timeline epoch

A fresh epoch is created for:

- media replacement;
- new start mapping;
- resume mapping;
- seek/reload.

Old-epoch frames become ineligible.

### Sequence

- monotonic within an epoch;
- starts at 0 for each new epoch;
- not a source frame number.

### Loop iteration

A confirmed loop restart:

- is allowed only from reader Completed;
- increments `loopIteration`;
- does not automatically create a new timeline epoch.

Consumer/camera timing remains unknown and is not modeled here.

---

## 12. Host unit-test proof

Canonical CI:

- workflow: `Frame Engine Stage A CI`
- Run #2
- Run ID: `36061404771`
- built/tested SHA: `009b8a81c604deef6618353a1e1b5d7394767794`
- result: **SUCCESS**

Test result:

**13 tests run / 13 PASS / 0 failures**

Passed tests:

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

Ownership tests do not use `CFGetRetainCount` as the primary proof.

The host test fixture uses `kCVPixelFormatType_32BGRA` only because it is a simple `CVPixelBufferCreate` fixture. It is **not** a VCAM PRO pixel-format decision.

---

## 13. Build environment

GitHub Actions runner label:

`macos-latest`

Actual runner image:

`macos-26-arm64`

Observed environment:

- macOS 26.6.2
- Xcode 26.6
- Apple clang 21.0.0
- host target: arm64-apple-darwin25.6.0
- macOS SDK: 26.5
- iPhoneOS SDK: 26.5

No Theos is used.

No signing identity is used.

No secret is required.

No device is attached.

---

## 14. Host build command

The host tests were compiled with C++17 using:

```sh
xcrun --sdk macosx clang++ \
  -std=c++17 \
  -Wall -Wextra -Werror -pedantic \
  -Isrc/frame_engine \
  src/frame_engine/PreparedFrame.cpp \
  src/frame_engine/FrameEngineState.cpp \
  tests/frame_engine/frame_engine_stage_a_tests.cpp \
  -framework CoreFoundation \
  -framework CoreMedia \
  -framework CoreVideo \
  -o build/host/frame_engine_stage_a_tests
```

Result:

**PASS**

---

## 15. iOS arm64 compile proof

Each Stage A implementation translation unit was compiled with:

```sh
xcrun --sdk iphoneos clang++ \
  -std=c++17 \
  -arch arm64 \
  -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" \
  -miphoneos-version-min=15.0 \
  -Wall -Wextra -Werror -pedantic \
  -Isrc/frame_engine \
  -c <source.cpp> \
  -o <object.o>
```

Static archive:

`build/ios/libVCAMFrameEngineStageA.a`

Archive command:

```sh
xcrun libtool -static \
  -o build/ios/libVCAMFrameEngineStageA.a \
  build/ios/PreparedFrame.o \
  build/ios/FrameEngineState.o
```

Observed object architecture:

- `PreparedFrame.o`: Mach-O 64-bit object arm64
- `FrameEngineState.o`: Mach-O 64-bit object arm64

Observed archive architecture:

**arm64**

Observed minimum iOS version from Mach-O load command:

**15.0**

arm64e:

**NOT PRESENT**

---

## 16. Static artifact

Artifact name:

`vcam-frame-engine-stage-a-static`

Artifact ID:

`10834735084`

GitHub Actions artifact ZIP digest:

`sha256:b9270143a74fd78523d8451ef6465a38148495f8eecad73065acef3dc9d2ae54`

Artifact contents:

- `libVCAMFrameEngineStageA.a`
- `undefined-symbols.txt`

This is a CI artifact only.

It is not a release, package, dylib, tweak, or deployment artifact.

---

## 17. Public framework / symbol boundary

Allowed Stage A API boundary:

- CoreFoundation
- CoreMedia
- CoreVideo
- C++ runtime

Observed undefined symbols in the static archive include only the expected Stage A families, for example:

- `CFDictionaryCreateCopy`
- `CFRelease`
- `CFRetain`
- `CVPixelBufferGetHeight`
- `CVPixelBufferGetPixelFormatType`
- `CVPixelBufferGetWidth`
- `CVPixelBufferRelease`
- `CVPixelBufferRetain`
- `kCMTimeInvalid`
- normal C++ runtime/unwind symbols

No private/hook symbol was observed.

No AVFoundation symbol was observed.

No VideoToolbox symbol was observed.

A static archive has unresolved framework symbols rather than a dylib-style runtime dependency list; the CI therefore validates the boundary with source checks plus `nm -u` on the archive.

---

## 18. Negative checks

CI rejects Stage A source if it contains functional references to:

- AVAssetReader
- AVCapture
- VideoToolbox
- VTDecompression
- MSHookFunction
- MSHookMessageEx
- %hook
- mediaserverd
- socket
- NSURLSession
- UIImagePicker
- CVPixelBufferPool

The canonical run passed this check.

Additional archive symbol check rejects:

- AVAsset*
- AVCapture*
- VTDecompression*
- MSHookFunction
- MSHookMessageEx

Result:

**PASS**

---

## 19. CI iteration history

Initial implementation commit:

`31c01e7c947209b6dee0b6d0da12036285db372b`

The first workflow run used `runs-on: macos-26-arm64` directly and remained queued without runner assignment.

No Stage A source was changed.

CI-only correction commit:

`009b8a81c604deef6618353a1e1b5d7394767794`

Change:

- use the project's already-proven GitHub-hosted label `macos-latest`.

The assigned runner for the successful canonical Run #2 used actual image `macos-26-arm64`.

No functional code change occurred between the two commits.

---

## 20. Explicit non-effects

This Stage A work did **not**:

- decode media;
- create AVAssetReader;
- open media files;
- select gallery media;
- implement frame queueing;
- implement backpressure;
- create producer threads;
- create CVPixelBufferPool;
- normalize/scale/crop/rotate frames;
- implement an injector;
- add hooks;
- contact a device;
- install a package;
- restart a camera service;
- access camera frames;
- substitute camera frames.

---

## 21. Device / injection boundary

**DEVICE NOT USED**

**DEVICE GATE: HOLD — AWAITING PHYSICAL DEVICE**

**MEDIASERVERD LOAD: NOT YET PROVEN**

**FRAME ACCESS: NO**

**FRAME SUBSTITUTION: PROHIBITED**

No Gate 1 runtime action occurred.

---

## 22. Reference repositories

Reference repositories remained READ ONLY:

- `martaxi-boss/MotionCam-iOS` @ `5ede3a1973a01cb13fe7f3ab562b47513feec1b1`
- `martaxi-boss/IOS-15-USB` — EMPTY
- `martaxi-boss/IOS-16-USB-4k` @ `cc20d787070c67565173d4a46c218e2549cecc93`

No reference implementation was modified or copied.

---

## 23. Result

**FRAME ENGINE CONTRACT: DEFINED**

**FRAME ENGINE IMPLEMENTATION: STAGE A — TYPES / STATE / OWNERSHIP**

**FRAME ENGINE STAGE A BUILD: PASS**

**FRAME ENGINE DECODER: NOT STARTED**

**READY FRAME QUEUE: NOT STARTED**

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

