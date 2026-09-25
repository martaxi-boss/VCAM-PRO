# VCAM PRO — Frame Engine Stage E1 Video Transform + Buffer Reuse 001

## Status

**STATIC COMPATIBILITY BLOCKER — PRODUCTION IMPLEMENTATION NOT STARTED**

Task:

`VCAM-PRO — FRAME ENGINE STAGE E1 — VIDEO TRANSFORM + BUFFER REUSE 001`

Base `main`:

`d476caacc4f557843f9551533c2fcbe7c5d40baa`

Workstream:

`builder/frame-engine-stage-e1-transform-001`

The exact final branch HEAD is reported by immutable PR metadata and the Builder return. A Git commit cannot embed its own final SHA in content without changing that SHA.

## Why implementation stopped before production mutation

Stage E1 requires a production transform path for the normative target:

- arm64;
- `IPHONEOS_DEPLOYMENT_TARGET=15.0`;
- first certification device iPhone 6s Plus / A9 / iOS 15.8.8.

The packet requires:

- public `VTPixelTransferSession` for scaling/pixel-format transfer;
- public `VTPixelRotationSession` for supported cardinal rotation if valid for the iOS 15 deployment target;
- compile-time availability checking;
- no deployment-target increase;
- no private API or availability bypass.

Before changing production code, CI inspected the actual Apple iPhoneOS SDK and compiled unguarded availability probes with:

`-arch arm64 -miphoneos-version-min=15.0 -Werror=unguarded-availability-new`

This produced a material static blocker.

## Toolchain evidence

Availability preflight run:

- GitHub Actions run: `36187915166`
- runner image: `macos-26-arm64`
- macOS: `26.6.2`
- Xcode: `26.6`
- Xcode build: `17F113`
- Apple clang: `21.0.0 (clang-2100.1.1.101)`
- iPhoneOS SDK: `iPhoneOS26.5.sdk`
- architecture probe target: `arm64`
- deployment target: `iOS 15.0`

Artifact:

- `vcam-frame-engine-stage-e1-api-availability`
- artifact ID: `10887141616`

## CVPixelBufferPool

A minimal public `CVPixelBufferPoolCreate` probe compiled successfully for arm64 / iOS 15.0 with warnings treated as errors.

Result:

**CVPIXELBUFFERPOOL_IOS15_COMPILE = PASS**

This confirms that buffer-pool availability is not the blocker.

## VTPixelTransferSession static blocker

The current public iPhoneOS SDK header declares `VTPixelTransferSessionRef` with:

`API_AVAILABLE(macos(10.8), ios(16.0), tvos(16.0), visionos(1.0))`

The arm64 / iOS 15.0 compile probe failed under `-Werror=unguarded-availability-new`.

Compiler evidence includes:

- `VTPixelTransferSessionRef` is only available on iOS 16.0 or newer;
- `VTPixelTransferSessionCreate` is introduced in iOS 16.0;
- `VTPixelTransferSessionInvalidate` is introduced in iOS 16.0.

Result:

**VTPIXELTRANSFER_IOS15_PUBLIC = NO**

The historical IOS-15-USB archive contains static evidence that a historical binary referenced VideoToolbox pixel-transfer symbols. That historical binary evidence does not change the public SDK availability contract and is not authorization to call an API below its public deployment availability or to reproduce proprietary implementation.

## VTPixelRotationSession static blocker

The current public iPhoneOS SDK header declares `VTPixelRotationSessionRef` with:

`API_AVAILABLE(macos(13.0), ios(16.0), tvos(16.0), visionos(1.0))`

The arm64 / iOS 15.0 compile probe failed under `-Werror=unguarded-availability-new`.

Compiler evidence includes:

- `VTPixelRotationSessionRef` is only available on iOS 16.0 or newer;
- `VTPixelRotationSessionCreate` is introduced in iOS 16.0;
- `VTPixelRotationSessionRotateImage` is introduced in iOS 16.0;
- `VTPixelRotationSessionInvalidate` is introduced in iOS 16.0.

Result:

**VTPIXELROTATION_IOS15_STATUS = STATIC_BLOCKER**

## Policy consequence

An `@available(iOS 16.0, *)` guard could make source compile with a deployment target of iOS 15, but it would deliberately make the required transform path unavailable on the certification device running iOS 15.8.8.

Using the symbols unguarded, weak-linking them to bypass the public availability contract, resolving them dynamically, copying a proprietary historical implementation, or raising the deployment target would violate this Stage E1 packet.

Therefore no partial `FrameTransformer` was added. A production component that advertises Stage E1 success while the required public transfer primitive cannot execute on iOS 15.8.8 would be misleading.

## Production / test effects

Production files changed:

**NONE**

Test files changed:

**NONE**

Existing Stage A/B/C1/D1/D2 code was not changed.

No transform code, hook, injector, scheduler, IPC, control plane, gallery, package or device action was added.

## What is proven

- current public SDK availability of `CVPixelBufferPool` is compatible with the iOS 15 compile target;
- current public SDK availability of `VTPixelTransferSession` begins at iOS 16.0;
- current public SDK availability of `VTPixelRotationSession` begins at iOS 16.0;
- direct use of those VT session APIs for an iOS 15.0 target is rejected by clang with unguarded availability treated as an error;
- no private/API-availability bypass was used.

## What is not proven

- Stage E1 production transform;
- scaling/cropping/pixel-format conversion on iOS 15.8.8;
- cardinal rotation on iOS 15.8.8;
- pool reuse in the intended production transform;
- metadata propagation through a transformed output;
- FramePipelinePump transform integration;
- Stage E1 transform tests;
- A9 performance.

Explicitly:

- **NOT Gate 1**
- **NOT Gate 2**
- **NOT Gate 3**
- **NOT A9 performance proof**
- **NOT final cross-process data plane**
- **NOT final injector**

## Required Supervisor decision

Stage E1 as specified cannot reach its success contract on iOS 15 while simultaneously requiring public `VTPixelTransferSession` and public `VTPixelRotationSession`.

A revised, explicitly authorized iOS-15-compatible transform primitive is required before production implementation can continue.

No architecture alternative is selected by this Builder task.
