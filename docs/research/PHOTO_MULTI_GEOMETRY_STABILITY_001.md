# PHOTO Multi-Geometry Stability 001

Task: `VCAM-PRO-PHOTO-MULTI-GEOMETRY-STABILITY-REMEDIATION-001`

## Exact starting state

- VCAM-PRO starting HEAD: `f66d0b271e6dc4bdec53cea8ac709dffc363e4fa`
- main: `d476caacc4f557843f9551533c2fcbe7c5d40baa`
- IOS-15-USB: `a908bccbcddb4efc072bb1bc8fbeb6ee89b1af9d`
- MotionCam-iOS: `5ede3a1973a01cb13fe7f3ab562b47513feec1b1`
- IOS-16-USB-4k: `cc20d787070c67565173d4a46c218e2549cecc93`

All reference repositories remain read-only.

## Authoritative device observation

Target device: iPhone 6s Plus, A9, iOS 15.8.8, Dopamine / RootHide.

The E2E Convergence 001 candidate `0.1.0+roothide16~e2econverge1` established:

- VCAM OFF -> REAL stable: PASS.
- VCAM ON + no media -> BLACK stable: PASS.
- Focus/touch no longer showed an obvious physical-scene flash: material improvement.
- A selected local PHOTO reached Apple Camera, proving gallery selection, staging, decode and central output.
- PHOTO presentation was intermittent: BLACK -> brief PHOTO -> BLACK -> brief PHOTO -> BLACK.

This remediation therefore does not reopen picker, staging, file ownership or initial PHOTO decode.

## Pre-fix source mechanism

At the starting HEAD, `MediaserverdRuntime::observeRealCameraBuffer()` stored one mutable global `observedGeometry_` and enqueued asynchronous work that later re-read that global.

A geometry event A followed quickly by B could therefore enqueue two work items that both operated as B by execution time.

The geometry work called `applyCachedState(true)`. For PHOTO that rebuilt the complete `InternalGalleryMediaSession`, reopened/reselected the PHOTO, produced a different `ReadyFrameQueue`, and rebound the adapter.

The adapter retained only one reusable static lease and treated queue pointer replacement as identity change. Therefore a geometry-driven session replacement could destroy the retained PHOTO even though selection generation, timeline epoch, media path and transform were unchanged.

## Objective pre-fix reproduction

Historical pre-fix evidence is bound to commit:

`7fff0911feab0d754721ae5322256999cd7a5ac9`

CI run:

`36488758172`

Real-product composition used ProductControlOwner, SharedMediaStager, SharedControlStore, MediaserverdRuntime, the real InternalGalleryMediaSession, FramePipelinePump, ReadyFrameQueue and CameraConsumerAdapter. It did not manually construct the session or bind the adapter.

Observed markers:

- `PRE_FIX_MULTI_GEOMETRY_REPRODUCED=PASS`
- `PRE_FIX_SESSION_CHURN_REPRODUCED=PASS`
- `PRE_FIX_REDECODE_REPRODUCED=PASS`
- `PRE_FIX_GLOBAL_GEOMETRY_ALIASING_REPRODUCED=PASS`
- `PRE_FIX_LOGICAL_SESSION_CREATION_COUNT=6`
- `PRE_FIX_TOTAL_PHOTO_DECODE_COUNT=6`

This confirms the Supervisor hypothesis.

## First broken stage

`STATIC_PHOTO_PRESENTATION_ACROSS_CAMERA_GEOMETRY_TRANSITIONS`

The logical local PHOTO source itself was correct. The defect was the relationship between geometry events, session lifetime, prepared-target lifetime and reusable PHOTO selection.

## IOS-15-USB semantic

The IOS-15-USB reference establishes:

- central `CMSampleBufferGetImageBuffer` ownership;
- `frameQueue -> lastObject` as the persistent latest virtual visual source;
- virtual content is adapted into the current ORIGINAL camera pixel buffer;
- ORIGINAL buffer identity is returned;
- `StillImageKey` is handled within the same central hook.

The relevant semantic is that a logical virtual source is not deselected merely because destination camera geometry changes.

