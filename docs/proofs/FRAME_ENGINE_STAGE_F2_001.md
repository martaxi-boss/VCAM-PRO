# VCAM PRO — Frame Engine Stage F2 Producer Wakeup Driver / Monotonic Clock 001

## Status

**STAGE F2 IMPLEMENTED — READY FOR FINAL CI / SUPERVISOR AUDIT**

Task:

`VCAM PRO — FRAME ENGINE STAGE F2 PRODUCER WAKEUP DRIVER / MONOTONIC CLOCK 001`

Accepted parent:

- PR #11
- branch `builder/frame-engine-stage-f1-timeline-001`
- exact parent head `26f9aa9eaee850daa589c47cae519cfa71306286`

Validated F2 implementation head before this proof-only commit:

`63f08dfe6d92ef6628b3d7f6fbe9382f0e224845`

The final F2 PR head is reported by PR metadata and the Builder return. A Git commit cannot embed its own final SHA without changing that SHA.

## Boundary

Stage F2 adds the local producer wakeup layer around accepted F1.

Accepted F1 remains responsible for:

- source-PTS mapping;
- `dueHostTimeNs`;
- one-frame pending state;
- late classification;
- generation/epoch handling;
- publication timing decision;
- `presentationTimestamp` policy.

Stage F2 does not move or rewrite those responsibilities.

Stage F2 owns:

- production monotonic host-time acquisition;
- one serial producer execution context;
- one reusable wakeup/timer source;
- start/stop lifecycle;
- arming/re-arming from F1 outcomes;
- idle/stopped behavior;
- avoidance of busy polling.

## Production files

Added:

- `src/frame_engine/MonotonicHostClock.h`
- `src/frame_engine/MonotonicHostClock.cpp`
- `src/media_engine/ProducerWakeupController.h`
- `src/media_engine/ProducerWakeupController.cpp`
- `src/media_engine/ProducerWakeupDriver.h`
- `src/media_engine/ProducerWakeupDriver.mm`

No accepted F1 scheduler, timed-pump, or queue source file is modified by Stage F2.

## Monotonic clock

Production clock API:

- `mach_absolute_time()`
- `mach_timebase_info()`

Ticks are converted into the F1 public unit:

**MONOTONIC HOST NANOSECONDS**

The conversion is checked integer arithmetic and does not use wall-clock/calendar time.

No:

- `gettimeofday`;
- `NSDate`;
- `CFAbsoluteTime`;
- `std::chrono::system_clock`;
- `CLOCK_REALTIME`.

## Wakeup / timer API

Production wakeup uses public libdispatch:

- `dispatch_queue_create(..., DISPATCH_QUEUE_SERIAL)`
- `dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, ...)`
- `dispatch_source_set_timer`
- `dispatch_time`

The driver owns:

- one serial producer queue;
- one reusable dispatch timer source.

No timer is created per frame.

## Serial producer contract

Each timer firing performs at most one controller event.

The production binding to accepted F1 is exactly one call site:

`pump_.pumpOnceAtHostTime(nowHostTimeNs)`

per wakeup processing turn.

No synchronous recursive pump call exists.

No catch-up while-loop exists.

No `sleep`, `usleep`, or busy-wait pacing exists.

The accepted F1 `ConcurrentProducerCallRejected` remains defensive only; F2 serialization is provided by the dedicated serial producer queue.

## WAIT re-arm policy

For:

`WaitingForPresentation`

the controller requires F1's `dueHostTimeNs`.

If:

`dueHostTimeNs > nowHostTimeNs`

F2 arms the reusable timer for that exact monotonic deadline.

If the due time is already due/past due, F2 arms an asynchronous immediate next producer turn.

It does not recursively call the pump.

## Continuation policy

A new asynchronous immediate producer turn is requested after:

- `Published`;
- `DroppedLate`;
- `LoopRestarted`;
- `QueueDropped`;
- `GenerationReset`;
- `EpochReset`.

Exactly one pump result is processed before re-arming.

No result triggers an internal multi-frame catch-up loop.

## NotReady / idle policy

`ProducerWakeupPolicy::notReadyRetryNs` is explicit configuration.

When playback remains `Playing`:

- non-zero policy -> arm one deadline at `now + notReadyRetryNs`;
- zero policy -> become idle rather than poll.

When playback is not `Playing`:

- start remains idle;
- a firing observed after playback becomes non-playing becomes idle;
- no timer spin occurs.

An explicit later `start()` can asynchronously kick the producer after playback becomes active again.

## End / fatal policy

`EndOfStream`:

- stops autonomous production;
- disarms the timer;
- invalidates prior lifecycle token;
- does not retry.

Fatal producer/timing states:

- stop the autonomous path;
- disarm the timer;
- invalidate prior lifecycle token;
- publish no new virtual frame.

Stage F2 does not implement camera fail-open itself. Existing architecture remains:

NO ELIGIBLE VIRTUAL FRAME -> future real-camera fallback.

## Start / stop / stale event safety

Start is idempotent while already armed.

Stop is idempotent.

A lifecycle token is advanced when starting a new lifecycle and when invalidating a stopped/failed/ended lifecycle.

