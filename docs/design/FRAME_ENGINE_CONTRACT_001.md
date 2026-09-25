# VCAM PRO — Frame Engine Contract 001

## Status

**DESIGN CONTRACT — IMPLEMENTATION NOW EXISTS THROUGH STAGE D1 / STAGE D2 VALIDATION**

**DEVICE GATE 1: RUNTIME PREPARATION STARTED / LOAD NOT YET PROVEN**

This document defines the contract for the future Local Media Engine and Frame Engine. It does not implement either component and does not change the central-injection runtime gate.

The current central candidate remains:

**mediaserverd — LEADING RESEARCH CANDIDATE / NOT RUNTIME PROVEN**

Frame substitution remains:

**PROHIBITED**

---

## 1. Objective

Define an injector-independent contract for producing ready video frames from local media on the normative target.

The future architecture remains:

LOCAL FILE
-> DECODE
-> ORIENTATION NORMALIZATION
-> SCALE / CROP
-> PIXEL FORMAT NORMALIZATION
-> COLOR METADATA
-> READY FRAME QUEUE
-> FUTURE VALIDATED INJECTOR ADAPTER

The Local Media Engine / Frame Engine must not depend on a private callback that has not yet been validated on iOS 15.8.8.

The future injector must consume already-prepared frames and must never perform sustained decode, scale, crop, rotation, or media-file work.

---

## 2. Exact target

Normative target:

- iPhone 6s Plus
- Apple A9
- arm64
- iOS 15.8.8
- Dopamine
- rootless

Performance sequence:

1. 720p / 30 fps
2. 1080p / 30 fps
3. 4K is not an initial requirement

Priority:

**STABILITY > LATENCY > QUALITY > MAXIMUM RESOLUTION**

Design baseline:

**main @ 232df9e19ac227ca0126a314b122a937c1de9e6c**

Workstream:

**builder/frame-engine-contract-001**

Device runtime work was not part of the original Contract 001 task. Current runtime work is governed by the device-proof policy below.

### 2.1 Current evidence and device-proof policy — 2026-09-25

**STATIC FACTS -> GitHub/reference artifacts.**

Do not use the target iPhone to rediscover package metadata, extracted payloads, plists, Mach-O metadata, imports/dependencies, strings, symbols, disassembly or source-repository facts.

**RUNTIME FACTS -> real iPhone only.**

Use the device for actual dylib load/PID identity, callback reachability, threading/frequency/lifetime, real buffer/format/timing behavior, stability, substitution/fail-open behavior and target-device performance.

Current device gates:

1. **Gate 1 — LOAD**: prove the audited VCAM PRO load probe loads in `mediaserverd`.
2. **Gate 2 — PASSIVE CONTRACT OBSERVATION**: after Gate 1 PASS, observe the real callback/contract without substitution.
3. **Gate 3 — MINIMAL SAFE SUBSTITUTION**: after Gate 2 PASS, perform the smallest possible substitution with mandatory fail-open.

Gate 1 remains pending.

---

## 3. Reference evidence

### 3.1 MotionCam-iOS

READ ONLY:

**martaxi-boss/MotionCam-iOS @ 5ede3a1973a01cb13fe7f3ab562b47513feec1b1**

Files reviewed:

- MediaManager.h
- MediaManager.m

### 3.2 IOS-15-USB

READ ONLY:

**martaxi-boss/IOS-15-USB @ a908bccbcddb4efc072bb1bc8fbeb6ee89b1af9d**

Current state:

**31-FILE HISTORICAL ARCHIVE / STATIC REFERENCE**

The archive preserves the original historical package, extracted payload, recovered dylib/plists, hashes, package metadata, Mach-O metadata, dynamic dependencies, strings, symbols, disassembly and audit documentation.

Relevant static evidence includes:

- `com.vcam.universal` 1.0.0;
- `iphoneos-arm64`;
- `mobilesubstrate`;
- arm64 Mach-O, minimum iOS 14.0, SDK 16.4;
- rootless package/payload layout;
- a filter explicitly naming `mediaserverd`;
- CoreMedia/CoreVideo/VideoToolbox;
- `CMSampleBuffer` / `CVPixelBuffer` APIs;
- `MSHookFunction` / `MSHookMessageEx`;
- Darwin-notification primitives.

This is static/historical evidence only. It does not prove iOS 15.8.8 runtime load, the actual callback contract, threading/lifetime/timing, or safe substitution. No proprietary implementation may be copied.

### 3.3 IOS-16-USB-4k

READ ONLY:

**martaxi-boss/IOS-16-USB-4k @ cc20d787070c67565173d4a46c218e2549cecc93**

Static evidence reviewed includes:

- CVPixelBufferPoolCreate
- CVPixelBufferPoolCreatePixelBuffer
- CVPixelBufferRetain
- CVPixelBufferRelease
- kCVPixelBufferIOSurfacePropertiesKey
- CMSampleBufferGetImageBuffer
- CMVideoFormatDescriptionCreate
- VTDecompressionSession APIs
- VTPixelTransferSession APIs
- VTPixelRotationSession APIs
- kCVImageBufferColorPrimariesKey
- kCVImageBufferTransferFunctionKey
- kCVImageBufferYCbCrMatrixKey

