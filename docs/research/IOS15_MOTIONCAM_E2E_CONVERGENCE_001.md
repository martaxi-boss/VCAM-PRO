# IOS15 + MotionCam End-to-End Convergence 001

Task: VCAM-PRO-IOS15-CENTRAL-MOTIONCAM-LOCAL-GALLERY-E2E-CONVERGENCE-001

## Exact references

- IOS-15-USB: `a908bccbcddb4efc072bb1bc8fbeb6ee89b1af9d`
- MotionCam-iOS: `5ede3a1973a01cb13fe7f3ab562b47513feec1b1`
- IOS-16-USB-4k: `cc20d787070c67565173d4a46c218e2549cecc93` (optional compatibility reference only)

All three references are read-only. The only mutable repository is `martaxi-boss/VCAM-PRO`.

## IOS-15-USB central-camera findings

### Injection topology

The canonical VCAM-PRO filter matches the IOS-15-USB topology:

- Bundles: `com.apple.mediaserverd`, `com.apple.springboard`, `com.apple.UIKit`
- Executables: `mediaserverd`

VCAM-PRO continues to use `product/VCAMPro.plist` as the single product filter source.

### Central hook and return identity

Recovered IOS-15-USB evidence establishes:

- `CMSampleBufferGetImageBuffer` is the central MSHookFunction target.
- Historical replacement address: `0x175d4`.
- The replacement inspects `StillImageKey` through `CMGetAttachment`.
- The historical virtual-content path renders/copies virtual pixels into the ORIGINAL camera pixel buffer.
- The historical return identity remains the ORIGINAL camera pixel buffer.

VCAM-PRO preserves the same central ownership shape: prepared virtual content is committed into the camera-shaped original buffer and the original identity is returned after successful ownership commit.

### frameQueue / lastObject comparison

IOS-15-USB uses `frameQueue -> lastObject` as a latest-visual-source model. Its semantics are naturally reusable for a static visual source.

VCAM-PRO's `ReadyFrameQueue` is intentionally stricter:

- generation-aware;
- timeline-epoch-aware;
- lease-aware;
- non-blocking;
- consumable.

A `ReadyFrameLease` marks its queue entry consumed when released. That behavior remains correct for VIDEO progression, but it is not sufficient by itself for a selected static PHOTO that must remain visible across camera callbacks.

The E2E composition run `36443554542` at commit `62048f0788fe98df74b5906e4850de06a6638add` proved every PHOTO stage through first output pixels, then failed at the next paused callback because the first consumable lease no longer supplied `PreparedMedia`. This identifies the first broken production stage as PHOTO latest-frame persistence after initial lease consumption.

The selected correction is therefore PHOTO-specific: a generation/epoch-bound reusable prepared lease plus single publication of the decoded static photo. VIDEO queue consumption/progression is unchanged.

## Active-mode ownership finding

Before convergence, `CameraConsumerAdapter::blackOrEmergencyOriginal` could return ORIGINAL when VCAM was enabled and no compatible cached BLACK existed. `MediaserverdRuntime::observeRealCameraBuffer` only scheduled BLACK preparation asynchronously after observing a new supported geometry.

Therefore, on the same first callback for a new supported 420v/420f geometry, the normal path could expose ORIGINAL pixels before the reusable BLACK existed.

The convergence correction keeps BLACK allocation/preparation outside the callback and uses a bounded in-place ownership guard for the already supplied original 420v/420f pixel buffer:

- 420v: Y=16, Cb/Cr=128
- 420f: Y=0, Cb/Cr=128

No allocation, decode, scale, file I/O or media wait is introduced into the camera callback. Unsupported formats remain explicitly classified instead of being falsely certified.

## StillImageKey relevance

`StillImageKey` remains a central IOS-15-USB parity fact. Same-geometry prepared PHOTO/BLACK content is committed into the original camera buffer. When a first-ever supported still geometry appears before a prepared variant exists, active ownership safety is provided by the same in-place BLACK guard while producer-side preparation can proceed asynchronously.

This proves the code path cannot deliberately return physical pixels for supported 420v/420f while enabled. It does not convert host/static evidence into a physical flash-device PASS.

## MotionCam-iOS local-source findings

### Gallery selection

MotionCam's `Tweak.xm` demonstrates local media acquisition concepts including:

- `UIImagePickerController`;
- `SavedPhotosAlbum`;
- media type inspection including `public.movie`;
- copying the selected temporary picker URL to an app-owned local file before long-lived playback;
- handing that owned local file to its media manager.

VCAM-PRO reuses the durable local-file ownership principle, but keeps its existing ProductControlOwner / SharedMediaStager / SharedControlStore architecture and supports both PHOTO and VIDEO.

### AVAssetReader

MotionCam's `MediaManager` demonstrates:

- `AVAsset`;
- `AVAssetReader`;
- `AVAssetReaderTrackOutput`;
- `alwaysCopiesSampleData = NO`;
- 420-family decode output;
- `copyNextSampleBuffer`;
- reader recreation for looping;
- start/stop lifecycle.

VCAM-PRO retains its existing LocalVideoReader / FramePipelinePump / ProducerWakeupDriver design and only uses these MotionCam findings as reference confirmation for local decode and loop behavior.

### Loop and timing

MotionCam uses wall-clock-oriented output retiming, including `CACurrentMediaTime` concepts. VCAM-PRO does not copy that timing contract automatically. VCAM-PRO preserves its explicit FrameTimelineScheduler and producer timing unless a concrete defect requires a timing change.

## MotionCam techniques intentionally not reused

The following are not adopted:

- process-local `g_vcamEnabled` as the final ownership architecture;
- application/AVCaptureSession-specific final camera hooks;
- MotionCam's video-only picker limitation;
- automatic replacement of VCAM-PRO timing with MotionCam wall-clock retiming;
- any black-frame range behavior that conflicts with VCAM-PRO's explicit 420v/420f ownership values;
- any architecture that moves decode, file I/O, scaling, PAN or PINCH into the camera callback.

## Convergence model

Final intended composition:

`LOCAL IPHONE GALLERY -> Product Control -> Local Media Engine -> Frame Engine -> CameraConsumerAdapter -> IOS15 central CMSampleBufferGetImageBuffer ownership -> ORIGINAL camera buffer identity`

PHOTO PAN/PINCH is producer-side only. Rotation is not a product control and `UIRotationGestureRecognizer` is not used.

## Required residual device fact

After exact-head CI and package audit, physical Apple Camera proof remains separate from code/static certification. The final device session must confirm end-to-end local media ownership on the target iPhone and classify any remaining device-only geometry behavior without reopening already-proven static stages.
