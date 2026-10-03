# VCAM PRO

Local-gallery virtual camera for iOS 15 / arm64 / Dopamine rootless.
First certification device: iPhone 6s Plus (A9), iOS 15.8.8.

## Current state

Implementation exists. The canonical development branch is
`builder/canonical-hook-continuation-001`; `main` remains frozen at
`d476caacc4f557843f9551533c2fcbe7c5d40baa`.

The latest implementation baseline before repository hygiene is
`f4087e8607929e6b3ff3c6b594e8e43cc6b0b2d8` (VIDEO remediation 002).
Its VIDEO and central-gallery E2E gates passed. Physical VIDEO proof still
requires a device retry; repository cleanup does not certify device behavior.

See [canonical state](docs/CANONICAL_PROJECT_STATE.md) for current evidence
and [repository hygiene](docs/REPOSITORY_HYGIENE_001.md) for the cleanup scope.
Historical research and proof documents describe their named phase only.

## Product contract

- OFF restores the original camera output.
- ON uses virtual output globally: BLACK without ready media, PHOTO or VIDEO
  when ready. Original output must not escape while ON.
- Gallery media is local; no OBS, PC, USB/Wi-Fi streaming or required backend.
- Photo/video adjustment uses pan and pinch, no rotation; producer updates are
  bounded to 30 Hz with a final commit on Done.
- Decode, file access and transforms remain outside the camera callback.

The central iOS 15 camera structure and accepted frame/media/control components
remain the implementation baseline. Reference repositories `IOS-15-USB`,
`MotionCam-iOS` and `IOS-16-USB-4k` are strictly read only.

## Validation and packaging

The two automatic canonical gates are:

- `video-device-proof-remediation-002-ci.yml`: VIDEO regressions and RootHide
  candidate `0.1.0+roothide23~videofix1`.
- `ios15-central-motioncam-gallery-e2e-convergence-001-ci.yml`: central-gallery
  E2E, ownership, control and callback safety regressions.

Frame-engine and focused regression tests remain available. Superseded package
certifications are manual only. Removed diagnostics remain recoverable from
Git history and existing checkpoint/evidence/archive tags.

No merge, release, deployment or device installation is implied by hygiene.