This is conceptual/static evidence only.

### Evidence labels

This document uses:

- **CONFIRMED SOURCE EVIDENCE** — directly observed in an authorized repository.
- **CONFIRMED APPLE API EVIDENCE** — directly supported by Apple documentation consulted for this work.
- **INFERENCE** — an architectural conclusion from confirmed evidence.
- **UNKNOWN** — requires build/runtime/device evidence.

---

## 4. MotionCam lessons

### 4.1 Useful concepts

**CONFIRMED SOURCE EVIDENCE**

MotionCam demonstrates:

- local AVAsset usage;
- AVAssetReader;
- AVAssetReaderTrackOutput;
- a serial decode queue;
- local playback state;
- loop/re-reader behavior;
- use of naturalSize and preferredTransform;
- CVPixelBuffer-backed video output;
- CMSampleBuffer handling;
- a retained-sample handoff convention in its public method declarations.

These are useful concepts, not code to copy.

### 4.2 Process-local state

**CONFIRMED SOURCE EVIDENCE**

MediaManager is a process-local singleton and its state lives in that injected process.

**DESIGN DECISION**

VCAM PRO must not make this process-local object the central architectural state. The future Media/Frame Engine must have an explicit ownership boundary and a transport-independent frame contract.

### 4.3 Reader reset / EOS / error ambiguity

**CONFIRMED SOURCE EVIDENCE**

MotionCam recreates AVAssetReader objects to loop and calls copyNextSampleBuffer again when the first call returns no sample.

**CONFIRMED APPLE API EVIDENCE**

Apple documents that copyNextSampleBuffer can return nil either because all available samples were read or because an error occurred, and directs callers to inspect AVAssetReader status to distinguish the reason.

**DESIGN DECISION**

A future VCAM PRO reader state machine must distinguish:

- completed / EOS;
- failed;
- cancelled;
- not yet ready / invalid state.

Looping is allowed only after confirmed EOS/completion. A decode error must not be silently treated as EOS.

### 4.4 preferredTransform is metadata, not pixel rotation

**CONFIRMED SOURCE EVIDENCE**

MotionCam applies preferredTransform to naturalSize to derive display dimensions.

**CONFIRMED APPLE API EVIDENCE**

Apple describes preferredTransform as the track transform preference to apply during presentation or processing.

**DESIGN DECISION**

Using the transform to compute width/height does not itself normalize pixel orientation. The future Frame Engine must explicitly track whether the pixel data has actually been rotated/transformed.

### 4.5 Wall-clock retiming

**CONFIRMED SOURCE EVIDENCE**

MotionCam replaces the sample output presentation timestamp with a CACurrentMediaTime-derived value.

**DESIGN DECISION**

VCAM PRO must not adopt this as the final timing rule.

Source media timing, engine playback timing, and the future camera-consumer timing contract are separate domains. The future injector adapter will only map timing after the real consumer contract is measured.

### 4.6 Default/fixed resolution assumptions

**CONFIRMED SOURCE EVIDENCE**

MotionCam initializes videoSize to 1920x1080 and later replaces it when usable track dimensions are available.

**DESIGN DECISION**

VCAM PRO will not use 1920x1080 as an implicit fallback contract. Width and height must be explicit frame properties derived from decoded/normalized output and the future consumer contract.

### 4.7 Pixel-range inconsistency in black-frame generation

**CONFIRMED SOURCE EVIDENCE**

MotionCam requests:

**kCVPixelFormatType_420YpCbCr8BiPlanarFullRange / 420f**

but fills the luma plane with value 16 for its generated black frame.

**CONFIRMED APPLE API EVIDENCE**

Apple defines:

- 420f as full-range with luma 0...255;
- 420v as video-range with luma 16...235.

Therefore MotionCam's declared full-range format and Y=16 black-level choice are inconsistent as a general color-range contract.

**DESIGN DECISION**

VCAM PRO must never infer black levels from the pixel-format name alone without respecting the format's range and color metadata.

### 4.8 Black-frame fallback

**CONFIRMED SOURCE EVIDENCE**

MotionCam generates a black sample when video output is unavailable or looping cannot immediately produce a sample.

**DESIGN DECISION**

This is not the VCAM PRO fail-open behavior.

For VCAM PRO:

**FRAME ENGINE FAILURE => NO VIRTUAL FRAME => REAL CAMERA FALLBACK**

The engine must not manufacture a black frame merely to hide decode failure.

### 4.9 Ownership boundary

**CONFIRMED SOURCE EVIDENCE**

MotionCam marks nextVideoFrame and nextAudioFrame as retained-return methods and releases source samples after creating a copy.

**CONFIRMED APPLE API EVIDENCE**

Apple documents:

