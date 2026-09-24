# VCAM PRO — mediaserverd Load Probe 001

## Status

**BUILD-ONLY / DEVICE NOT RUN**

This artifact is a load-only preparation probe. It has been built and statically validated. It has **not** been installed or executed on an iPhone.

## Objective

The only intended future runtime statement is:

> This dylib was loaded inside `mediaserverd`.

This build does not prove that statement yet.

It does not implement camera observation, callback interception, frame access, or frame substitution.

## Exact baseline

Approved `main` base:

`bf1913f8d8fd3c02d791b483a1ecd60a25924e6f`

Workstream:

`builder/mediaserverd-load-probe-build-001`

## Source paths

Functional/package source:

- `proofs/mediaserverd_load_probe/Makefile`
- `proofs/mediaserverd_load_probe/control`
- `proofs/mediaserverd_load_probe/VCAMProLoadProbe.plist`
- `proofs/mediaserverd_load_probe/LoadProbe.c`

Build-only workflow:

- `.github/workflows/mediaserverd-load-probe-build.yml`

## Runtime behavior by design

`LoadProbe.c` is C only.

Its `__attribute__((constructor))` performs only:

1. read the current process name using `getprogname()`;
2. compare it with `mediaserverd`;
3. return immediately for every other process;
4. when the process name is exactly `mediaserverd`, emit one bounded unified-log marker containing process name and PID.

Expected marker:

`VCAM_PRO_LOAD_PROBE_001 process=%{public}s pid=%{public}d`

Defense in depth therefore exists both in the tweak filter and inside the constructor.

## Injection filter

Exact filter:

```text
Filter
└── Executables
    └── mediaserverd
```

No other executable, bundle, app, wildcard, SpringBoard, UIKit, Camera, WhatsApp, or broad target is present.

## Build configuration

- `THEOS_PACKAGE_SCHEME = rootless`
- `ARCHS = arm64`
- deployment target: iOS 15.0 minimum
- no arm64e
- install path declared to Theos: `/usr/lib/TweakInject`
- final rootless package path: `/var/jb/usr/lib/TweakInject`

Theos revision:

`dd5c14bb9d91311e221d51b5bfb8c9e5948156db`

## Build environment

Successful build ran in GitHub Actions on:

- runner image: `macos-26-arm64`
- macOS: `26.6.2`
- macOS build: `25G83`
- runner architecture: arm64
- Xcode: `26.6`
- Xcode build: `17F113`
- iPhoneOS SDK: `iPhoneOS26.5.sdk`
- Apple clang: `21.0.0 (clang-2100.1.1.101)`

The workflow uses no repository secrets, no private signing identities, no SSH, no device connection, no deployment, and no release.

Build command:

`make clean package FINALPACKAGE=1`

Successful workflow:

- GitHub Actions Run #3
- Run ID: `36055302355`
- Result: **SUCCESS**
- Head SHA built: `57a47031c41ea5c4383c243cc455d480432051ff`

Run URL:

`https://github.com/martaxi-boss/VCAM-PRO/actions/runs/36055302355`

### Build iteration record

History was not rewritten:

- Run #1 failed during workflow validation before any build job was created.
- Run #2 compiled and validated the source/package/Mach-O successfully; only the final artifact upload path was wrong.
- Run #3 repeated the build/validation successfully and uploaded the artifact successfully.

No functional probe change was needed after the initial source commit.

## Package result

Package filename:

`com.vcampro.loadprobe_0.0.1_iphoneos-arm64.deb`

Metadata:

- Package: `com.vcampro.loadprobe`
- Name: `VCAM PRO Load Probe`
- Version: `0.0.1`
- Architecture: `iphoneos-arm64`
- Depends: `firmware (>= 15.0), mobilesubstrate`

The `mobilesubstrate` dependency is package/ABI compatibility metadata. It does not assert that Cydia Substrate is the actual runtime loader on the Dopamine target.

Package SHA-256:

