# VCAM PRO — Frame Engine Stage E1 Video Transform + Buffer Reuse 001

## Status

**STAGE E1 VIMAGE IMPLEMENTATION — READY FOR SUPERVISOR AUDIT**

Task:

`VCAM-PRO — FRAME ENGINE STAGE E1 — IOS15 VIMAGE TRANSFORM REMEDIATION 002`

Base `main`:

`d476caacc4f557843f9551533c2fcbe7c5d40baa`

Previous blocker head:

`49e7d1e6b8f573568958d8edf171b24e46cce4eb`

Validated implementation head before this proof update:

`cd34e0dfaafbb90074e3ed64892c2c7f32c5e35b`

Workstream:

`builder/frame-engine-stage-e1-transform-001`

PR:

`#10`

The exact final branch HEAD after this proof update is reported by immutable PR metadata and the Builder return. A Git commit cannot embed its own final SHA in its own content without changing that SHA.

---

## 1. PRE-IMPLEMENTATION STATIC FINDING — VIDEOTOOLBOX

The original Stage E1 packet requested public:

- `VTPixelTransferSession`;
- `VTPixelRotationSession`.

A bounded Apple-SDK availability proof was executed before production implementation.

Pre-implementation proof:

- GitHub Actions run: `36187915166`
- Xcode: `26.6`
- iPhoneOS SDK: `26.5`
- target architecture: `arm64`
- deployment target: `iOS 15.0`
- compiler policy: `-Werror -Werror=unguarded-availability-new`

The public SDK marks:

- `VTPixelTransferSession` as iOS 16.0+;
- `VTPixelRotationSession` as iOS 16.0+.

Direct iOS 15.0 compile probes were rejected by clang exactly because those APIs are unavailable before iOS 16.

This finding remains valid and is intentionally preserved.

No weak-link bypass, dynamic symbol lookup, private API, deployment-target increase, or proprietary implementation copy was used.

---

## 2. SUPERVISOR ADAPTATION — IOS15 BACKEND

The accepted iOS 15 backend is:

```text
CoreVideo CVPixelBufferPool
+
Accelerate / vImage
```

The iOS16 VideoToolbox session APIs remain reference techniques only and are not used by the iOS15 production implementation.

---

## 3. EXACT IOS15 VIMAGE COMPATIBILITY PROOF

Before production mutation, the following public APIs were compiled and linked together for:

- `arm64`
- `-miphoneos-version-min=15.0`
- `-Werror`
- `-Werror=unguarded-availability-new`
- public Accelerate and CoreVideo frameworks

Exact API set:

1. `CVPixelBufferPoolCreate`
2. `CVPixelBufferPoolCreatePixelBuffer`
3. `vImageScale_Planar8`
4. `vImageScale_CbCr8`
5. `vImageRotate90_Planar8`
6. `vImageRotate90_Planar16U`
7. `vImageConvert_420Yp8_CbCr8ToARGB8888`
8. `vImageConvert_ARGB8888To420Yp8_CbCr8`
9. `vImageConvert_YpCbCrToARGB_GenerateConversion`
10. `vImageConvert_ARGBToYpCbCr_GenerateConversion`

Pre-implementation vImage probe:

- run: `36189396244`
- result: **SUCCESS**
- architecture: **arm64**
- minimum iOS: **15.0**
- result marker: **VIMAGE_IOS15_API_PROBE=PASS**

The full Stage E1 validation run repeated the same probe successfully.

---

## 4. PRODUCTION IMPLEMENTATION

Changed production files:

- `src/media_engine/FrameTransformer.h`
- `src/media_engine/FrameTransformer.mm`
- `src/media_engine/FramePipelinePump.h`
- `src/media_engine/FramePipelinePump.cpp`

Existing contracts preserved:

- `PreparedFrame`
- `FrameNormalizer`
- `ReadyFrameQueue`
- existing historical D1/D2 pump behavior through the legacy constructor path

### FrameTransformer

The original VCAM PRO transformer:

- accepts a `PreparedFrame`;
- consumes `SourceGeometry`;
- consumes `NormalizationTarget`;
- validates media generation and timeline epoch;
- never mutates the source frame;
- returns a new `PreparedFrame` only after complete success;
- returns structured transform status on failure.

Structured result states include:

- transformed;
- invalid frame;
- generation mismatch;
- timeline mismatch;
- unsupported target;
- unsupported geometry;
- unsupported color conversion;
- pool failure;
- transform failure.

### Reusable CVPixelBufferPool

Production output uses reusable `CVPixelBufferPool` resources.

Pool keys derive from:

- width;
- height;
- pixel format.

Supported production targets remain:

- `420v`;
- `420f`.

Pool attributes include:

`kCVPixelBufferIOSurfacePropertiesKey`

No resolution/model hardcodes are used.