- Create/Copy Core Foundation objects are caller-owned;
- CMSampleBufferGetImageBuffer returns a buffer the caller does not own;
- CVPixelBufferRetain / CVPixelBufferRelease map to Core Foundation retain/release semantics.

**DESIGN DECISION**

VCAM PRO requires explicit queue/consumer ownership rules; a borrowed image buffer must never escape a sample-buffer scope without an explicit retain or equivalent owned lease.

### 4.10 Audio

**CONFIRMED SOURCE EVIDENCE**

MotionCam also constructs an independent audio AVAssetReader path.

**DESIGN DECISION**

Audio is outside Frame Engine Contract 001.

The first VCAM PRO Media/Frame Engine implementation proof will be video-only. Audio must not expand this gate.

---

## 5. iOS16 static concepts

### 5.1 Confirmed static evidence

**CONFIRMED SOURCE EVIDENCE**

IOS-16-USB-4k contains static references to:

- pixel-buffer pool creation;
- pixel-buffer retain/release;
- IOSurface-backed pixel-buffer attributes;
- CMSampleBuffer image-buffer access;
- video format-description creation;
- explicit VideoToolbox decompression;
- pixel transfer;
- pixel rotation;
- color primaries;
- transfer function;
- YCbCr matrix.

### 5.2 Architectural inferences

**INFERENCE**

Those symbols are consistent with a design that:

- reuses allocated pixel buffers;
- normalizes or converts frame dimensions/formats;
- tracks CoreVideo ownership;
- carries explicit color metadata.

They do not prove the internal source architecture, queue depth, exact output format, or consumer contract.

### 5.3 Unknowns

**UNKNOWN**

The static evidence does not prove:

- which APIs were actually used on every frame;
- buffer-pool capacity;
- exact pool attributes;
- whether IOSurface was used for inter-process transfer;
- exact scaling/crop policy;
- exact orientation policy;
- exact output pixel format;
- exact color conversion policy;
- exact iOS 15.8.8 availability/behavior of every API appearing in the iOS16 binary.

No proprietary implementation is reconstructed here.

---

## 6. iOS15 API / compatibility findings

### 6.1 AVAssetReader

**CONFIRMED APPLE API EVIDENCE**

Apple documents AVAssetReaderTrackOutput as a way to read one media track and return samples either in stored form or converted to uncompressed output.

With non-nil outputSettings, the track output decodes the samples and returns them in presentation order.

With nil outputSettings, the output can vend stored-format samples and skip decode.

**DESIGN DECISION**

The first future Media Engine proof should use AVAssetReader with explicit uncompressed video output settings.

### 6.2 copyNextSampleBuffer

**CONFIRMED APPLE API EVIDENCE**

copyNextSampleBuffer returns nil on EOS or error; reader status must be inspected.

**DESIGN DECISION**

Reader state and errors are part of the Media Engine state machine, not hidden inside a frame getter.

### 6.3 CMSampleBuffer image-buffer ownership

**CONFIRMED APPLE API EVIDENCE**

CMSampleBufferGetImageBuffer returns an image buffer that is not owned by the caller. A caller that keeps the image buffer must retain it.

**DESIGN DECISION**

The Prepared Frame queue never stores an unretained borrowed CVPixelBuffer.

### 6.4 Core Foundation Create/Copy rule

**CONFIRMED APPLE API EVIDENCE**

Objects returned from Create/Copy ownership paths are caller-owned and must be released. Apple also documents CMSampleBufferCreateCopy as a shallow sample-buffer copy that retains its underlying data buffer/format description and propagatable attachments.

**DESIGN DECISION**

The contract uses explicit owner/lease transfer rather than assuming a CMSampleBuffer copy owns independent pixel bytes.

### 6.5 Pixel-buffer pool

**CONFIRMED APPLE API EVIDENCE**

CVPixelBufferPoolCreatePixelBuffer creates buffers according to pool pixel-buffer attributes and default attachment attributes.

**DESIGN DECISION**

A pool is a likely future allocation strategy, but the pool capacity and threshold are measurement parameters, not constants in this contract.

### 6.6 Attachments and color metadata

**CONFIRMED APPLE API EVIDENCE**

CoreVideo exposes:

- color primaries;
- transfer function;
- YCbCr matrix;
- propagated and non-propagated attachments;
- an API for propagating attachments between buffers.

**DESIGN DECISION**

Color metadata is first-class frame metadata. Normalization must explicitly preserve, translate, or replace relevant attachments rather than silently losing them.

### 6.7 Timing

**CONFIRMED APPLE API EVIDENCE**

CMSampleBuffer exposes presentation timestamp, decode timestamp, duration, and output timing concepts.

**DESIGN DECISION**

VCAM PRO stores media-source timing without assuming it is already the future camera-consumer timing.

### 6.8 VideoToolbox decompression

**CONFIRMED APPLE API EVIDENCE**

Apple documents VTDecompressionSession as a session for decoding compressed video samples into output frames.

**DESIGN DECISION**

This remains an optional future decoder strategy, not the default first implementation.

