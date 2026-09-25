# VCAM PRO — Frame Engine Stage F1 Producer Timeline / Pacing / Freshness 001

## Status

**STAGE F1 IMPLEMENTED — READY FOR FINAL CI / SUPERVISOR AUDIT**

Task:

`VCAM-PRO — FRAME ENGINE STAGE F1 — PRODUCER TIMELINE / PACING / FRESHNESS 001`

Accepted parent:

- PR #10
- branch `builder/frame-engine-stage-e1-transform-001`
- exact parent head `4abc76afa063977b0009f70c77e7f3dda1f3480d`

Validated F1 implementation head before this proof-only commit:

`990af3ba403243ae308a8cfa90dcd10cc7cbe46d`

The final F1 PR head is reported by immutable PR metadata and the Builder return. A Git commit cannot embed its own final SHA without changing that SHA.

## Boundary

Stage F1 owns only local producer playback pacing.

It does **not** define or infer the final camera callback timing contract.

It does not fabricate:

- final camera `CMSampleTimingInfo`;
- mediaserverd callback cadence;
- final injected `CMSampleBuffer` PTS.

`FrameTiming.presentationTimestamp` remains unresolved/invalid.

The only new publication timing field is:

`FrameTiming.producedAtHostTime`

which records the actual caller-supplied monotonic host nanosecond value used for local producer publication.

## Host time contract

Public scheduler host time unit:

**MONOTONIC HOST NANOSECONDS**

Type:

`std::uint64_t`

The scheduler does not:

- sample a host clock;
- use raw mach ticks in its public API;
- create threads;
- sleep or block;
- own a dispatch timer;
- own a display link.

The caller supplies `nowHostTimeNs`.

## FrameTimelineScheduler

Production files:

- `src/frame_engine/FrameTimelineScheduler.h`
- `src/frame_engine/FrameTimelineScheduler.cpp`

Inputs:

- `PreparedFrame::timing().sourcePTS`;
- `PreparedFrame::timing().duration`;
- `FrameIdentity.mediaGeneration`;
- `FrameIdentity.timelineEpoch`;
- `FrameIdentity.loopIteration`;
- current media generation;
- current timeline epoch;
- caller-supplied monotonic host time.

Structured outcomes:

- `ReadyNow`
- `WaitUntilDue`
- `DropLate`
- `InvalidTiming`
- `GenerationMismatch`
- `TimelineMismatch`

When meaningful, the result returns `dueHostTimeNs`.

## Anchor model

For the first valid frame in a generation/epoch timeline:

- source anchor = first source PTS;
- host anchor = current caller-supplied host time;
- first due time = current host time.

For later frames in the same generation/epoch/loop:

`dueHostTimeNs = hostAnchorNs + (sourcePTS - sourceAnchor)`

The source delta is converted to nanoseconds with checked integer quotient/remainder arithmetic.

No assumed FPS participates in scheduling.

30 fps, 24 fps, and variable-rate PTS are tested as source-PTS cases rather than special scheduler modes.

## Validation and malformed time handling

Stage F1 rejects:

- invalid/non-numeric source PTS;
- wrong generation;
- wrong epoch;
- non-monotonic PTS within one uninterrupted loop;
- CMTime-to-nanosecond overflow;
- host-anchor addition overflow.

The implementation uses checked `std::uint64_t` arithmetic and does not rely on non-standard wide integers.

## Loop policy

A change in `loopIteration` is treated as an intentional source-PTS reset.

The first frame of a new loop receives a new source anchor.

The host anchor never moves backwards.

If the previous frame has a valid positive duration, the new-loop boundary is no earlier than:

`previousDueHostTimeNs + previousDurationNs`

and is also no earlier than the current caller-supplied host time.

If no usable previous duration exists, the scheduler safely anchors at no earlier than current host time / previous due time.

This prevents a source PTS reset to zero from causing a burst of the new loop.

## Lateness policy

Lateness is configured by the scheduler constructor through:

`maxLatenessNs`

No 30 fps-derived constant is embedded.

If:

`nowHostTimeNs > dueHostTimeNs + maxLatenessNs`

the scheduler returns `DropLate`.

The timed pump publishes nothing for that frame and performs no internal catch-up loop.

## Timed producer mode

Production file:

- `src/media_engine/FramePipelinePumpTimed.cpp`

The existing `pumpOnce()` path remains the historical immediate producer API.

Stage F1 adds:

`pumpOnceAtHostTime(nowHostTimeNs)`

The F1 constructor accepts:

- `FrameTransformer`;
- `FrameTimelineScheduler`;
- existing `ReadyFrameQueue`;
- existing normalization target.

### One-frame pending rule

Timed mode retains at most one already prepared/transformed future frame.

When that frame is early:

- result = `WaitingForPresentation`;
- `dueHostTimeNs` is returned;
- the frame remains pending;
- no next source frame is read;
- no additional transform occurs.

A later invocation re-evaluates that same pending frame.

There is no future-frame backlog.

## Publication stamp

When a frame becomes due:

- a safe `PreparedFrame` copy is constructed;
- pixel-buffer ownership and frame identity are preserved;
- source PTS and duration are preserved;
- orientation, color metadata and attachments are preserved;
- `producedAtHostTime` is set to the actual publication call's `nowHostTimeNs`;
- `presentationTimestamp` is not fabricated.

## Low-latency queue policy

Immediately before timed publication, the pump creates a queue context whose:

`minimumSequence = sequence being published`

and calls the existing stale-purge mechanism.

Older eligible unleased entries from the same generation/epoch therefore do not accumulate deliberate playback latency.

An already acquired `ReadyFrameLease` remains valid because its retained frame/pixel-buffer ownership is independent of the queue entry lifetime.