`d97e5be4c96a005d3fc630dfed7aeac837939e4843b912c7686803ad75061f62`

The downloaded GitHub Actions artifact was independently unpacked and the contained `.deb` matched the same SHA-256.

GitHub Actions artifact:

- name: `vcampro-mediaserverd-load-probe-deb`
- artifact ID: `10832507143`
- artifact ZIP digest: `sha256:c23ebcc9d8adca27e09668aa5c1b4efb46ce01105ecdf1458349d429c3fc2195`
- artifact expiration recorded by GitHub: 2026-10-08

## Installed file list

The package contains only these payload files:

- `/var/jb/usr/lib/TweakInject/VCAMProLoadProbe.dylib`
- `/var/jb/usr/lib/TweakInject/VCAMProLoadProbe.plist`

No rootful destination is used as the final package path.

## Maintainer-script validation

The extracted Debian control archive contains only:

- `control`

No custom:

- `preinst`
- `postinst`
- `prerm`
- `postrm`
- `extrainst_`

is present.

Therefore this package contains no package script that kills/restarts `mediaserverd`, SpringBoard, userspace, or the device.

## Source static validation

The functional source was checked to reject these tokens/API families:

- `%hook`
- `MSHookFunction`
- `MSHookMessageEx`
- `AVCapture`
- `CMSampleBuffer`
- `CVPixelBuffer`
- `VTDecompression`
- `IOSurface`
- `UIImagePicker`
- socket/connect/send/recv calls

Result:

**PASS**

The source contains exactly one occurrence of the required marker.

## Mach-O validation

Generated dylib:

`VCAMProLoadProbe.dylib`

`file` result:

`Mach-O 64-bit dynamically linked shared library arm64`

`lipo -archs` result:

`arm64`

Dependencies reported by `otool -L`:

- `@rpath/VCAMProLoadProbe.dylib`
- `/usr/lib/libSystem.B.dylib`

No deliberate or observed link dependency on:

- AVFoundation
- CoreMedia
- CoreVideo
- VideoToolbox
- Photos
- UIKit

Undefined-symbol inspection contained only the expected lightweight runtime/system references, including:

- stack-check helpers
- unified logging helpers
- `getpid`
- `getprogname`
- `strcmp`

No `MSHookFunction` or `MSHookMessageEx` symbol was present.

The required marker is present in the generated binary:

`VCAM_PRO_LOAD_PROBE_001 process=%{public}s pid=%{public}d`

## Explicit non-effects

This probe does **not**:

- hook any function or Objective-C method;
- use Logos hooks;
- swizzle methods;
- use fishhook;
- perform inline hooks or function rebinding;
- observe camera callbacks;
- import or deliberately link AVFoundation/CoreMedia/CoreVideo/VideoToolbox/Photos/UIKit;
- touch `CMSampleBuffer`;
- touch `CVPixelBuffer`;
- allocate frame buffers;
- produce frames;
- alter frames;
- delay frames;
- select media;
- create timers;
- create threads;
- create dispatch queues;
- use IPC;
- open sockets or perform networking;
- write runtime files;
- restart or kill `mediaserverd`;
- respring;
- userspace reboot;
- reboot the device.

## Device boundary

Device deployment:

**NOT PERFORMED**

No iPhone SSH, Sileo, dpkg install, dylib copy, respring, daemon restart, jailbreak-setting change, Camera test, WhatsApp test, or runtime log collection occurred in this task.

## Runtime claims

`mediaserverd` load:

**NOT YET PROVEN**

iOS 15.8.8 runtime:

**NOT YET PROVEN**

`mediaserverd` remains:

**LEADING RESEARCH CANDIDATE / NOT RUNTIME PROVEN**

It is not declared the final architecture.

## Frame access and substitution

Frame access:

**NO**

Frame substitution:

**PROHIBITED**

Any future device action requires a separate Supervisor-approved order. This build must not be interpreted as authorization to install, restart `mediaserverd`, begin reachability work, or substitute frames.