### 6.9 VideoToolbox pixel transfer / rotation

**CONFIRMED APPLE API EVIDENCE**

Apple documents VTPixelTransferSession for copying/converting between pixel buffers and VTPixelRotationSession for rotating from a source pixel buffer to a destination pixel buffer.

**UNKNOWN — IOS 15 TARGET**

The official Apple pages consulted for this work confirm semantics but did not provide sufficient retrieved evidence here to promote these two APIs as guaranteed iOS 15.8.8 implementation dependencies.

The fact that they occur in the iOS16 reference is not iOS15 proof.

**DESIGN DECISION**

The iOS15 baseline must not depend on VTPixelTransferSession or VTPixelRotationSession until a later target-SDK/build validation explicitly proves availability and behavior.

### 6.10 BGRA conversion warning

**CONFIRMED APPLE API EVIDENCE**

Apple TN3121 warns against defaulting capture output to BGRA because it may require format conversion and uses substantially more memory than native bi-planar YCbCr formats.

**INFERENCE**

Although the technote is about AVCaptureVideoDataOutput rather than AVAssetReader, the memory-size and conversion-cost warning is relevant to A9 normalization strategy.

It does not prove the future private consumer's preferred format.

---

## 7. Prepared Frame contract

The contract is abstract and injector-independent.

The future implementation may represent it as a struct/class, but this document does not prescribe language or binary ABI.

### 7.1 Required fields

| Field | Contract |
| --- | --- |
| pixelBuffer | Owned/leased CVPixelBuffer-compatible storage; never a dangling borrowed reference |
| width | Actual normalized pixel width |
| height | Actual normalized pixel height |
| pixelFormat | Actual CoreVideo OSType/FourCC of pixelBuffer |
| sourcePTS | Presentation timestamp from the decoded source timeline |
| presentationTimestamp | Frame Engine playback-timeline presentation timestamp; not yet camera timing |
| duration | Source or normalized frame duration; must be valid or explicitly unknown |
| orientation | Explicit source/normalized orientation state |
| colorPrimaries | Explicit value if known; unknown must be represented as unknown, not guessed |
| transferFunction | Explicit value if known |
| yCbCrMatrix | Explicit value if known/applicable |
| attachments | Snapshot/propagated metadata required to preserve frame semantics |
| sequence | Monotonic frame sequence within a playback epoch |
| mediaGeneration | Identity that changes when selected media changes |
| timelineEpoch | Identity that changes when timing is discontinuously remapped |
| loopIteration | Loop cycle identity where loop is enabled |
| producedAt | Monotonic engine host-time observation for staleness accounting |
| validity | Ready / invalidated / failed or equivalent explicit state |
| staleAfter | Policy value or computed boundary; must not be an undocumented magic constant |

### 7.2 Invariants

A Ready Prepared Frame must satisfy all of the following:

- non-null pixel storage;
- width and height match the actual pixel buffer;
- pixelFormat matches the actual pixel buffer;
- generation and timeline identities match the active Media Engine state;
- orientation state is explicit;
- timing is internally coherent;
- color metadata is explicit when known;
- ownership is valid for the entire lease;
- the frame is not invalidated or stale.

The contract deliberately does not include:

- a private callback address;
- a mediaserverd class/selector;
- a camera-specific CMSampleBuffer ABI;
- an injector hook;
- an IPC mechanism.

### 7.3 CMSampleBuffer boundary

The Prepared Frame contract is not defined as a CMSampleBuffer.

The Media Engine may receive CMSampleBuffer objects from AVAssetReader, but it should extract/retain the image buffer and capture required timing/metadata into the Prepared Frame contract.

A future consumer adapter may construct or adapt a CMSampleBuffer only if the validated central consumer requires one.

This prevents the Frame Engine from being coupled to an unknown private callback contract.

---

## 8. Decoder strategy comparison

| Criterion | AVAssetReader | Explicit VTDecompressionSession |
| --- | --- | --- |
| Local file integration | Direct and simple | Requires explicit compressed-sample path |
| Output ordering | Decoded output can be delivered in presentation order | Caller manages decode session/callback flow |
| Implementation complexity | Lower | Higher |
| Codec/decode control | Moderate | Higher |
| Memory/lifetime complexity | Lower | Higher |
| First 720p30 proof suitability | **Preferred** | Deferred |
| Reason to adopt | Simple deterministic local decode | Only after evidence shows a need for more control/performance |

### Initial decoder strategy

**AVAssetReader first.**

Reasons:

- already demonstrated conceptually by MotionCam;
- Apple documents uncompressed output conversion;
- simpler ownership/state model for a first 720p30 proof;
- avoids adding explicit decoder callback/session complexity before it is justified.

### VideoToolbox promotion conditions

Explicit VideoToolbox decode may be promoted later only if measurements show a concrete need, such as:

- AVAssetReader cannot meet A9 latency/resource targets;
- a required codec/output constraint needs explicit control;
- decoder reuse/control materially reduces resource use;
- future consumer timing/format requirements justify it.

