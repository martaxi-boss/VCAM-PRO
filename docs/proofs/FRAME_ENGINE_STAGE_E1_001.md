# VCAM PRO — Frame Engine Stage E1 Video Transform + Buffer Reuse 001

## Status

**IMPLEMENTED — IOS15 ACCELERATE/vIMAGE BACKEND READY FOR SUPERVISOR AUDIT**

Task:

`VCAM-PRO — FRAME ENGINE STAGE E1 — IOS15 VIMAGE TRANSFORM REMEDIATION 002`

Base `main`:

`d476caacc4f557843f9551533c2fcbe7c5d40baa`

Workstream:

`builder/frame-engine-stage-e1-transform-001`

PR:

`#10`

Production-validation head before proof finalization:

`7fec50bc2ff3c1b831635d6f00f03b9c089eb50c`

The exact final branch HEAD is reported by PR metadata and the Builder return. A Git commit cannot embed its own final SHA without changing that SHA.

## Pre-implementation static finding — VideoToolbox session APIs

The first Stage E1 packet required public `VTPixelTransferSession` and `VTPixelRotationSession` while keeping:

- arm64;
- `IPHONEOS_DEPLOYMENT_TARGET=15.0`;
- no private API;
- no availability bypass.

GitHub Actions run `36187915166` established that the current public Apple SDK declares:

- `VTPixelTransferSessionRef` as iOS 16.0+;
- `VTPixelRotationSessionRef` as iOS 16.0+.

Direct arm64 / iOS 15.0 probes with:

`-Werror=unguarded-availability-new`

were rejected by clang as expected.

This finding remains valid provenance. VCAM PRO does not use, weak-link, dynamically resolve, or bypass those iOS16+ APIs for the iOS 15 product baseline.

## Supervisor adaptation

The accepted iOS 15 backend is:

`CVPixelBufferPool + Accelerate/vImage`

The implementation is original VCAM PRO code and does not reproduce a historical binary/disassembly implementation.

## Exact iOS 15 public API preflight

Run:

`36189396244`

Result:

**SUCCESS**

The probe compiled and linked an arm64 Mach-O with:

`minos 15.0`

and referenced exactly:

- `CVPixelBufferPoolCreate`
- `CVPixelBufferPoolCreatePixelBuffer`
- `vImageScale_Planar8`
- `vImageScale_CbCr8`
- `vImageRotate90_Planar8`
- `vImageRotate90_Planar16U`
- `vImageConvert_420Yp8_CbCr8ToARGB8888`
- `vImageConvert_ARGB8888To420Yp8_CbCr8`
- `vImageConvert_YpCbCrToARGB_GenerateConversion`
- `vImageConvert_ARGBToYpCbCr_GenerateConversion`

Result:

**VIMAGE_IOS15_API_PROBE = PASS**

## Production implementation

Added:

- `src/media_engine/FrameTransformer.h`
- `src/media_engine/FrameTransformer.mm`

Updated:

- `src/media_engine/FramePipelinePump.h`
- `src/media_engine/FramePipelinePump.cpp`

The production transformer:

- consumes `PreparedFrame`, `SourceGeometry`, and `NormalizationTarget`;
- validates media generation and timeline epoch;
- never mutates the source pixel buffer;
- emits structured transform status;
- produces a new `PreparedFrame` only after complete success;
- marks successful geometry as `OrientationState::Normalized`;
- preserves FrameIdentity and existing producer timing fields;
- does not invent presentation scheduling.

## Reusable CVPixelBufferPool

Transformed output is allocated from a reusable `CVPixelBufferPool`.

Pool key:

- target width;
- target height;
- target pixel format.

Pool attributes include:

`kCVPixelBufferIOSurfacePropertiesKey`

The output pool is reused while the material target is unchanged and rebuilt when width, height, or pixel format changes.

Additional bounded reusable resources include:

- rotation pixel-buffer pool;
- range-conversion input pool;
- planar scaling scratch storage;
- ARGB range-conversion scratch storage;
- generated vImage YCbCr/ARGB conversion descriptors.

There is no unbounded resource cache.

## NV12 same-format fast path

For:

- 420v -> 420v
- 420f -> 420f

the implementation stays in bi-planar NV12.

Luma uses:

`vImageScale_Planar8`

Interleaved CbCr uses:

`vImageScale_CbCr8`

The same-format path does not perform an ARGB conversion.

## Center crop / scale

The implementation:

- preserves source aspect ratio;
- computes deterministic center crop;
- emits the exact requested output size;
- rejects odd or invalid 4:2:0 target geometry;
- aligns crop origin and crop dimensions to chroma boundaries;
- never silently stretches the source.

## Cardinal rotation

The linear component of `preferredTransform` is interpreted independently from normal translation.

Supported non-mirrored cardinal cases:

- 0 degrees;
- 90 degrees;
- 180 degrees;
- 270 degrees.

Rejected:

- mirrored transforms;
- shear/non-unit transforms;
- non-cardinal arbitrary rotation.

Rotation implementation:

- Y plane -> `vImageRotate90_Planar8`;
- CbCr plane -> `vImageRotate90_Planar16U`.

The CbCr plane is treated as 16-bit elements so each interleaved chroma pair remains intact.

For 90/270 degrees the rotated logical width/height are swapped before crop/scale.

## 420v / 420f range conversion

The implementation does not relabel FourCC values.

When source and target NV12 range differ:

1. the already-rotated/cropped/scaled NV12 source is converted to reusable ARGB scratch with:
   - `vImageConvert_420Yp8_CbCr8ToARGB8888`;
2. ARGB is converted to the target NV12 range with:
   - `vImageConvert_ARGB8888To420Yp8_CbCr8`.

Reusable conversion descriptors are generated with:

- `vImageConvert_YpCbCrToARGB_GenerateConversion`;
- `vImageConvert_ARGBToYpCbCr_GenerateConversion`.

Recognized matrices:

- ITU-R 601;
- ITU-R 709.

If a range conversion requires a matrix and the source matrix metadata is absent/unrecognized, the transformer returns:

`UnsupportedColorConversion`

and publishes nothing.

## Metadata

When present, the following PreparedFrame metadata remains preserved:

- `kCVImageBufferColorPrimariesKey`;
- `kCVImageBufferTransferFunctionKey`;
- `kCVImageBufferYCbCrMatrixKey`;
- propagating PreparedFrame attachments.

Relevant propagating attachments are also applied to the destination `CVPixelBuffer`.

Missing color metadata is not fabricated.

## Frame contract

A successful transform preserves:

- `FrameIdentity.sequence`;
- `mediaGeneration`;
- `timelineEpoch`;
- `loopIteration`;
- `sourcePTS`;
- `duration`;
- unresolved `presentationTimestamp`;
- unresolved `producedAtHostTime`.

No scheduler/pacing is implemented in Stage E1.

## Pipeline integration

`FramePipelinePump` now supports a Stage E1 transform-enabled constructor.

Flow:

`Reader -> FrameNormalizer`

Ready passthrough:

`ReadyPassthrough -> publish`

Transform-required:

`TransformRequired -> FrameTransformer -> post-transform normalization validation -> publish`

Transform failure:

`TransformFailed -> publish nothing`

The original constructor is retained so historical D1/D2 regression suites preserve their original pre-Stage-E1 semantics.

No transform work was added to `ReadyFrameQueue::tryAcquire()`.

## Focused Stage E1 tests

Added:

- `tests/media_engine/frame_transformer_stage_e1_tests.mm`
- `tests/media_engine/frame_pipeline_stage_e1_tests.mm`

Transformer tests:

**27 / 27 PASS**

Pipeline integration tests:

**3 / 3 PASS**

Total focused Stage E1 tests:

**30 / 30 PASS**

Coverage includes:

- passthrough regression;
- same-format 420v scale;
- same-format 420f scale;
- center crop semantics;
- exact output dimensions;
- directional 90-degree rotation;
- directional 180-degree rotation;
- directional 270-degree rotation;
- mirrored transform rejection;
- non-cardinal transform rejection;
- odd/invalid 4:2:0 target rejection;
- 420v -> 420f;
- 420f -> 420v;
- range conversion verified as pixel conversion, not FourCC relabel;
- FrameIdentity preservation;
- sourcePTS/duration preservation;
- no presentation-time fabrication;
- color metadata propagation;
- attachment propagation;
- stale generation rejection;
- stale epoch rejection;
- missing-matrix range conversion rejection;
- output-pool reuse;
- target-change resource rebuild;
- rotation-pool reuse;
- conversion-resource reuse;
- source immutability;
- normalized successful output;
- transform failure publishes no frame;
- transform-enabled pump publishes only a validated complete frame;
- passthrough does not allocate transform resources.