A stale timer event carrying an old token is ignored.

The dispatch source is set to `DISPATCH_TIME_FOREVER` when disarmed.

Re-arming does not accumulate multiple active wakeups.

## Deterministic host test seam

`ProducerWakeupController` is platform-independent.

Tests inject:

- manual monotonic host time;
- scripted pump results;
- fake wakeup arming/firing.

No wall-clock sleep or real delayed dispatch is used by deterministic Stage F2 tests.

## Stage F2 deterministic tests

File:

`tests/media_engine/producer_wakeup_driver_stage_f2_tests.cpp`

Validated result:

**19 / 19 PASS**

Coverage includes:

- initial producer wakeup;
- exact WAIT deadline propagation;
- no firing before simulated due time;
- one pump call per simulated firing;
- no duplicate wakeup accumulation;
- asynchronous continuation after `Published`;
- `DroppedLate` continuation without synchronous catch-up;
- `LoopRestarted` continuation;
- `QueueDropped` continuation;
- explicit `NotReady` retry policy;
- zero-delay `NotReady` policy becomes idle;
- paused/non-playing state remains idle;
- stop cancels future producer execution;
- stale lifecycle event ignored;
- generation reset schedules only one next turn;
- epoch reset schedules only one next turn;
- fatal result stops without spin;
- end-of-stream stops without retry;
- playback transition after a pump becomes idle;
- repeated start/stop safety;
- already-due WAIT uses asynchronous immediate arm;
- arm failure becomes structured failed/stopped driver state.

## Accepted regression results

Validated on implementation head `63f08dfe6d92ef6628b3d7f6fbe9382f0e224845` by Stage F2 CI run `36199134359`:

- Stage F2 driver: **19 / 19 PASS**
- Stage F1 scheduler: **13 / 13 PASS**
- Stage F1 timed pipeline: **12 / 12 PASS**
- Stage A: **13 / 13 PASS**
- Stage B: **10 / 10 PASS**
- Stage C1 queue: **18 / 18 PASS**
- Stage C1 normalizer: **17 / 17 PASS**
- Stage D1: **19 / 19 PASS**
- Stage D2 consumer: **5 / 5 PASS**
- Stage D2 queue stress: **8 / 8 PASS**
- Stage D2 pipeline stress: **5 / 5 PASS**
- Stage E1 transformer: **27 / 27 PASS**
- Stage E1 pipeline: **3 / 3 PASS**

No previous accepted workflow/test is weakened to obtain this result.

## Consumer isolation

Consumer-only archive remains:

- `PreparedFrame`;
- `ReadyFrameQueue`.

Consumer path is checked to contain no dependency on:

- ProducerWakeupDriver / ProducerWakeupController;
- MonotonicHostClock;
- FrameTimelineScheduler;
- FramePipelinePump;
- LocalVideoReader / AVAssetReader / AVFoundation;
- FrameTransformer / Accelerate/vImage;
- mach host-clock APIs;
- libdispatch timer APIs;
- sleep APIs;
- injector/hook APIs;
- network/backend APIs.

`ReadyFrameQueue::tryAcquire()` is unchanged.

## iOS 15 arm64 build proof

Stage F2 production objects compile with:

- `-arch arm64`;
- `-miphoneos-version-min=15.0`;
- `-Werror`;
- `-Werror=unguarded-availability-new`;
- `-pedantic`.

Validated archive:

`libVCAMProducerWakeupStageF2.a`

Result:

- architecture: **arm64**
- minimum iOS: **15.0**
- no arm64e requirement
- no deployment-target increase
- no private framework/API

Undefined-symbol inspection confirms the expected public dependencies:

- `_mach_absolute_time`
- `_mach_timebase_info`
- `_dispatch_source_create`
- `_dispatch_source_set_timer`

Consumer archive:

`libVCAMConsumerFastPathF2.a`

Result:

- architecture: arm64
- min iOS 15.0
- no F2 producer/clock/timer dependency

## CI evidence

Implementation validation:

- workflow: `Frame Engine Stage F2 CI`
- run: `36199134359`
- head: `63f08dfe6d92ef6628b3d7f6fbe9382f0e224845`
- conclusion: **SUCCESS**

Artifact:

- name: `vcam-frame-engine-stage-f2-validation`
- artifact ID: `10891023104`
- digest: `sha256:48ab994be74562acd5d0a8dc628ba560b114f3f520820c2fb33179a9f78e247f`

The proof-only commit containing this record must rerun the same Stage F2 CI before promotion. The terminal run for the final PR head is reported in the Builder return.

## Explicit non-claims

Stage F2 is:

- **NOT Gate 1**
- **NOT Gate 2**
- **NOT Gate 3**
- **NOT callback timing proof**
- **NOT A9 performance proof**
- **NOT cross-process data plane**
- **NOT injector implementation**

It does not implement:

- mediaserverd hooks;
- camera callbacks;
- CMSampleBuffer substitution;
- final camera CMSampleTimingInfo;
- final injected camera PTS;
- IOSurface IPC/data plane;
- UI;
- backend/networking;
- device work.