The iOS16 reference is not by itself a reason to choose explicit VideoToolbox decode.

---

## 9. Normalization pipeline

Candidate logical pipeline:

LOCAL FILE
-> AVASSETREADER DECODE
-> SOURCE METADATA CAPTURE
-> ORIENTATION NORMALIZATION
-> SCALE / CROP
-> PIXEL FORMAT NORMALIZATION
-> COLOR METADATA NORMALIZATION
-> READY FRAME
-> BOUNDED READY QUEUE

### 9.1 Decode output

Prefer requesting a useful uncompressed output from AVAssetReader when that avoids an extra conversion stage.

Do not request a format merely because a reference project uses it.

### 9.2 Orientation

preferredTransform is input metadata.

Frame Engine output must carry one of two explicit states:

- pixels already normalized to the canonical orientation; or
- pixels not normalized, with an explicit transform/orientation contract.

For the eventual injector path, already-normalized pixels are preferred because heavy rotation must not happen inside the injector.

### 9.3 Scale / crop

Scaling/cropping must occur before publish.

The exact implementation technology is not frozen by this contract.

### 9.4 Candidate mechanisms

**CoreVideo/CoreMedia primitives**

Useful for:

- pixel-buffer storage;
- pools;
- timing metadata;
- format descriptions;
- attachments;
- retain/release.

They are not, by themselves, a complete arbitrary rotation/scaling engine.

**VTPixelTransferSession**

Conceptually attractive for pixel-buffer conversion/scaling/color handling.

Status for iOS15 baseline:

**CANDIDATE ONLY / TARGET AVAILABILITY NOT YET PROVEN**

**VTPixelRotationSession**

Conceptually attractive for pixel-buffer rotation.

Status for iOS15 baseline:

**CANDIDATE ONLY / TARGET AVAILABILITY NOT YET PROVEN**

### 9.5 Future implementation rule

If a chosen normalization primitive is not proven for iOS 15.8.8, the Builder must select another target-compatible mechanism rather than increasing the deployment target.

---

## 10. Pixel-format strategy

No single format is final until the real iOS15 consumer contract is measured.

### 10.1 420v

**kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange**

Apple definition:

- bi-planar 4:2:0;
- 8-bit;
- video-range luma 16...235;
- video-range chroma 16...240.

Advantages:

- compact YUV 4:2:0 storage;
- common camera/video format family;
- avoids BGRA-size overhead;
- range semantics align with Y=16 video-black.

Risks / unknowns:

- future central consumer may not require 420v;
- source may be full-range;
- incorrect metadata/range conversion can create lifted/crushed blacks or color errors.

### 10.2 420f

**kCVPixelFormatType_420YpCbCr8BiPlanarFullRange**

Apple definition:

- bi-planar 4:2:0;
- 8-bit;
- full-range luma 0...255.

Advantages:

- compact YUV 4:2:0 storage;
- useful for full-range sources/pipelines.

Risks / unknowns:

- future central consumer may expect video-range;
- converting video-range to full-range has a cost and color/range implications;
- black value must be consistent with full-range semantics.

### 10.3 BGRA

**kCVPixelFormatType_32BGRA**

Advantages:

- simple packed representation;
- useful for some CPU/GPU image-processing paths.

Costs:

- 4 bytes per pixel;
- significantly larger working set than 4:2:0 bi-planar formats;
- Apple warns BGRA requests can cause conversion from native capture formats.

A9 rule:

**Do not default to BGRA without evidence.**

### 10.4 Initial pixel-format strategy

The first implementation must be parameterized for the target format and must not publish a universal hard-coded winner.

Initial preference:

1. remain in a bi-planar YUV format when source/output can do so efficiently;
2. choose 420v or 420f according to measured consumer/range requirements;
3. use BGRA only when a normalization implementation or measured consumer contract requires it.

Until device proof:

**420v vs 420f = OPEN CONTRACT PARAMETER**

---

## 11. Timing model

VCAM PRO must maintain three distinct timing domains.

### 11.1 SOURCE timeline

Derived from decoded media:

- sourcePTS;
- source duration;
- source frame ordering;
- source EOS.

These values describe the file.

### 11.2 ENGINE PLAYBACK timeline

A monotonic playback mapping maintained by the Media Engine.

It defines:

- current playback epoch;
- start position;
- pause state;
- resume mapping;
- loop iteration;
- seek discontinuities.

A Prepared Frame presentationTimestamp belongs to this engine timeline.

### 11.3 FUTURE CONSUMER / CAMERA timeline

**UNKNOWN until runtime reachability/contract proof.**

The consumer adapter, not the Media Engine, will eventually decide how an engine frame maps to the validated camera callback timebase.

### 11.4 Prohibition

Do not assume:

**consumer PTS = CACurrentMediaTime()**

Do not overwrite source timing merely to make timestamps appear monotonic.

### 11.5 State transitions

#### Start

- establish a new playback/timeline epoch;
- map selected source position to playback time;
- begin producer work;
- publish only frames from the current epoch.

