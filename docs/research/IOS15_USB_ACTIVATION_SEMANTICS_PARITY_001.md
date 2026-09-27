# iOS 15 USB Activation Semantics Parity 001

## Authority and reference

Owner-authoritative activation contract:

- VCAM OFF -> ORIGINAL camera.
- VCAM ON + no media -> BLACK virtual.
- VCAM ON + media selected but not ready -> BLACK virtual.
- VCAM ON + photo ready -> PHOTO virtual.
- VCAM ON + video ready -> VIDEO virtual.
- VCAM ON + Clear Media -> BLACK virtual.
- VCAM OFF from any state -> ORIGINAL immediately.

Read-only reference:

- repository: `martaxi-boss/IOS-15-USB`
- exact SHA: `a908bccbcddb4efc072bb1bc8fbeb6ee89b1af9d`

## Verified reference evidence

Recovered filter topology:

- Bundles:
  - `com.apple.mediaserverd`
  - `com.apple.springboard`
  - `com.apple.UIKit`
- Executables:
  - `mediaserverd`

This supports the existing VCAM PRO central mediaserverd topology and does not justify per-app hooks.

Recovered strings include:

- `frameQueue`
- `clearQueue`
- `isLive`
- `setIsLive:`
- `CIContext`
- `imageWithCVPixelBuffer:`
- `render:toCVPixelBuffer:`

Recovered imports include:

- `CMSampleBufferGetImageBuffer`
- `CMSampleBufferCreateReady`
- `CMBlockBufferCreateWithMemoryBlock`
- `MSHookFunction`
- CoreVideo pixel-buffer APIs
- `VTPixelTransferSessionCreate`
- `VTPixelTransferSessionTransferImage`

Evidence limitation:

- `analysis/disassembly/VCamRecovered.disassembly.txt` is empty.
- The isolated `blackColor` string appears among UIKit/UI strings and is not evidence of a historical camera-black implementation.

No undocumented historical BLACK mechanism is reconstructed from imports or strings alone.

## VCAM PRO adaptation

VCAM PRO preserves the current central path:

`CMSampleBufferGetImageBuffer hook -> MediaserverdRuntime -> CameraConsumerAdapter -> prepared virtual output`

The correction is limited to active-mode output ownership:

1. prepared local-media frame when eligible;
2. prepared BLACK fallback when media is absent, pending, rejected, stale, unavailable, or rebuilding;
3. ORIGINAL only as an emergency safety escape when a compatible BLACK buffer cannot safely exist.

`ReferenceCameraHook.mm` remains unchanged for this gate.

No WhatsApp-, Telegram-, FaceTime-, KYC-, bundle-, or third-party-app-specific hook is introduced.

## BLACK preparation

`VirtualBlackFrame` prepares immutable reusable NV12 buffers outside the camera callback.

Supported formats remain:

- `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`
- `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`

BLACK values:

- 420v: Y=16, Cb=128, Cr=128
- 420f: Y=0, Cb=128, Cr=128

The implementation follows the existing iOS-15-compatible CoreVideo pool pattern already used by `src/media_engine/FrameTransformer.mm`:

- `CVPixelBufferPoolCreate`
- width/height/pixel-format attributes
- `kCVPixelBufferIOSurfacePropertiesKey`
- `CVPixelBufferPoolCreatePixelBuffer`

The prepared buffer is cached by geometry, with a bounded capacity of four entries. Allocation, pool construction, plane locking, and BLACK filling occur outside the camera-critical callback.

## Safety classes

Expected active states:

- no media;
- pending media;
- empty/no-eligible queue;
- temporarily unavailable producer;
- clear media;
- rejected/mismatched media frame;

resolve to BLACK virtual when a compatible prepared BLACK buffer exists.

Emergency technical failure:

- unsupported camera format;
- BLACK allocation/preparation failure;
- cache exhaustion for a new geometry;
- no compatible BLACK buffer;
- irrecoverable internal inconsistency;

may return ORIGINAL as the last crash/watchdog-prevention escape.

The emergency path is separately identifiable and counted. It is not the normal no-media behavior.

## Device-proof boundary

The first parity device proof will use only the existing central hook and will distinguish:

- ORIGINAL;
- BLACK_VIRTUAL;
- PHOTO_VIRTUAL.

A deeper hook-parity investigation is deferred unless physical evidence proves that VCAM PRO selected a valid different BLACK or prepared-media buffer while Apple Camera still visibly showed the original camera.