Compatible frames reuse the pool. Material target changes rebuild the relevant pool.

### Direct NV12 same-format path

For:

- `420v -> 420v`
- `420f -> 420f`

the implementation does not route through ARGB.

Luma scaling uses:

`vImageScale_Planar8`

Interleaved CbCr scaling uses:

`vImageScale_CbCr8`

### Center crop / scale

The scale path:

- preserves source aspect ratio;
- produces exact requested output dimensions;
- computes a deterministic centered crop;
- enforces even 4:2:0 geometry;
- aligns crop origin to chroma boundaries;
- rejects invalid geometry instead of producing corrupted chroma;
- never silently stretches.

### Cardinal rotation

Supported non-mirrored cardinal transforms:

- 0 degrees;
- 90 degrees;
- 180 degrees;
- 270 degrees.

Translation components from normal AVAssetTrack preferred transforms do not cause mirror classification.

The linear transform is validated for determinant/orientation.

Rejected:

- mirrored transforms;
- shear/non-cardinal transforms.

Producer-side rotation uses:

- `vImageRotate90_Planar8` for luma;
- `vImageRotate90_Planar16U` for each interleaved CbCr pair as one 16-bit unit.

90/270 swaps logical dimensions before crop/scale.

Successful output is:

`OrientationState::Normalized`

### 420v / 420f range conversion

The implementation does not relabel the FourCC.

Range conversion uses:

- `vImageConvert_420Yp8_CbCr8ToARGB8888`;
- `vImageConvert_ARGB8888To420Yp8_CbCr8`;
- `vImageConvert_YpCbCrToARGB_GenerateConversion`;
- `vImageConvert_ARGBToYpCbCr_GenerateConversion`.

The conversion descriptors and ARGB scratch storage are reused.

Recognized matrix bases:

- ITU-R 601;
- ITU-R 709.

If a required matrix basis is absent or unsupported, the transform returns:

`UnsupportedColorConversion`

and publishes nothing.

The normal same-format NV12 path does not pay the ARGB conversion cost.

### Resource reuse

Bounded reusable state includes:

- destination CVPixelBufferPool;
- rotation CVPixelBufferPool;
- conversion-input CVPixelBufferPool;
- luma/chroma scale scratch;
- ARGB conversion scratch;
- vImage conversion descriptors.

No unbounded cache exists.

### Metadata

When present, the implementation preserves:

- `kCVImageBufferColorPrimariesKey`;
- `kCVImageBufferTransferFunctionKey`;
- `kCVImageBufferYCbCrMatrixKey`;
- applicable propagating PreparedFrame attachments.

Metadata is applied to the destination `CVPixelBuffer` and retained in the returned PreparedFrame contract.

Missing metadata is not invented.

### Identity and timing

A successful transform preserves:

- sequence;
- mediaGeneration;
- timelineEpoch;
- loopIteration;
- sourcePTS;
- duration.

Stage E1 does not fabricate unresolved presentation scheduling fields.

---

## 5. PIPELINE INTEGRATION

`FramePipelinePump` now supports a Stage E1 transform-enabled constructor.

Flow:

```text
Reader
  -> FrameNormalizer
       -> ReadyPassthrough
            -> publish
       -> TransformRequired
            -> FrameTransformer
            -> exact target revalidation
            -> publish
```

Transform failure returns:

`FramePipelinePumpStatus::TransformFailed`

and publishes no frame.

The existing pre-Stage-E1 constructor retains the historical `TransformRequired` behavior so Stage D1/D2 regression sources preserve their original semantics.

Consumer fast path remains:

`ReadyFrameQueue::tryAcquire()`

No decode, vImage transform, Accelerate work, file I/O, hook code, or networking was added to the consumer path.

---

## 6. TESTS

New tests:

- `tests/media_engine/frame_transformer_stage_e1_tests.mm`
- `tests/media_engine/frame_pipeline_stage_e1_tests.mm`

Transformer suite:

**27 tests / 0 failures**

Pipeline integration suite:

**3 tests / 0 failures**

Total Stage E1:

**30 tests / 0 failures**

Coverage includes:

- passthrough regression;
- same-format 420v scale;
- same-format 420f scale;
- center crop / aspect preservation;
- exact output dimensions;
- directional-pattern 90-degree rotation;
- directional-pattern 180-degree rotation;
- directional-pattern 270-degree rotation;
- mirror rejection;
- non-cardinal rejection;
- odd 4:2:0 target rejection;
- 420v -> 420f;
- 420f -> 420v;
- range conversion proven not to be FourCC relabel only;
- FrameIdentity preservation;
- sourcePTS/duration preservation;
- no scheduling-field fabrication;
- color metadata propagation;
- attachment propagation;
- stale generation rejection;
- stale epoch rejection;
- missing matrix rejection for range conversion;
- output pool reuse;
- target-change resource rebuild;
- rotation resource reuse;
- conversion-resource reuse;
- source non-mutation;
- normalized output;
- transform-enabled pipeline publish;
- transform failure publishes nothing;
- passthrough avoids transformer resource construction.

