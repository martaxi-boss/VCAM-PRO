# VCAM PRO — Post-Photo Local Media Final Convergence 001

Task: `VCAM-PRO-POST-PHOTO-LOCAL-MEDIA-FINAL-CONVERGENCE-001`

## Exact baseline and immutable references

- Starting VCAM PRO HEAD: `4951d227ac8ea4425e969adeb46259293d1b7d6a`
- main: `d476caacc4f557843f9551533c2fcbe7c5d40baa`
- IOS-15-USB: `a908bccbcddb4efc072bb1bc8fbeb6ee89b1af9d`
- MotionCam-iOS: `5ede3a1973a01cb13fe7f3ab562b47513feec1b1`
- IOS-16-USB-4k: `cc20d787070c67565173d4a46c218e2549cecc93`
- Owner physical baseline package: `0.1.0+roothide19~geomws2`

All three reference repositories remain read-only.

## Owner device evidence entering this task

Target device: iPhone 6s Plus / A9 / iOS 15.8.8 / Dopamine rootless.

Accepted physical facts:

- VCAM OFF -> REAL: PASS
- VCAM ON + no media -> BLACK: PASS
- VCAM ON + selected PHOTO -> PHOTO appears: PASS
- PHOTO continuous presentation: PASS
- old large PHOTO -> BLACK -> PHOTO dropout: CLOSED
- tiny occasional PHOTO microflash/flicker remains, while PHOTO stays visible
- no observed BLACK frame or PHOTO disappearance during the tiny microflash
- WhatsApp video call physically received the VCAM PHOTO through the current central mediaserverd architecture
- remote WhatsApp image was observed approximately 90 degrees rotated
- possible remote crop/overscale was not conclusive

Canonical interpretation:

`PHOTO_DROPOUT_PRESENT=NO`

`CENTRAL_THIRD_PARTY_PATH_OBSERVED_WITH_WHATSAPP=PASS`

This evidence does not certify every third-party app.

## Stable PHOTO / microflash classification

Pre-fix host composition used the real product chain and warmed two PHOTO geometries before a long alternating decision sequence.

Observed after warm-up:

- PreparedMedia decisions remained continuous
- media decision delta: 128
- BLACK decision delta: 0
- InPlaceBlackOwnershipGuard delta: 0
- emergency ORIGINAL delta: 0
- unsupported-format delta: 0
- prepared geometry switches observed: 127

Therefore:

- `PHOTO_PREPARED_MEDIA_DECISIONS_CONTINUOUS=PASS`
- `PHOTO_STABLE_BLACK_DECISION_DELTA=0`
- `PHOTO_STABLE_GUARD_DECISION_DELTA=0`
- `PHOTO_STABLE_ORIGINAL_DECISION_DELTA=0`
- `PHOTO_MICROFLASH_NOT_OWNERSHIP_FALLBACK=PASS`
- `PHOTO_DROPOUT_PRESENT=NO`

Final task classification is deliberately conservative:

`PHOTO_MICROFLASH_CLASSIFICATION=PRESENTATION_LEVEL_OR_RUNTIME_ONLY_UNRESOLVED`

The task did not modify PHOTO BLACK ownership or the proven PHOTO working-set architecture to chase this residual presentation symptom.

## PHOTO architecture preserved

The remediation preserves:

- one logical PHOTO source/session
- one source PHOTO decode
- adaptive PHOTO geometry working set
- 12 prepared structural slots
- 32 MiB retained PHOTO variant budget
- safe BLACK under genuinely unavailable prepared output
- no supported VCAM-ON physical ORIGINAL decision
- StillImageKey path
- existing virtual-content commit into ORIGINAL camera-buffer identity
- producer-side PHOTO transforms
- no camera-callback decode/scale/transform

`LocalPhotoReader`, PHOTO `ReadyFrameQueue` semantics, the PHOTO memory budget, and `product/VCAMPro.plist` were not changed by this task.

## VIDEO selection and Loop pre-fix evidence

Deterministic pre-fix proof ran at `d90e23411f4869def234e54e77d9cc4583df6045`, CI run `36565212399`.

Selection/control path passed before any VIDEO architecture mutation:

- `VIDEO_PICKER_CLASSIFICATION=PASS`
- `VIDEO_LOAD_REPRESENTATION_KIND=VIDEO`
- `VIDEO_STAGING=PASS`
- `VIDEO_CONTROL_COMMIT=PASS`
- `VIDEO_MEDIA_KIND=VIDEO`
- `VIDEO_PLAYBACK_INTENT_AFTER_SELECTION=PLAYING`
- `VIDEO_LOOP_UI_ENABLED_WHEN_VIDEO_SNAPSHOT_ACTIVE=PASS`
- `VIDEO_LOOP_OFF_DOES_NOT_BLOCK_START=PASS`
- `VIDEO_REQUIRES_LOOP_TO_START=NO`

Therefore the earlier physical disabled/unresponsive Loop symptom did not reproduce as a picker/staging/control contract defect.

Loop semantics remain:

`VIDEO_LOOP_MEANING=EOS_RESTART_ONLY`

Loop OFF plays once. Loop ON restarts at EOS.

## VIDEO geometry pre-fix reproduction

Against the pre-fix production geometry behavior, one selected VIDEO was driven through A -> B -> A -> B without media reselection.

Measured:

- `PRE_FIX_VIDEO_SESSION_REBUILD_COUNT=3`
- `PRE_FIX_VIDEO_READER_REOPEN_COUNT=3`
- `PRE_FIX_VIDEO_AVASSETREADER_RESTART_COUNT=3`
- `PRE_FIX_VIDEO_TIMELINE_RESTART_OR_DISCONTINUITY=YES`
- `PRE_FIX_VIDEO_GEOMETRY_CHURN_REPRODUCED=YES`
- selectionGeneration remained stable

The first broken VIDEO stage was therefore:

`VIDEO_FIRST_BROKEN_STAGE=DESTINATION_GEOMETRY_CHANGE_REBUILT_LOGICAL_VIDEO_SESSION_AND_READER`

## VIDEO correction

VIDEO destination retargeting now stays inside the existing logical `InternalGalleryMediaSession`.

The correction preserves:

- one logical VIDEO session for one selected source
- one `LocalVideoReader`
- one underlying AVAssetReader start for geometry churn
- stable media selection generation
- stable source timeline epoch across destination retarget
- producer-side target changes through `FramePipelinePump`
- current temporal VIDEO semantics rather than PHOTO static-lease reuse

`FramePipelinePump::setTargetPreservingTimeline()` changes the prepared-output target without resetting the timed source context.

Geometry A/B output may briefly use safe virtual BLACK while a new target is not yet ready, but supported VCAM-ON does not expose physical ORIGINAL.

Post-fix host composition proved:

- `VIDEO_LOGICAL_SESSION_CREATION_COUNT=1`
- `VIDEO_READER_OPEN_COUNT=1`
- `VIDEO_READER_START_COUNT=1`
- `VIDEO_SELECTION_GENERATION_STABLE=PASS`
- `VIDEO_TIMELINE_CONTINUOUS=PASS`
- `VIDEO_SOURCE_PTS_MONOTONIC=PASS`
- `VIDEO_GEOMETRY_A_OUTPUT=PASS`
- `VIDEO_GEOMETRY_B_OUTPUT=PASS`
- `VIDEO_NO_RESTART_ON_GEOMETRY_SWITCH=PASS`
- `VCAM_ON_SUPPORTED_ORIGINAL_DECISIONS=ZERO`

Normal product lifecycle regressions also cover Pause, Resume, Loop, Clear, PHOTO -> VIDEO, VIDEO -> PHOTO, and VCAM OFF from VIDEO.

Production `LocalVideoReader` itself did not need architectural modification.

## MotionCam read-only comparison

Exact MotionCam reference: `5ede3a1973a01cb13fe7f3ab562b47513feec1b1`.

Reconfirmed comparison concepts:

- AVAsset
- AVAssetReader
- AVAssetReaderTrackOutput
- `alwaysCopiesSampleData = NO`
- `copyNextSampleBuffer`
- EOS handling
- reader start/stop/recreation lifecycle

VCAM PRO reused only the relevant local-media concepts. MotionCam process-local camera hooks, `g_vcamEnabled` ownership, picker limitations, and unrelated timing architecture were not transplanted.

## Stream orientation root-cause classification

The minimalism audit classified each candidate semantic before accepting new central state.

