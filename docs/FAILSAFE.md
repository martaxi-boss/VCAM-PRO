# VCAM PRO Fail-Open Policy

## Principle

VCAM PRO must prefer a valid real-camera frame over an uncertain virtual frame.

The injector must be designed so that loss of VCAM state, media, decode, IPC/data-plane access, timing, or frame compatibility does not intentionally break the real camera path.

## Mandatory fallback table

| Condition | Required action |
| --- | --- |
| VCAM OFF | Use the real frame |
| No virtual frame available | Use the real frame |
| Virtual frame invalid | Use the real frame |
| Decoder failed | Use the real frame |
| IPC/control/data plane unavailable | Use the real frame |
| Buffer incompatible | Use the real frame |
| Virtual frame late/stale | Use the real frame |
| Unexpected error | Use the real frame |

## Injector constraints

The injector must:

- perform only the minimum work required to validate and substitute a ready frame;
- preserve the original real-frame path;
- avoid synchronous media decode;
- avoid heavy crop/scale/rotation/decode work;
- avoid waiting indefinitely for another process/thread;
- treat missing or malformed shared state as VCAM unavailable;
- reject a virtual frame if basic format, timing, or lifetime requirements are not satisfied;
- prefer skipping a virtual frame over disrupting the camera service.

## Prohibited behavior

VCAM PRO must never intentionally:

- block the camera pipeline or `mediaserverd` indefinitely;
- wait for a decoder inside the injector;
- process heavy video work inside the injector;
- crash a camera service as a control mechanism;
- remove the fallback to real frames;
- substitute a frame without minimum compatibility validation;
- spin indefinitely waiting for IPC or a new buffer;
- assume a stale virtual frame is safer than the real frame.

## Failure domains for later proof

Device-proof planning must eventually cover at least:

- media end-of-stream;
- corrupt/unsupported media;
- decoder initialization failure;
- media-engine termination/restart;
- missing control-plane signal;
- unavailable shared buffer;
- pixel-format mismatch;
- size mismatch;
- bad/missing attachments;
- stale presentation timestamp;
- frame queue starvation;
- slow producer;
- rapid ON/OFF transitions;
- application/camera-session restart;
- central-service restart.

Each test must demonstrate that the real camera path remains usable or automatically becomes the fallback.

## Critical-service rule

If the validated central injection point runs inside or directly affects a critical camera service, the default behavior on uncertainty is:

**NO VIRTUAL SUBSTITUTION — USE REAL FRAME**