`ReadyFrameQueue::tryAcquire()` was not changed.

## Generation / epoch reset

The timed pump tracks its local scheduling context.

A generation or epoch transition:

- clears the one-frame pending state;
- resets the scheduler;
- purges obsolete queue context;
- returns a structured `GenerationReset` or `EpochReset`;
- performs no source read on that reset call.

No old pending frame can cross into the new media generation or timeline epoch.

## Serial producer contract

Stage F1 explicitly supports one producer execution domain.

It does not add a mutex to serialize concurrent producer mutations.

A fail-fast `atomic_flag` re-entry detector returns:

`ConcurrentProducerCallRejected`

rather than silently claiming that concurrent timed-producer mutation is supported.

Consumer queue synchronization remains independent.

## Allocation / failure boundary

Stage F1 adds structured allocation handling on normal producer paths:

- `FramePipelinePump::prepareFrame` converts recoverable `std::bad_alloc` into `AllocationFailed`;
- one-frame pending storage converts `std::bad_alloc` into `AllocationFailed`;
- timed publication copy converts `std::bad_alloc` into `AllocationFailed`;
- `FrameTransformer::transform` now catches reusable scratch/container `std::bad_alloc` and returns `FrameTransformStatus::AllocationFailure`.

No partial/invalid frame is published after these recoverable allocation failures.

## Tests

Deterministic scheduler tests:

`tests/frame_engine/frame_timeline_scheduler_stage_f1_tests.cpp`

Result:

**13 / 13 PASS**

Coverage includes:

- first frame due immediately;
- 30 fps PTS pacing;
- 24 fps PTS pacing;
- variable-frame-rate PTS;
- repeated WAIT with stable due time;
- configurable lateness threshold;
- generation mismatch;
- epoch mismatch;
- loop rebase using prior scheduled end;
- non-monotonic same-loop PTS rejection;
- invalid PTS rejection;
- time-conversion overflow rejection;
- host due-time addition overflow rejection.

Timed pipeline tests:

`tests/media_engine/frame_pipeline_stage_f1_tests.mm`

Result:

**10 / 10 PASS**

Coverage includes:

- passthrough pacing;
- exact early WAIT;
- repeated WAIT does not read another source frame;
- due frame publishes exactly once;
- `producedAtHostTime` equals publication host time;
- `presentationTimestamp` remains invalid;
- late frame drop publishes nothing;
- low-latency obsolete queue cleanup;
- already leased old frame remains valid across cleanup;
- generation reset invalidates pending;
- epoch reset invalidates pending;
- transformed-frame pacing;
- transform failure publishes nothing;
- concurrent timed-producer re-entry rejection;
- structured allocation-failure boundary.

No wall-clock sleep is used in Stage F1 tests.

## Regressions

Validated on F1 implementation head:

- Stage A: **PASS** — 13 / 13
- Stage B: **PASS** — 10 / 10
- Stage C1 queue: **PASS** — 18 / 18
- Stage C1 normalizer: **PASS** — 17 / 17
- Stage D1: **PASS** — 19 / 19
- Stage D2 consumer: **PASS** — 5 / 5
- Stage D2 queue stress: **PASS** — 8 / 8
- Stage D2 pipeline stress: **PASS** — 5 / 5
- Stage E1 transformer: **PASS** — 27 / 27
- Stage E1 pipeline: **PASS** — 3 / 3
- ASan/UBSan queue regression: **PASS**

Historical Stage D1/D2/E1 workflows/tests were not weakened.

## Consumer isolation

The consumer-only archive remains:

- `PreparedFrame`
- `ReadyFrameQueue`

It has no dependency on:

- `FrameTimelineScheduler`;
- `FramePipelinePumpTimed`;
- AVAssetReader;
- AVFoundation;
- Accelerate/vImage;
- FrameTransformer;
- host-clock acquisition APIs;
- sleep/timer APIs;
- injector/hook code;
- network/backend code.

`ReadyFrameQueue::tryAcquire()` remains bounded and nonblocking.

## iOS 15 / arm64 build proof

CI production compile uses:

- `-arch arm64`
- `-miphoneos-version-min=15.0`
- `-Werror`
- `-Werror=unguarded-availability-new`
- `-pedantic`

Results:

- `libVCAMConsumerFastPathF1.a`: arm64
- `libVCAMFrameEngineStageF1.a`: arm64
- all inspected F1 production objects: minimum iOS 15.0
- no arm64e requirement
- no private framework/API
- no deployment target increase

Undefined-symbol inspection confirms the scheduler owns no clock/thread/timer primitive.

## CI evidence

Implementation validation:

- workflow: `Frame Engine Stage F1 CI`
- run: `36194167388`
- head: `990af3ba403243ae308a8cfa90dcd10cc7cbe46d`
- conclusion: **SUCCESS**

Artifact:

- name: `vcam-frame-engine-stage-f1-validation`
- artifact ID: `10889431031`
- digest: `sha256:0d337a49212e3773ce9307baece1e9d9a5695115a20cef3fe8b33d9872d3de61`

The proof-only commit containing this record must rerun the same F1 CI before promotion. Its terminal run is reported in the Builder return.

## What remains runtime / later-stage work

Stage F1 does not prove or implement:

- final camera callback timing;
- final camera CMSampleTimingInfo;
- final injected CMSampleBuffer PTS;
- callback cadence in mediaserverd;
- A9 real-device pacing/performance;
- control-layer wakeup/timer driver;
- cross-process data plane;
- injector;
- frame substitution.

Explicitly:

- **NOT Gate 1**
- **NOT Gate 2**
- **NOT Gate 3**
- **NOT callback timing proof**
- **NOT A9 performance proof**
- **NOT final cross-process data plane**
- **NOT final Control timer/driver**
