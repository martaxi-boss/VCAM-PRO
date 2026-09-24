# VCAM PRO — Project State

## Current phase

- **PHASE:** CENTRAL INJECTION — LOAD PROOF PREPARATION
- **FUNCTIONAL IMPLEMENTATION:** MINIMAL LOAD-ONLY PROBE
- **BUILD:** PASS
- **DEVICE PROOF:** NOT STARTED
- **DEVICE GATE:** HOLD — AWAITING PHYSICAL DEVICE
- **FRAME ENGINE CONTRACT:** DEFINED
- **PARALLEL WORKSTREAM:** FRAME ENGINE STAGE B
- **FRAME ENGINE IMPLEMENTATION:** STAGE B — LOCAL AVASSETREADER VIDEO PATH
- **FRAME ENGINE STAGE A BUILD:** PASS
- **FRAME ENGINE STAGE B BUILD:** PASS
- **FRAME ENGINE DECODER:** AVASSETREADER LOCAL VIDEO — BUILD/HOST TEST PASS
- **READY FRAME QUEUE:** NOT STARTED
- **MEDIASERVERD LOAD:** NOT YET PROVEN
- **FRAME SUBSTITUTION:** PROHIBITED
- **IOS 15.8.8 RUNTIME:** NOT YET PROVEN
- **A9 720P30 DEVICE PERFORMANCE:** NOT YET MEASURED
- **PUBLIC RELEASE:** NO

## Normative target

- iPhone 6s Plus
- Apple A9
- arm64
- iOS 15.8.8
- Dopamine
- rootless
- ElleKit-compatible tweak loading

No runtime PASS may be recorded until the relevant behavior is tested on the real target device under a separate Supervisor-approved order.

## Approved implementation baseline

Approved `main` used for this workstream:

`bf1913f8d8fd3c02d791b483a1ecd60a25924e6f`

Build workstream:

`builder/mediaserverd-load-probe-build-001`

Reference repositories remained READ ONLY at:

| Repository | Observed state |
| --- | --- |
| `martaxi-boss/MotionCam-iOS` | `main` @ `5ede3a1973a01cb13fe7f3ab562b47513feec1b1` |
| `martaxi-boss/IOS-15-USB` | EMPTY; no branch / no HEAD |
| `martaxi-boss/IOS-16-USB-4k` | `main` @ `cc20d787070c67565173d4a46c218e2549cecc93` |

## Load-only probe

Source location:

`proofs/mediaserverd_load_probe/`

The probe is intentionally limited to a C dylib constructor that:

1. reads process identity;
2. returns unless the process is exactly `mediaserverd`;
3. emits one bounded unified-log marker containing the process name and PID.

Marker:

`VCAM_PRO_LOAD_PROBE_001`

Injection filter:

**Executable = mediaserverd only**

No hook, camera callback, frame access, IPC, media engine, frame production, frame conversion, or frame substitution exists in this implementation.

## Build result

Build environment:

- GitHub Actions macOS runner
- image `macos-26-arm64`
- Xcode 26.6
- iPhoneOS26.5 SDK
- Apple clang 21.0.0
- Theos @ `dd5c14bb9d91311e221d51b5bfb8c9e5948156db`

Configuration:

- rootless package scheme
- arm64 only
- iOS 15.0 minimum deployment target
- no arm64e

Successful build/validation:

- GitHub Actions Run #3
- Run ID `36055302355`
- result: **SUCCESS**

Package:

`com.vcampro.loadprobe_0.0.1_iphoneos-arm64.deb`

Package SHA-256:

`d97e5be4c96a005d3fc630dfed7aeac837939e4843b912c7686803ad75061f62`

Installed paths:

- `/var/jb/usr/lib/TweakInject/VCAMProLoadProbe.dylib`
- `/var/jb/usr/lib/TweakInject/VCAMProLoadProbe.plist`

Mach-O:

- arm64 only
- only observed dynamic dependency beyond its own install name: `/usr/lib/libSystem.B.dylib`
- no AVFoundation/CoreMedia/CoreVideo/VideoToolbox/Photos/UIKit dependency
- no `MSHookFunction` / `MSHookMessageEx` symbol

Package control archive contains no maintainer/restart script.

Detailed evidence:

`docs/proofs/MEDIASERVERD_LOAD_PROBE_001.md`

## Central-injection status

`mediaserverd` remains:

**LEADING RESEARCH CANDIDATE / NOT RUNTIME PROVEN**

The successful build does not promote it to final architecture and does not prove that the dylib loads in the daemon on iOS 15.8.8.

## Device gate

Device action was **NOT PERFORMED**.

The next device operation, if later authorized, must begin with load proof only.

This branch does not authorize:

- installation on the iPhone;
- SSH to the iPhone;
- Sileo/dpkg installation;
- copying the dylib to `/var/jb`;
- killing/restarting `mediaserverd`;
- respring;
- userspace reboot;
- Camera/WhatsApp testing;
- callback reachability work.

## Frame gate

Frame access:

**NO**

Frame substitution:

**PROHIBITED**

No future work may progress to reachability or substitution without a new explicit Supervisor order after audit of this build/package.

## Provenance

The implementation is original to VCAM PRO.

No reference repository was modified and no proprietary implementation was copied.

## Public release

**NO**

No merge, release, deployment, or device installation is authorized by this build workstream.
