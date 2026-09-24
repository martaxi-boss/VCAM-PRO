# VCAM PRO — Project State

## Current phase

- **PHASE:** CENTRAL INJECTION RESEARCH
- **FUNCTIONAL IMPLEMENTATION:** NOT STARTED
- **DEVICE PROOF:** NOT STARTED
- **CENTRAL INJECTION:** RESEARCH IN PROGRESS / CANDIDATE ONLY
- **IOS 15.8.8 COMPATIBILITY:** TARGET / NOT YET PROVEN
- **PUBLIC RELEASE:** NO

## Normative target

- iPhone 6s Plus
- Apple A9
- arm64
- iOS 15.8.8
- Dopamine
- rootless

No runtime PASS may be recorded until the relevant behavior is tested on the real target device.

## Research baseline

Approved base `main`:

`6e2e30e1242f47fed702e0af1cab51137eb6f77a`

Research workstream:

`builder/central-injection-research-001`

Reference state observed for this research:

| Repository | Mutability | Observed state |
| --- | --- | --- |
| `martaxi-boss/MotionCam-iOS` | READ ONLY | `main` @ `5ede3a1973a01cb13fe7f3ab562b47513feec1b1` |
| `martaxi-boss/IOS-15-USB` | READ ONLY | EMPTY; no branch / no HEAD |
| `martaxi-boss/IOS-16-USB-4k` | READ ONLY | `main` @ `cc20d787070c67565173d4a46c218e2549cecc93` |

Official upstream snapshots used:

- Dopamine `3.x` @ `1a54e76d515ff5916b64e44d6afbb57d2bc89ee9`
- ElleKit `main` @ `1017a0d09606ea49ba8bc4d6cccc530d372e640e`
- Theos rootless/packaging documentation
- Apple AVFoundation/CoreMedia/VideoToolbox/IOSurface documentation

## Central injection research result

### Confirmed

- MotionCam's current frame-substitution architecture is process-local.
- Current Dopamine source has a rootless process/systemhook injection layer and an iOS15-specific spawn-hook path.
- Current Dopamine loads rootless `TweakLoader.dylib` when tweak injection is enabled.
- Current ElleKit source implements rootless tweak filtering/loading and provides `mobilesubstrate` compatibility.
- The iOS16 reference filter explicitly includes `mediaserverd`.
- The iOS16 reference has static CoreMedia/CoreVideo/VideoToolbox, pixel-buffer-pool, IOSurface-property, Darwin-notification and hook-symbol evidence.
- The current IOS-15-USB GitHub repository is empty.

### Leading research candidate

`mediaserverd`

Status:

**CANDIDATE ONLY — NOT FINAL ARCHITECTURE**

Reason: it has the strongest current central-target evidence, but iOS 15.8.8 runtime load, the exact private camera callback, threading, buffer ownership/lifetime, format, timing, and stability remain unproven.

## Next proof gate

If authorized by the Supervisor, the first functional proof must be limited to:

**LOAD / REACHABILITY / PASSIVE OBSERVATION**

The proof must not include:

- gallery;
- Media Engine;
- frame decode;
- frame conversion;
- shared frame IPC;
- virtual frame production;
- frame substitution.

### Required order

1. prove a minimal research dylib loads in the candidate process without changing camera behavior;
2. identify the exact iOS15.8.8 callback/symbol;
3. prove passive reachability while preserving original behavior;
4. characterize thread, sample-buffer/pixel-buffer lifetime, pixel format, dimensions and timing;
5. demonstrate fail-open/recovery behavior;
6. return to Supervisor audit.

Frame substitution remains prohibited until a later explicit order.

## Fail-open contract

The approved fail-open policy is unchanged:

- VCAM OFF / absent -> real/original behavior;
- no virtual state -> real/original behavior;
- unknown callback -> original behavior;
- invalid/incompatible buffer -> real/original behavior;
- error -> original behavior;
- injector/proof component unavailable -> original behavior.

No future design may block `mediaserverd` or another critical camera pipeline while waiting for media, IPC, decode, or a frame.

## Provenance

The research report documents names, filters, symbols, dependencies, public APIs and relationships only.

No proprietary dylib, closed implementation, converted disassembly, credentials, backend, anti-debug logic or commercial component has been copied into VCAM PRO.

See:

`docs/research/CENTRAL_INJECTION_IOS15.md`

for the full FACT / INFERENCE / UNKNOWN evidence map and source list.

## Public release

**NO**

No merge or public release is authorized by this research phase.