### A. Source preferredTransform

VIDEO already preserved `AVAssetTrack.naturalSize` and `preferredTransform`, and FrameTransformer already interpreted source preferred transforms.

PHOTO source orientation is normalized during ImageIO decode, after which the logical PHOTO source is upright.

Result:

`SOURCE_PREFERRED_TRANSFORM_STATUS=VIDEO_PRESERVED_PHOTO_NORMALIZED_UPRIGHT`

Source preferredTransform alone could not represent the destination camera-stream orientation that differed between consumers/device orientation.

### B. Destination orientation semantics

The old runtime geometry identity carried width, height and pixel format, but no destination stream/display orientation.

Result:

`DESTINATION_ORIENTATION_SEMANTICS_STATUS=MISSING_BEFORE_NOW_CENTRALIZED`

### C. Pixel/sample-buffer attachment source

The central ReferenceCameraHook did not expose a reliable stream-orientation attachment contract suitable for the product.

Result:

`BUFFER_ORIENTATION_ATTACHMENT_STATUS=NO_RELIABLE_STREAM_ORIENTATION_ATTACHMENT_IN_CURRENT_HOOK`

No expensive attachment parsing or per-app logic was added to the camera callback.

### D. Orientation/crop order

Existing source preferredTransform processing already preceded center-crop/scale. The new asymmetric fixtures explicitly prove source orientation composition followed by destination stream orientation and then the existing crop/scale path.

Result:

`ORIENTATION_CROP_ORDER_STATUS=STREAM_ROTATION_THEN_EXISTING_CENTER_CROP`

### E. Central orientation state

Because A-D did not supply the missing destination-stream semantic, one app-independent lightweight central orientation state was justified.

Result:

`CENTRAL_ORIENTATION_STATE_REQUIRED=YES`

`THIRD_PARTY_ORIENTATION_ROOT_CAUSE=MISSING_DESTINATION_STREAM_ORIENTATION_STATE`

## IOS-15-USB orientation forensic audit

The exact read-only IOS-15-USB recovered binary/source evidence was independently re-audited in the dedicated CI rather than copied from prior chat conclusions.

The recovered central render path confirms:

- virtual source converted to CIImage around `0x15e20` with `imageWithCVPixelBuffer:`
- `imageByApplyingOrientation:` call at `0x15ee8`
- orientation argument value `6` loaded at `0x15eec`
- crop follows orientation
- final render path targets the ORIGINAL camera pixel buffer

Required audit marker:

`IOS15_ORIENTATION_REFERENCE_AUDITED=PASS`

The product does **not** globally hardcode orientation 6. The recovered value is reference evidence for the historical central stream adaptation semantics.

## Central stream orientation implementation

One central, app-independent product model is used:

- Unknown
- Portrait
- PortraitUpsideDown
- LandscapeLeft
- LandscapeRight

SpringBoard supplies lightweight current device/interface orientation through the existing product control plane.

Orientation has an independent revision and does not change `selectionGeneration`.

SharedControlStore decoding remains backward-compatible.

Producer-side mapping prepares raw stream memory orientation through FrameTransformer. Source preferredTransform is applied first; stream orientation follows; then the existing crop/scale path produces destination geometry.

No WhatsApp, Apple Camera, Telegram, FaceTime or other bundle-specific branch was introduced.

No orientation pixel work was added to the camera callback.

## Asymmetric orientation and aspect proof

Directional fixtures contain distinguishable TOP/BOTTOM/LEFT/RIGHT content.

Host tests prove all supported central stream orientations:

- `STREAM_ORIENTATION_LANDSCAPE_LEFT=PASS`
- `STREAM_ORIENTATION_PORTRAIT=PASS`
- `STREAM_ORIENTATION_LANDSCAPE_RIGHT=PASS`
- `STREAM_ORIENTATION_PORTRAIT_UPSIDE_DOWN=PASS`
- `ASYMMETRIC_TOP_BOTTOM_LEFT_RIGHT_FIXTURE=PASS`
- `PHOTO_VIDEO_STREAM_ORIENTATION_COMPOSITION=PASS`
- `NO_APP_SPECIFIC_ORIENTATION_HACK=PASS`

The physical Owner report only established orientation failure on the old package. The corrected physical third-party orientation remains pending device proof.