---

## 7. REGRESSION VALIDATION

Full Stage E1 validation run on implementation head:

`36190345037`

Conclusion:

**SUCCESS**

Passed:

- Stage A regression;
- Stage B regression;
- Stage C1 queue regression;
- Stage C1 normalizer regression;
- Stage D1 regression;
- Stage D2 consumer regression/isolation;
- Stage D2 queue/concurrency regression;
- Stage D2 pipeline regression;
- Stage D2 720p30 host smoke;
- ASan/UBSan queue ownership regression;
- ASan/UBSan pipeline regression;
- ThreadSanitizer queue regression.

The historical Stage D2 workflow itself was not weakened or rewritten.

Stage E1 reruns the relevant historical regression test sources against the current implementation as required.

---

## 8. IOS15 ARM64 BUILD PROOF

The production Stage E1 archive was compiled with:

- architecture: **arm64**
- deployment target: **iOS 15.0**
- `-Werror`
- `-Werror=unguarded-availability-new`

Artifacts include:

- `libVCAMConsumerFastPathE1.a`
- `libVCAMFrameEngineStageE1.a`

Object inspection confirmed minimum iOS:

**15.0**

No arm64e requirement was introduced.

Expected producer undefined symbols include public:

- CVPixelBufferPool APIs;
- Accelerate/vImage scale APIs;
- Accelerate/vImage rotation APIs;
- Accelerate/vImage conversion APIs.

Forbidden dependency checks cover:

- UIKit;
- Photos;
- private/injector hook primitives;
- AVCapture;
- VTPixelTransferSession;
- VTPixelRotationSession;
- network/backend symbols.

No private API/availability bypass is used.

---

## 9. CONSUMER FAST-PATH ISOLATION

The consumer-only archive contains only:

- `PreparedFrame`;
- `ReadyFrameQueue`.

The consumer isolation check rejects:

- AVAssetReader;
- AVFoundation;
- Accelerate/vImage;
- FrameTransformer;
- VideoToolbox transform APIs;
- injector/hook code;
- mediaserverd dependencies;
- network code.

Result:

**PASS**

Producer transform work remains outside `ReadyFrameQueue::tryAcquire()`.

---

## 10. CI ARTIFACT

Implementation validation artifact:

- name: `vcam-frame-engine-stage-e1-validation`
- artifact ID: `10887879164`
- run: `36191436743`
- validated implementation head: `cd34e0dfaafbb90074e3ed64892c2c7f32c5e35b`
- artifact digest: `sha256:a73e2fe181d5d487ebea655b198bdeeee6beb8281ad3bb8bbd8ee10bc64e1af8`

The implementation head above passed the complete Stage E1 validation workflow. The documentation-only commit containing this record must rerun the same workflow before promotion; its terminal run is reported in the Builder return.

---

## 11. WHAT THIS PROVES

Stage E1 static/build/host evidence proves:

- the required public vImage/CoreVideo API set is available to arm64/iOS 15.0 compilation;
- the VCAM PRO FrameTransformer is implemented;
- reusable output/resource pools are implemented;
- same-format NV12 direct scale/crop is implemented;
- cardinal rotations are implemented;
- video/full range conversion is implemented with recognized matrix basis;
- metadata/attachment propagation is implemented;
- producer pipeline integration is implemented;
- transform failure publishes nothing;
- prior regression suites remain green inside Stage E1 validation;
- consumer fast-path isolation remains intact;
- Stage E1 production objects compile for arm64 / minimum iOS 15.0.

---

## 12. RUNTIME-ONLY FACTS STILL OUTSTANDING

This Stage E1 work does **not** establish:

- A9 throughput;
- thermal behavior;
- device memory pressure;
- exact target-device vImage performance;
- mediaserverd load;
- private callback reachability;
- camera callback lifetime/timing;
- central substitution behavior;
- cross-process transport.

Those are separate runtime/device gates.

Explicitly:

- **NOT Gate 1**
- **NOT Gate 2**
- **NOT Gate 3**
- **NOT A9 performance proof**
- **NOT final cross-process data plane**
- **NOT final injector**

---

## 13. FINAL STAGE E1 STATE

Backend:

**CoreVideo CVPixelBufferPool + Accelerate/vImage**

VT iOS15 compatibility finding:

**PRESERVED — VT session families are iOS16+**

Stage E1 implementation:

**IMPLEMENTED**

Host/static/build validation:

**PASS on implementation head; final documentation head must rerun CI**

Device action:

**NONE**

Reference repository mutation:

**NONE**

Merge:

**NO**