## Full Stage E1 CI

Implementation validation run:

`36190345037`

Head:

`7fec50bc2ff3c1b831635d6f00f03b9c089eb50c`

Conclusion:

**SUCCESS**

Artifact:

`vcam-frame-engine-stage-e1-validation`

Artifact ID:

`10887832355`

Artifact digest:

`sha256:c5da3880536a3259cc39fe0d80bd1c12415041c9db5e2389a378353a7d81d584`

CI passed:

- exact vImage iOS15 public API probe;
- Stage E1 transformer tests;
- Stage E1 pipeline tests;
- Stage A regression;
- Stage B regression;
- Stage C1 queue regression;
- Stage C1 normalizer regression;
- Stage D1 regression test source;
- Stage D2 consumer regression;
- Stage D2 queue/concurrency regression;
- Stage D2 pipeline regression;
- ASan/UBSan queue regression;
- ASan/UBSan pipeline regression;
- ThreadSanitizer gate;
- arm64 / iOS 15.0 production compile;
- consumer fast-path isolation;
- producer undefined-symbol/dependency inspection.

## Historical workflows

Historical stage workflows are not rewritten to erase their original stage boundaries.

In particular, the Stage D1 historical workflow can reject new transform-era production through its original negative checks. Stage E1 CI therefore runs the relevant Stage D1 regression test source against the new implementation directly.

The historical D2 workflow is left unchanged. Stage E1 CI independently revalidates D2 consumer, queue and pipeline regression sources plus consumer isolation.

## iOS 15 arm64 build proof

The Stage E1 production slice compiles with:

- architecture: `arm64`;
- minimum deployment target: `iOS 15.0`;
- `-Werror=unguarded-availability-new`.

The built producer archive contains the expected public CoreVideo/vImage undefined symbols and no iOS16 VideoToolbox session symbols.

No arm64e requirement was introduced.

## Consumer fast-path isolation

The consumer-only archive remains:

- `PreparedFrame`;
- `ReadyFrameQueue`.

Its source and undefined symbols show no dependency on:

- AVFoundation;
- AVAssetReader;
- Accelerate/vImage;
- FrameTransformer;
- VideoToolbox transform APIs;
- injector/hook code;
- network code.

Producer transformation remains outside `ReadyFrameQueue::tryAcquire()`.

## What is proven

This stage proves, in host/build scope:

- public vImage/CoreVideo primitives compile and link for arm64/iOS 15.0;
- original FrameTransformer production code builds for that target;
- bounded reusable output and scratch resources are implemented;
- same-format NV12 transform path avoids ARGB conversion;
- center crop/scale behavior is exercised;
- 0/90/180/270 handling is implemented, with pattern verification for rotated cases;
- mirror/non-cardinal geometry is rejected;
- real 420v/420f range conversion is exercised;
- color metadata/attachments propagate;
- FramePipelinePump publishes transformed frames only after complete transform and validation;
- transform failures publish no frame;
- Stage A-D2 regression sources pass in Stage E1 CI;
- consumer fast-path isolation remains intact.

## Runtime-only / future proof

Stage E1 does not prove:

- A9 runtime performance;
- sustained target-device memory pressure;
- target-device vImage throughput;
- real central callback format/dimensions/timing;
- cross-process data plane;
- injector behavior;
- real-camera substitution.

Explicitly:

- **NOT Gate 1**
- **NOT Gate 2**
- **NOT Gate 3**
- **NOT A9 performance proof**
- **NOT final cross-process data plane**
- **NOT final injector**

## Final stage conclusion

The iOS16 VideoToolbox session blocker remains preserved as a pre-implementation static finding.

For iOS 15, VCAM PRO Stage E1 now uses:

**CoreVideo CVPixelBufferPool + public Accelerate/vImage**

No private API or availability bypass was used.

Final status:

**STAGE_E1_VIMAGE_READY_FOR_SUPERVISOR_AUDIT**