#### Pause

- stop advancing production/playback mapping;
- queued frames become invalid/stale according to policy;
- future injector must not block or reuse stale frames.

Default fail-open effect:

**no eligible virtual frame => real camera**

#### Resume

- create a fresh timing mapping;
- invalidate frames from the previous timing epoch;
- continue from the preserved media position.

#### Loop

On confirmed EOS and loop enabled:

- recreate/reset reader state;
- increment loopIteration;
- establish a clean source-timeline restart;
- do not confuse the end of one loop with source PTS from the next.

#### EOS without loop

- transition to ENDED;
- stop production;
- allow no indefinite wait;
- after queued eligible frames expire/drain, there is no virtual frame.

#### Seek / reload

- increment timelineEpoch;
- cancel/rebuild reader state;
- flush/invalidate old queued frames.

#### Media replacement

- increment mediaGeneration;
- invalidate every frame from the previous media generation;
- construct new reader/normalization state.

---

## 12. Queue / backpressure model

### 12.1 Mandatory properties

The Ready Frame Queue must be:

- bounded;
- non-blocking from the consumer/injector point of view;
- generation-aware;
- timeline-aware;
- able to reject stale frames;
- able to release ownership deterministically.

### 12.2 Capacity

This contract does not freeze a magic buffer count.

Queue capacity and any pool threshold are parameters to measure later on A9.

The selected capacity must be the smallest value that gives stable 720p30 production without excessive latency or memory growth.

### 12.3 Consumer rule

Future consumer call:

**try-acquire eligible frame**

must return immediately with either:

- an owned/leased Prepared Frame; or
- no virtual frame.

It must never wait for decode or for a producer condition variable indefinitely.

### 12.4 Full queue rule

When the queue is full, the producer must not block a future injector.

Eviction preference:

1. invalid generation;
2. invalid timeline epoch;
3. stale frame;
4. oldest unleased frame no longer useful to the playback scheduler.

If every slot is currently leased and cannot be safely reclaimed:

**drop the newly produced frame rather than block the consumer/camera pipeline.**

### 12.5 Empty/starved queue

Queue empty or producer starvation means:

**no virtual frame available**

Future required result:

**REAL CAMERA FALLBACK**

### 12.6 Decoder location

Decoder/normalizer execution is never allowed in the injector callback.

---

## 13. Ownership / lifetime model

### 13.1 Producer ownership

A producer owns the decoded/normalized pixel buffer until publish.

On publish:

- the queue obtains its own strong retain/owned reference;
- the producer releases/transfers its local ownership according to the implementation language.

### 13.2 Queue ownership

Each Ready Frame Queue entry owns its frame storage for as long as the entry exists.

Removing, invalidating, or evicting an entry releases the queue's ownership.

### 13.3 Consumer lease

Consumer acquire must create an explicit lease/retain.

The queue may remove an entry while a consumer lease exists, but buffer storage must remain valid until the last lease is released.

### 13.4 Borrowed CMSampleBuffer image buffers

A CVPixelBuffer obtained with CMSampleBufferGetImageBuffer is borrowed.

It must be retained before it is stored in a Prepared Frame or used beyond the guaranteed sample-buffer lifetime.

### 13.5 Pool lifetime

A future CVPixelBufferPool is owned by a Frame Engine generation/context.

Do not destroy/reconfigure a pool while buffers from that generation remain leased.

Media replacement or format change creates a new generation/context; old context resources are retired only after all outstanding leases are gone.

### 13.6 Shallow sample-buffer copies

Because Apple documents CMSampleBufferCreateCopy as shallow with retained underlying data/format references, a sample-buffer copy must not be treated as proof that pixel data is independently duplicated.

The VCAM PRO ownership model is based on explicit buffer ownership, not presumed deep copies.

### 13.7 Stale invalidation

A frame is ineligible when any of these is true:

- mediaGeneration no longer matches;
- timelineEpoch no longer matches;
- validity is not Ready;
- stale policy says it is late;
- consumer compatibility check rejects size/format/metadata.

Invalidation never force-frees a leased frame; it prevents new acquisition and releases storage when leases end.

---

## 14. Control-plane / data-plane boundary

### Control plane

Carries small state:

- ON/OFF;
- play;
- pause;
- loop;
- selected-media identity;
- current media generation;
- current timeline epoch;
- state/errors.

A future control update should be versioned/generation-aware so the consumer can detect stale state.

Darwin notifications remain a possible small-signal mechanism only.

### Data plane

Carries ready frame storage and frame metadata.

Large frame data must not be transported via Darwin notifications.

IOSurface/shared buffers remain:

**CANDIDATE ONLY**

until the actual process boundary and target runtime are validated.

### Separation rule

The Frame Engine contract must remain usable if the eventual data plane is:

- same-process queue;
- IOSurface-backed cross-process buffers;
- another validated target-compatible mechanism.

No IPC mechanism is frozen here.

---

## 15. A9 performance strategy

