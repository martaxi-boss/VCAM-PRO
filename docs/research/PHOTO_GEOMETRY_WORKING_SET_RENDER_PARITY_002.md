# VCAM PRO — PHOTO GEOMETRY WORKING-SET / IOS15 RENDER PARITY REMEDIATION 002

TASK_ID=VCAM-PRO-PHOTO-GEOMETRY-WORKING-SET-RENDER-PARITY-REMEDIATION-002

## Starting state

STARTING_HEAD=fcb873e60772b0258e8e6c57a97fdcf82c020613

MAIN=d476caacc4f557843f9551533c2fcbe7c5d40baa

IOS15_USB=a908bccbcddb4efc072bb1bc8fbeb6ee89b1af9d
MOTIONCAM=5ede3a1973a01cb13fe7f3ab562b47513feec1b1
IOS16_USB=cc20d787070c67565173d4a46c218e2549cecc93

Starting tested package:
0.1.0+roothide17~multigeom1

## Authoritative device result

PHOTO_MULTI_GEOMETRY_STABILITY_DEVICE_PROOF=FAIL

Observed on iPhone 6s Plus / A9 / iOS 15.8.8 / Dopamine RootHide:

- VCAM OFF -> REAL stable: PASS
- VCAM ON + no media -> BLACK stable: PASS
- selected PHOTO reaches Apple Camera: PASS
- ordinary physical-frame suppression: materially improved and preserved
- continuous PHOTO presentation: FAIL
- repeated visible sequence: BLACK -> brief PHOTO -> BLACK -> later PHOTO -> BLACK

This evidence does not reopen gallery selection, staging, local PHOTO decode or central hook reachability.

## Deterministic pre-fix reproduction

Production source remained byte-for-byte at the starting implementation while the reproduction-only test was added.

Pre-fix test commit:
3b6e69b8dd3978779143842340afd0b8c64c3915

Pre-fix CI:
36534864302 = SUCCESS

Exact evidence:

PRE_FIX_WORKING_SET_REPRODUCED=PASS
PRE_FIX_VARIANT_CAPACITY=4
PRE_FIX_UNIQUE_GEOMETRIES=5
PRE_FIX_RETURN_TO_EVICTED_GEOMETRY_BLACK=YES
PRE_FIX_REPREPARATION_COUNT=5
PRE_FIX_VARIANT_EVICTION_COUNT=6
PRE_FIX_PHOTO_TO_BLACK_OSCILLATION_REPRODUCED=PASS
PRE_FIX_PHOTO_LOGICAL_SESSION_CREATION_COUNT=1
PRE_FIX_PHOTO_SOURCE_DECODE_COUNT=1
PRE_FIX_ORIGINAL_DECISION_COUNT=0
PRE_FIX_RAPID_GEOMETRY_INTERLEAVING=PASS
PRE_FIX_NO_GEOMETRY_EVENT_ALIASING=PASS

The deterministic sequence A/B/C/D/E/A/B/C/D/E therefore proved the device-compatible source mechanism rather than merely inferring it from the fixed capacity.

## Root cause

The previous PHOTO cache was a four-slot pre-rendered destination cache. ReadyFrameQueue entries are consumable; after an entry is acquired and retained by CameraConsumerAdapter, destruction of the ReadyFrameLease marks that queue entry consumed. Once a retained geometry was later evicted from the four-slot adapter cache, a return to that GeometryKey had neither a retained variant nor a reusable queue entry.

The resulting product behavior was:

return to evicted geometry
-> retained variant miss
-> matching ReadyFrameQueue miss
-> BLACK ownership path
-> asynchronous producer-side reprepare
-> later PHOTO

This repeated for a recurring working set larger than four.

ROOT_CAUSE=FIXED_FOUR_SLOT_PRE_RENDERED_PHOTO_CACHE_COULD_NOT_PRESERVE_A_RECURRING_CAMERA_GEOMETRY_WORKING_SET_AFTER_READYFRAMEQUEUE_CONSUMPTION