VCAM-PRO preserves that semantic while keeping decode and transform outside the camera callback.

## Chosen architecture

### One logical PHOTO session

A geometry transition no longer rebuilds the logical selected PHOTO session when media identity is unchanged.

The same `LocalPhotoReader` remains open and retains the single decoded PHOTO source.

### Immutable geometry work items

Each asynchronous geometry request captures the `GeometryKey` that caused it.

A queued A request remains A even if B is observed before the control queue executes.

`observedGeometry_` remains useful as last-observed telemetry, but it is no longer the sole identity of queued geometry work.

### Producer-side target preparation

For a missing supported target, the live PHOTO session retargets its existing `FramePipelinePump` producer-side and publishes one prepared frame for that geometry.

No source reopen or ImageIO re-decode occurs for A -> B -> A -> B.

### Bounded reusable PHOTO variants

`CameraConsumerAdapter` retains a fixed capacity of four reusable PHOTO variants keyed by:

- media generation;
- timeline epoch;
- photo transform revision;
- width;
- height;
- pixel format.

The callback performs a bounded fixed-array search. A matching retained PHOTO variant returns PreparedMedia immediately.

If no retained variant exists, the adapter performs a geometry-aware non-blocking queue acquisition. The prepared pixel storage is retained in the bounded variant cache.

Eviction is deterministic LRU within the fixed four-slot cache. There is no unbounded map or cache expansion.

### Transform invalidation

The photo transform revision is part of the reusable static identity. PAN/PINCH changes invalidate stale transform variants and producer-side preparation rebuilds the needed transformed target.

### BLACK while a new target is pending

For a first encounter with a supported geometry that has not yet been prepared:

- compatible cached BLACK may be used;
- otherwise the existing in-place BLACK ownership guard applies.

ORIGINAL remains prohibited for supported 420v/420f while VCAM is enabled.

Once the target variant is prepared, the next compatible callback returns PHOTO.

## Post-fix host proof

The fixed composition test covers:

- 420f geometry A and B;
- 420v geometry A and B;
- 420f <-> 420v preparation;
- A/B/A/B warm returns;
- fifth geometry bounded eviction;
- deliberately queued A then B events while control work is suspended.

Verified host behavior:

- PHOTO-A visible.
- B uses virtual BLACK only while first preparation is pending.
- PHOTO-B becomes visible after preparation.
- Returning to cached A remains PHOTO.
- Returning to cached B remains PHOTO.
- Logical PHOTO session creation count remains 1.
- Source decode count remains 1.
- Cached geometry returns do not republish/redecode.
- Geometry event identity is preserved.
- Variant cache remains bounded at 4.
- Supported enabled callbacks do not return ORIGINAL.

## MotionCam relevance

No new MotionCam lifecycle defect was established.

The already-adopted local-source concepts remain sufficient:

- local owned file;
- one PHOTO decode retained locally;
- LocalVideoReader AVAssetReader lifecycle.

No process-local MotionCam hook, application-specific hook or new media-selection architecture is introduced.

`MOTIONCAM_RELEVANCE=NO_NEW_LOCAL_MEDIA_LIFECYCLE_DEFECT_ESTABLISHED`

## Callback performance properties

The camera callback remains bounded to:

- control/atomic reads;
- try-lock of existing adapter state;
- fixed-size geometry comparisons;
- fixed four-slot variant scan;
- non-blocking geometry-aware ReadyFrameQueue acquisition;
- choosing PreparedMedia, BLACK or in-place BLACK ownership guard;
- existing prepared-pixel commit semantics in the central hook.

The callback performs no:

- file I/O;
- image decode;
- source reopen;
- FrameTransformer execution;
- CVPixelBufferPool construction;
- AVAsset creation;
- dispatch_sync;
- sleep/wait;
- unbounded cache lookup/allocation.

## Physical proof boundary

Host/static evidence proves the corrected geometry/session ownership model. Physical Apple Camera stability for real preview/still/flash geometry interleaving remains a device-only fact and is reserved for:

`PHOTO_MULTI_GEOMETRY_STABILITY_DEVICE_PROOF`