## Aspect investigation

The task did not change framing based on the unconfirmed remote overscale/crop impression.

After orientation correction, the asymmetric host fixture showed no independent extra crop/overscale defect in the retained framing path.

Final host result:

- `ASPECT_RATIO_RESULT=NO_INDEPENDENT_ASPECT_DEFECT_IN_ASYMMETRIC_HOST_FIXTURE`
- `ASPECT_RATIO_SEMANTICS_FINAL=EXISTING_CENTER_CROP_PRESERVE_ASPECT`
- `NO_UNINTENDED_OVERSCALE_OR_CROP=HOST_FIXTURE_PASS`

Physical third-party framing remains reviewable during final device proof.

## Central Adjust Photo overlay

Before this task, PAN/PINCH lived only inside `InternalGalleryViewController`.

`PHOTO_GESTURE_SURFACE_BEFORE=CONTROL_PANEL_ONLY`

The implementation now exposes explicit **Adjust Photo** only for an active PHOTO.

Entering Adjust Photo:

- dismisses the control panel as needed
- temporarily installs a transparent full-screen interaction surface inside the existing `VCAMProductOverlayWindow`
- leaves the floating VCAM control and Done affordance above the interaction surface
- one-finger PAN updates existing `ProductPhotoTransform.translationX/Y`
- two-finger PINCH updates existing `ProductPhotoTransform.scale`
- no rotation recognizer or second transform model exists

Done removes the temporary surface and restores the existing overlay passthrough.

Result:

- `PHOTO_GESTURE_SURFACE_AFTER=CENTRAL_SPRINGBOARD_OVERLAY_ADJUST_MODE`
- `PHOTO_DIRECT_OVERLAY_PAN=PASS`
- `PHOTO_DIRECT_OVERLAY_PINCH=PASS`
- `NORMAL_APP_TOUCH_PASSTHROUGH=PASS`
- `ADJUST_MODE_TOUCH_CAPTURE=PASS`
- `DONE_RESTORES_PASSTHROUGH=PASS`
- `NO_APP_UI_PERMANENTLY_BLOCKED=PASS`
- `USER_ROTATION_GESTURE_PRESENT=NO`

All image transformation remains producer-side.

## Camera-critical-path contract

The reachable central hook/runtime/adapter path was re-audited.

PASS:

- no file I/O
- no PHOTO decode
- no scaling
- no FrameTransformer execution
- no color-conversion loop
- no media allocation
- no synchronous wait
- no direct PHOTO renderer
- no LocalVideoReader / AVAssetReader work

`CALLBACK_HEAVY_WORK=NO`

## Candidate certification before canonical-state reconciliation

Candidate source HEAD: `a4a28e2154687800e02f95dce73c6a900064209a`

Dedicated convergence CI:
- run `36575539839`
- conclusion: SUCCESS

Existing IOS15/MotionCam E2E:
- run `36575540014`
- conclusion: SUCCESS

Candidate package:

- Package: `com.vcampro.camera`
- Version: `0.1.0+roothide20~mediaconverge1`
- Architecture metadata: `iphoneos-arm64e`
- Mach-O: `arm64`
- Minimum iOS: `15.0`
- DEB: `VCAM-PRO-RootHide-Local-Media-Final-Convergence-001.deb`
- candidate size: `189840` bytes
- candidate SHA-256: `8d6988c10df00e463a43d1898503734e36df3889d991707992bf3b54ba6cdff3`
- candidate artifact ID: `11037995966`
- candidate artifact digest: `sha256:5fd076bc38aafea0a47b771aa1bd53e6f9ead04d96afb0e20d65d9963596387c`

This candidate certification is pre-documentation. The terminal task requires exact-head recertification after canonical-state documentation changes.

## Host/CI proof versus pending physical proof

Host/CI proves the source contracts, orientation pixel mappings, VIDEO lifecycle invariants, callback constraints, packaging and overlay topology.

The following remain **PENDING_DEVICE_PROOF** for the corrected package:

- physical WhatsApp orientation correction
- physical VIDEO output
- physical PAN/PINCH interaction
- whether the residual tiny microflash is visually improved/unchanged
- physical third-party aspect/framing confirmation

No Builder device action occurred in this task.