## IOS15 reference semantic

The IOS-15-USB reference establishes:

frameQueue -> lastObject -> persistent logical visual source
-> render/adapt into CURRENT ORIGINAL camera destination buffer
-> return ORIGINAL buffer identity.

IOS15_RELEVANT_DIFFERENCE=PERSISTENT_LOGICAL_SOURCE_IS_INDEPENDENT_OF_FIXED_PRE_RENDERED_GEOMETRY_SLOT_COUNT

VCAM PRO may retain pre-rendered variants as an optimization, but reaching that optimization's storage boundary must not invalidate the logical PHOTO.

## Adaptive bounded working set

The primary correction is an adaptive bounded PHOTO geometry working set.

Current bounds:

- PHOTO pre-rendered structural slots: 12
- PHOTO retained pixel-buffer byte budget: 32 MiB
- geometry working-set metadata entries: 16
- active observation window: 32 observations

The retained byte budget uses actual CVPixelBuffer footprint rather than slot count alone. Geometry observations are tracked producer/control-side. Eviction prefers stale logical identity and cold/non-active geometry before active recurring geometry.

The camera callback scans only fixed bounded state and uses try-lock behavior. Working-set growth, admission and producer transforms stay outside the camera callback.

A five-geometry recurring set that fits the budget converges and remains continuously admissible after warm-up.

## Overflow gate and IOS15 direct render parity

Stress above the safe pre-rendered retained working-set boundary established that pre-rendered retention alone cannot provide semantic continuity without unbounded memory.

IOS15_DIRECT_RENDER_FALLBACK_REQUIRED=YES
IOS15_DIRECT_RENDER_FALLBACK_USED=YES

The overflow path therefore keeps one persistent decoded PHOTO source and prepares bounded per-geometry render plans outside the callback. The callback writes directly into the already-supplied ORIGINAL camera destination and returns ORIGINAL buffer identity.

No new camera hook target was introduced. CMSampleBufferGetImageBuffer remains central and StillImageKey remains on the common hook path.

The fallback uses:

- direct render geometry plan capacity: 16
- render mapping byte budget: 16 MiB
- compact producer-side decoded PHOTO snapshot budget: 24 MiB
- no callback output CVPixelBuffer allocation
- no callback file I/O
- no callback PHOTO decode
- no AVAsset creation
- no CIContext creation
- no synchronous dispatch/wait
- no unbounded collection growth

The producer-side compact NV12 snapshot exists because callback-side access to the retained decoded CVPixelBuffer was not deterministic in the host/runtime-faithful path. The source is copied once per logical PHOTO/transform identity outside the callback.

A defect in the direct-plan implementation was also found and corrected: ComputeDirectRegions validated its local result but did not assign it back to the output parameter. That produced a nominally valid zero-sized render plan. The fix commits the computed regions before returning success.

## Primary fixed evidence

Primary working-set/render-parity gate:

CI_RUN=36543614348
CI_CONCLUSION=SUCCESS
HEAD=c8d9c399f33b2e0257aadc75e4327bbc8fe49730

Observed markers:

A_B_C_D_WITHIN_CACHE=PASS
FIFTH_GEOMETRY_BEHAVIOR=PASS
RETURN_TO_EVICTED_GEOMETRY=PASS
FIVE_GEOMETRY_CONTINUOUS_CYCLE=PASS
RAPID_GEOMETRY_INTERLEAVING=PASS
NO_REPEATED_BLACK_AFTER_GEOMETRY_WARMUP=PASS
PHOTO_ACTIVE_WORKING_SET_RETAINED=PASS
PHOTO_VARIANT_MEMORY_BOUNDED=PASS
PHOTO_VARIANT_STRUCTURAL_BOUND=PASS
PHOTO_SOURCE_DECODE_COUNT=1
PHOTO_LOGICAL_SESSION_CREATION_COUNT=1
NO_GEOMETRY_EVENT_ALIASING=PASS
NO_ORIGINAL_WHILE_ON=PASS
OVER_BUDGET_STRESS=PASS
IOS15_DIRECT_RENDER_FALLBACK_REQUIRED=YES
IOS15_DIRECT_RENDER_FALLBACK_USED=YES
DIRECT_RENDER_OVERFLOW_CONTINUITY=PASS
DIRECT_RENDER_HOST_BENCHMARK=PASS
DIRECT_RENDER_HOST_AVERAGE_NS=12328212
OVER_BUDGET_RETAINED_BYTES=6229440
DIRECT_RENDER_COUNT=21
DIRECT_RENDER_SCRATCH_BYTES=215208
NO_CALLBACK_UNBOUNDED_ALLOCATION=PASS
NO_CALLBACK_SYNCHRONOUS_WAIT=PASS

