# VCAM PRO — Legacy Hook Structural Parity Audit 001

Task: `VCAM-PRO-LEGACY-HOOK-STRUCTURAL-PARITY-AUDIT-001`

Authoritative VCAM-PRO base: `ade6887fa6214ac1cd26b56f13e0d4f64e07e1d4`

Read-only IOS-15-USB reference: `a908bccbcddb4efc072bb1bc8fbeb6ee89b1af9d`

## Scope

Static comparison only. No hook is installed or executed. No camera consumer is opened. No CMSampleBuffer/CVPixelBuffer runtime access occurs. No frame substitution occurs. Dummy self-test branches are historical diagnostic evidence only and are not implementation candidates.

## Legacy evidence summary

| Point | Classification | Evidence |
|---|---|---|
| `_MSHookFunction` imported | PROVEN | `analysis/symbols/VCamRecovered.undefined-symbols.txt` contains `_MSHookFunction`. |
| `_CMSampleBufferGetImageBuffer` imported | PROVEN | Same undefined-symbol evidence contains `_CMSampleBufferGetImageBuffer`. |
| Hook marker | PROVEN | `analysis/strings/VCamRecovered.strings.txt` and disassembly contain `[VCam] Hooking CMSampleBufferGetImageBuffer`. |
| mediaserverd injection filter | PROVEN | `recovered/VCamRecovered.plist` names executable `mediaserverd` and bundle `com.apple.mediaserverd`. |
| Provider call uses CMSampleBuffer target | PROVEN | ARM64 disassembly has direct `bl` to the `_MSHookFunction` stub with x0 loaded from literal `_CMSampleBufferGetImageBuffer`; observed at two call sites around 0x5c8c4 and 0x5e0d0. |
| Direct provider import rather than runtime `dlsym` | PROVEN | Undefined import plus direct symbol-stub calls to `_MSHookFunction`; no claim is made that the binary contains no unrelated dynamic lookup mechanism. |
| Replacement-function concept | PROVEN | At both MSHookFunction call sites x1 is loaded from the same code address (0x175d4), and the disassembly contains a function entry at 0x175d4. The local semantic name is stripped, but the provider-argument role is statically established. |
| Original/trampoline storage concept | PROVEN | At both call sites x2 addresses the same writable storage at 0xa9000+0x500. The function at 0x175d4 later loads that storage and calls it via `blr x8` (including around 0x18940/0x18948 and 0x1a51c/0x1a524). The local variable name is stripped, but the original-trampoline storage-and-call pattern is statically established. |
| Exact legacy constructor/startup call context | NOT_DETERMINABLE | The dylib is stripped/obfuscated and the available static evidence does not identify a source-level constructor enclosing the hook call with sufficient certainty. |
| arm64 | PROVEN | Historical audit identifies a thin Mach-O 64-bit arm64 dylib. |
| minimum iOS | PROVEN | Historical LC_BUILD_VERSION records minimum iOS 14.0, therefore the binary's deployment target is compatible with iOS 15 at the Mach-O minimum-version level; this is not iOS 15.8.8 runtime proof. |
| rootless layout | PROVEN | Historical package uses `/var/jb/Library/MobileSubstrate/DynamicLibraries`. |
| media-source model | PROVEN / limited | Strings include `GET /vcam.mjpg`, `OBS PC IP`, and network host/auth text. These prove an external transport/UI model was embedded; static strings alone do not prove every runtime media path. |

## VCAM-PRO structural evidence summary

Unchanged `src/product/ReferenceCameraHook.mm` directly declares and invokes `MSHookFunction` with:

- target: `&CMSampleBufferGetImageBuffer`
- replacement: `&HookedCMSampleBufferGetImageBuffer`
- original storage: `&gOriginalCMSampleBufferGetImageBuffer`
- installation success predicate: `gOriginalCMSampleBufferGetImageBuffer != nullptr`

`src/product/VCAMProEntry.mm` has an explicit `mediaserverd` process guard and calls `MediaserverdRuntime::start()` before `InstallReferenceCameraHook()`.

VCAM-PRO uses the local-gallery media engine behind the existing runtime/camera-consumer adapter. This is an intentional frame-source adaptation, not a different hook-provider architecture.

## Structural parity matrix

| Dimension | IOS-15-USB legacy | VCAM-PRO | Parity assessment |
|---|---|---|---|
| mediaserverd targeting | PROVEN plist filter | PROVEN constructor process guard | MATCH |
| MSHookFunction usage | PROVEN direct import + direct symbol-stub calls | PROVEN direct declaration/call | MATCH |
| CMSampleBufferGetImageBuffer target | PROVEN at provider call sites | PROVEN source target argument | MATCH |
| replacement-function concept | PROVEN provider x1 → 0x175d4 function entry | PROVEN `HookedCMSampleBufferGetImageBuffer` | MATCH |
| original trampoline concept | PROVEN provider x2 storage later loaded/called | PROVEN `gOriginalCMSampleBufferGetImageBuffer` | MATCH |
| startup/load topology | PROVEN mediaserverd injection; exact constructor context NOT_DETERMINABLE | PROVEN constructor → runtime.start → install | COMPATIBLE; exact legacy timing unknown |
| arm64 compatibility | PROVEN arm64 | compile-only CI requires arm64 | MATCH |
| rootless layout | `/var/jb/Library/MobileSubstrate/DynamicLibraries` | Dopamine/RootHide TweakInject packaging in certified product path | ADAPTATION, not hook divergence |
| iOS 15 compatibility | Mach-O min iOS 14.0; iOS 15 runtime not proven by archive | compile-only min iOS 15.0 + frozen device readiness facts | COMPATIBLE |
| fail-open behavior | exact hook-failure behavior NOT_DETERMINABLE | explicit original-buffer fallback in hook path and non-null original predicate | VCAM-PRO is more explicit; no incompatible legacy fact found |
| media source | external MJPEG/OBS/PC evidence | local gallery/internal media engine | INTENTIONAL PRODUCT ADAPTATION |

## Conclusion

`LEGACY_STRUCTURAL_PARITY=CONFIRMED`

The relevant historical hook structure is preserved closely enough to reject further dummy-hook architecture work as unnecessary: mediaserverd targeting, direct MSHookFunction provider model, CMSampleBufferGetImageBuffer target, replacement concept, and original-storage/trampoline concept align. Rootless layout and media-source differences are expected product adaptations.

This conclusion is static only. It does **not** certify that the production camera hook has been installed or succeeds at runtime.

`DUMMY_SELFTEST_DEVELOPMENT=STOPPED`
`RUNTIME_HOOK_INSTALLATION=NOT_PERFORMED`
`CAMERA_INTERCEPTION=NOT_PERFORMED`
`FRAME_ACCESS=NOT_PERFORMED`
`FRAME_SUBSTITUTION=NOT_PERFORMED`