### Gate 1 performance objective for the future Frame Engine

**720p / 30 fps stable before 1080p.**

### Design priorities

1. avoid unnecessary pixel-format conversions;
2. avoid BGRA by default;
3. reuse buffers through a measured pool when appropriate;
4. keep decode/normalization off the injector path;
5. use bounded queues;
6. maintain a small controlled producer lead rather than deep buffering;
7. perform orientation/scale/format work once before publish;
8. avoid duplicate full-frame copies;
9. measure sustained memory and thermal behavior;
10. preserve a direct fail-open path regardless of producer performance.

### Measurement parameters

Future device proof must measure:

- decode time per frame;
- normalization time per frame;
- queue occupancy;
- pool pressure;
- dropped producer frames;
- memory footprint;
- stale-frame rate;
- 30 fps sustained behavior;
- thermal behavior over sustained playback.

No 1080p optimization is permitted to undermine 720p stability.

4K is out of scope.

---

## 16. Fail-open integration

The contract preserves docs/FAILSAFE.md without weakening it.

### Media/Frame Engine failures

The following produce no eligible virtual frame:

- decoder initialization failure;
- unsupported file;
- decode error;
- unexpected EOS handling failure;
- normalization failure;
- producer starvation;
- queue empty;
- invalid frame;
- incompatible size;
- incompatible pixel format;
- missing/invalid required metadata;
- stale frame;
- generation mismatch;
- timing mismatch.

Future required injector result:

**REAL CAMERA FALLBACK**

### Critical rule

The Media Engine must never require the injector or camera service to wait for:

- file I/O;
- AVAssetReader;
- decode;
- scaling;
- crop;
- rotation;
- pixel-format conversion;
- queue refill;
- IPC retry.

### No black-frame failover

A Media Engine failure is represented as unavailable virtual output, not a synthetic black frame.

---

## 17. Unknowns requiring device proof

Real-device work has started, but the central load proof is still pending.

Device gate:

**GATE 1 — LOAD: NOT YET PROVEN**

The following remain UNKNOWN and must not be filled by inference:

1. whether the approved load probe loads in mediaserverd on iOS 15.8.8;
2. the actual central callback/reachability point;
3. real consumer width/height contracts;
4. real consumer pixel format(s);
5. full-range vs video-range consumer expectation;
6. required color primaries / transfer / YCbCr matrix behavior;
7. consumer timing/timebase behavior;
8. acceptable staleness window;
9. callback thread/queue;
10. IOSurface or other cross-process data-plane feasibility;
11. safe minimum queue capacity on A9;
12. safe buffer-pool threshold on A9;
13. sustained 720p30 memory/thermal budget;
14. 1080p30 feasibility after 720p success;
15. target availability/behavior of candidate normalization APIs not already proven for iOS 15.8.8.

No private consumer contract is assumed by this design.

---

## 18. Implementation sequence

This sequence is a design recommendation only. It does not authorize implementation.

### Stage A — contract types / state machine

Future implementation should first create:

- Prepared Frame representation;
- media generation / timeline epoch model;
- explicit ownership/lease model;
- reader state/error model.

No injector dependency.

### Stage B — local AVAssetReader video path

Implement video-only local decode with:

- one selected local file;
- deterministic start/stop;
- explicit EOS/error handling;
- loop;
- source timing capture;
- no audio.

Initial performance target:

**720p / 30 fps**

### Stage C — normalization and bounded queue

Add:

- explicit orientation state;
- target-size policy;
- target pixel-format parameter;
- color metadata handling;
- bounded ready queue;
- measured buffer reuse/pool if justified.

### Stage D — non-device build/static validation

Prove:

- no injector coupling;
- ownership rules are explicit;
- queue cannot grow without bound;
- decoder work is outside future injector path;
- failure produces no virtual output.

### Stage E — physical-device gates

Separate from Frame Engine work:

1. **Gate 1 — LOAD:** prove the audited VCAM PRO dylib loads in `mediaserverd`;
2. **Gate 2 — PASSIVE CONTRACT OBSERVATION:** after Gate 1 PASS, establish the real callback/contract with no substitution;
3. feed measured dimensions/formats/timing/lifetime back into Frame Engine configuration;
4. **Gate 3 — MINIMAL SAFE SUBSTITUTION:** after Gate 2 PASS, perform the smallest possible substitution with mandatory fail-open.

### Stage F — consumer adapter only after proof

Only after the real consumer contract is known:

- implement a narrow adapter from Prepared Frame to the validated callback contract;
- keep heavy processing in the Frame Engine;
- preserve fail-open;
- do not redefine the Frame Engine around a private callback.

### Stage G — later optimization

Only after 720p30 correctness/stability:

- assess explicit VideoToolbox decode;
- assess target-proven transfer/rotation primitives;
- assess 1080p30;
- tune pool/queue sizes from measurements.

---

## 19. Provenance / no-copy statement

VCAM PRO implementation must remain original.

MotionCam-iOS was consulted only for high-level concepts and limitations:

- AVAssetReader;
- loop;
- track dimensions;
- preferredTransform;
- serial decode;
- sample/pixel-buffer handling.

IOS-16-USB-4k was consulted only as static conceptual evidence for:

- buffer pools;
- ownership functions;
- IOSurface-related attributes;
- CoreMedia/CoreVideo symbols;
- VideoToolbox session families;
- color attachments.

No proprietary source was reconstructed or copied.

The current IOS-15-USB repository is a historical static archive at `a908bccbcddb4efc072bb1bc8fbeb6ee89b1af9d`. It supplies reference evidence only and no reusable proprietary implementation.

---

# Design decisions summary

1. **Prepared Frame is injector-independent and not defined as a private callback CMSampleBuffer.**
2. **AVAssetReader is the initial decoder strategy.**
3. **420v/420f remain negotiated/configured candidates; no final pixel format is declared before consumer measurement.**
4. **BGRA is not the default A9 strategy.**
5. **Source timing, engine playback timing, and consumer timing are distinct.**
6. **Queue capacity and pool size are bounded but not frozen to magic numbers.**
7. **Consumer acquisition is non-blocking.**
8. **Frame ownership uses explicit retain/lease semantics.**
9. **Media/Frame Engine failure means no virtual frame, not black-frame substitution.**
10. **VTPixelTransferSession / VTPixelRotationSession remain candidate-only until iOS15 target availability/behavior is explicitly proven.**
11. **Audio is out of the first implementation proof.**
12. **mediaserverd remains a leading candidate, not a Frame Engine dependency and not a final architecture.**

---

# Apple sources consulted

The following official Apple documentation was consulted for API semantics and design validation:

1. AVAssetReaderTrackOutput  
   https://developer.apple.com/documentation/avfoundation/avassetreadertrackoutput

2. AVAssetReaderOutput copyNextSampleBuffer  
   https://developer.apple.com/documentation/avfoundation/avassetreaderoutput/copynextsamplebuffer()

3. AVAssetTrack preferredTransform  
   https://developer.apple.com/documentation/avfoundation/avassettrack/preferredtransform

4. TN3121 — Selecting a pixel format for an AVCaptureVideoDataOutput  
   https://developer.apple.com/documentation/technotes/tn3121-selecting-a-pixel-format-for-an-avcapturevideodataoutput

5. kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange  
   https://developer.apple.com/documentation/corevideo/kcvpixelformattype_420ypcbcr8biplanarvideorange

6. kCVPixelFormatType_420YpCbCr8BiPlanarFullRange  
   https://developer.apple.com/documentation/corevideo/kcvpixelformattype_420ypcbcr8biplanarfullrange

7. kCVPixelFormatType_32BGRA  
   https://developer.apple.com/documentation/corevideo/kcvpixelformattype_32bgra

8. CMSampleBufferGetImageBuffer  
   https://developer.apple.com/documentation/coremedia/cmsamplebuffergetimagebuffer(_:)

9. CMSampleBufferCreateCopy  
   https://developer.apple.com/documentation/coremedia/cmsamplebuffercreatecopy(allocator:samplebuffer:samplebufferout:)

10. CMSampleBuffer timing APIs  
    https://developer.apple.com/documentation/coremedia/cmsamplebuffer-api

11. CVPixelBufferRetain  
    https://developer.apple.com/documentation/corevideo/cvpixelbufferretain

12. CVPixelBufferRelease  
    https://developer.apple.com/documentation/corevideo/cvpixelbufferrelease

13. CVPixelBufferPoolCreatePixelBuffer  
    https://developer.apple.com/documentation/corevideo/cvpixelbufferpoolcreatepixelbuffer(_:_:_:)

14. CVBufferPropagateAttachments  
    https://developer.apple.com/documentation/corevideo/cvbufferpropagateattachments(_:_:)

15. kCVImageBufferColorPrimariesKey / related image-buffer attachment keys  
    https://developer.apple.com/documentation/corevideo/kcvimagebuffercolorprimarieskey

16. VTDecompressionSession  
    https://developer.apple.com/documentation/videotoolbox/vtdecompressionsession-api-collection

17. VTPixelTransferSession  
    https://developer.apple.com/documentation/videotoolbox/vtpixeltransfersession-api-collection

18. VTPixelRotationSession  
    https://developer.apple.com/documentation/videotoolbox/vtpixelrotationsession-api-collection

---

# Terminal design state

**FRAME ENGINE CONTRACT: DEFINED**

**FRAME ENGINE IMPLEMENTATION: STAGE D1 IMPLEMENTED / STAGE D2 VALIDATION PASS**

**DEVICE GATE 1: RUNTIME PREPARATION STARTED / LOAD NOT YET PROVEN**

**MEDIASERVERD LOAD: NOT YET PROVEN**

**FRAME ACCESS: NO**

**FRAME SUBSTITUTION: PROHIBITED**

**IOS 15.8.8 RUNTIME: NOT YET PROVEN**

**PUBLIC RELEASE: NO**