The host benchmark is a regression/performance bound for this implementation, not A9 device-performance certification.

## Component scope

ReferenceCameraHook changed only because the overflow gate objectively required DirectRenderedPhoto to be recognized as an already-committed virtual decision. It does not create another hook or app-specific path.

InternalGalleryMediaSession exposes the already-decoded PHOTO pixel storage to the product runtime. It does not re-read or re-decode the source for geometry changes.

LocalPhotoReader decode implementation remains unchanged.
LocalVideoReader remains unchanged.
ReadyFrameQueue remains unchanged by this remediation.
ProductControl schema, picker/stager and gesture UI are not redesigned.

MOTIONCAM_RELEVANCE=NONE_FOR_CURRENT_PERSISTENCE_DEFECT

## Runtime-only boundary

Host/CI can certify the working-set mechanism, source decode count, session lifetime, memory bounds, overflow rendering, ownership decisions and package structure.

Only the physical iPhone can certify continuous Apple Camera preview/still/flash behavior under real mediaserverd geometry interleaving and A9 performance.

NEXT_PHASE=PHOTO_CONTINUOUS_PRESENTATION_DEVICE_PROOF

## Supervisor camera-critical-path audit addendum - remediation 003

The d71c3ecdf2860ed078d1c7a42a020a366c7b0328 candidate was CI-green for the working-set/render-parity task but is rejected for device certification because CameraConsumerAdapter::decide() synchronously called renderDirectPhotoIntoOriginalLocked() from the CMSampleBufferGetImageBuffer camera-critical path.

That overflow fallback performed destination BLACK initialization, source-row/source-column remapping, per-pixel Y and CbCr writes, and range conversion in the callback. Exact-head run 36544809862 measured DIRECT_RENDER_HOST_AVERAGE_NS=19030941 (about 19 ms per host callback), but the benchmark had no acceptance threshold and therefore did not certify A9 performance.

The same exact-head E2E run 36544809835 reported NO_CALLBACK_SCALE_OR_TRANSFORM=PASS using a validator that inspected only the literal HookedCMSampleBufferGetImageBuffer body. It did not inspect the synchronously reachable chain HookedCMSampleBufferGetImageBuffer -> MediaserverdRuntime::decideCameraBuffer -> Impl::decide -> CameraConsumerAdapter::decide -> renderDirectPhotoIntoOriginalLocked. That marker was a false negative.

Remediation 003 removes DirectRenderedPhoto, the callback-side direct renderer, source snapshots, render plans, mapping vectors and direct-render counters. The product path is one logical PHOTO -> producer-side bounded geometry preparation -> compatible PreparedMedia selection in callback.

If the bounded prepared working set is under pressure, the callback keeps virtual ownership with BLACK / InPlaceBlackOwnershipGuard while producer/control work prepares the requested geometry. It never scales, transforms, range-converts or decodes PHOTO content in the camera callback merely to preserve an artificial over-budget stress case.

The corrected E2E validator audits the full synchronous decision chain plus the adapter source that implements its helpers, and rejects direct-render machinery or callback-side scaling/transform/color-conversion/media-allocation/blocking tokens.

Historical working-set evidence and the five-geometry root cause remain unchanged.
