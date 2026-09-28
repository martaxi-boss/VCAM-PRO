# IOS-15-USB Still Capture Parity 001

## Scope

Reference repository (READ ONLY):

`martaxi-boss/IOS-15-USB`

Exact reference HEAD:

`a908bccbcddb4efc072bb1bc8fbeb6ee89b1af9d`

Recovered binary:

`recovered/VCamRecovered.dylib`

Recovered binary blob:

`49c7068f07c56d88dd578759cbbd2899e69e3b9b`

The previously committed
`analysis/disassembly/VCamRecovered.disassembly.txt` is empty.  This report
therefore uses a fresh exact-SHA macOS disassembly produced by the
VCAM-PRO CI forensic job.  Imports or nearby strings alone are not treated
as proof of control flow.

## Evidence classes

- **PROVEN** — direct instruction/data-flow evidence in the exact recovered
  Mach-O.
- **STRONGLY_SUPPORTED** — multiple direct observations support the
  interpretation but stripped/obfuscated control flow prevents a complete
  semantic reconstruction.
- **UNRESOLVED** — the recovered evidence is insufficient to claim the
  relationship.

## Central hook installation

### PROVEN

The reference installs `MSHookFunction` against
`CMSampleBufferGetImageBuffer`.

Recovered installer callsites around `0x5c8b0` and `0x5e0b8` resolve:

- target: `_CMSampleBufferGetImageBuffer`;
- replacement: `0x175d4`;
- original trampoline storage: global `0xa9500`.

The central replacement begins at `0x175d4`.

No different C-function target has been established from the recovered
`MSHookFunction` installer callsites audited in this binary.

## Original camera pixel buffer

### PROVEN

Inside replacement `0x175d4`, the stored original trampoline is invoked
with the incoming sample buffer.

Representative path:

- `0x18944`: call original `CMSampleBufferGetImageBuffer`;
- `0x1894c-0x18950`: preserve returned pixel buffer in the local later
  captured as block field `+0x20`.

An alternate path repeats the same operation around
`0x1a520-0x1a52c`.

Thus block capture `+0x20` is the original camera pixel buffer.

## Virtual frame source

### PROVEN

Under the reference manager lock, the replacement:

1. reads `VCamManager.frameQueue`;
2. checks queue count;
3. calls `lastObject`;
4. calls `pointerValue`;
5. retains the recovered `CVPixelBufferRef`.

This occurs in the replacement around `0x1941c-0x195ec` and again in a
parallel path around `0x1a690-0x1a920`.

The resulting virtual pixel buffer is captured in block field `+0x28`.

Therefore `frameQueue / lastObject` directly feeds the central replacement
path.

## StillImageKey branch

### PROVEN

The exact `__cfstring` mapping establishes:

- CFString object `0x986c0` -> `"StillImageKey"`;
- CFString object `0x986a0` -> `"vcam_patched"`;
- nearby object `0x98680` -> `"Orientation"`.

Within the same `CMSampleBufferGetImageBuffer` replacement:

- `0x19798`: load incoming sampleBuffer;
- `0x197a0`: load CFString object `0x986c0`;
- `0x197a8`: call `CMGetAttachment(sampleBuffer, StillImageKey, ...)`;
- `0x197e0-0x197f4`: compare returned attachment to
  `kCFBooleanTrue`.

The resulting boolean is captured into the processing block at field
`+0x31`.

Therefore the historical replacement is sample-buffer aware and explicitly
classifies calls using `StillImageKey`.

## Virtual-to-original render ownership

### PROVEN

The processing block invoke begins at `0x1aa0c`.  Its captured arguments
are:

- `+0x20`: ORIGINAL camera pixel buffer;
- `+0x28`: VIRTUAL frameQueue pixel buffer;
- `+0x31`: StillImageKey boolean.

The block passes those values to wrapper `0x87308`, which reaches helper
`0x14390(original, virtual, stillFlag)`.

At helper setup:

- `0x151e4`: original input is in `x11`;
- `0x151e0`: virtual input is in `x10`;
- `0x153ec-0x153f0`: original is stored in helper slot `#0x150`;
- `0x153f4-0x153f8`: virtual is stored in helper slot `#0x148`.

At render time:

- `0x15e14-0x15e24`: slot `#0x148` (VIRTUAL) is passed to
  `CIImage imageWithCVPixelBuffer:`;
- `0x16ab0-0x16ac8`: the processed CIImage is passed as the source to
  `render:toCVPixelBuffer:`, while slot `#0x150` (ORIGINAL) is the
  destination;
- a second corresponding render exists around `0x174f4-0x1750c`.

Thus the recovered implementation renders virtual frame content into the
original camera pixel buffer rather than relying solely on returning an
alternate virtual `CVPixelBufferRef`.

The StillImageKey boolean participates in this helper's conditional
processing.  Exact orientation/crop sub-branch semantics are not required
to establish source and destination ownership.

## Returned pixel-buffer identity

### PROVEN

The replacement stores the ORIGINAL pixel buffer into its return path:

- `0x1a158-0x1a160`: original local is copied into return-state slot
  `x19+0x58`;
- `0x1a1f8-0x1a1fc` / `0x1a9a0-0x1a9a4`: that value becomes the
  final return local;
- `0x1a328-0x1a3b4`: final return local is moved to `x0` and returned.

Therefore the historical central semantic is:

`virtual content -> ORIGINAL camera pixel buffer -> return ORIGINAL buffer`.

This differs materially from current VCAM-PRO's pre-remediation behavior,
which returns `decision.pixelBuffer` when a virtual decision succeeds.

## vcam_patched attachment

### PROVEN

After the virtual-to-original processing block, the reference marks the
original pixel buffer.

The block path loads:

- original buffer;
- CFString object `0x986a0` = `"vcam_patched"`;
- `kCFBooleanTrue`;
- propagating attachment mode value.

Wrapper `0x87330` resolves to `CVBufferSetAttachment`.

Thus `vcam_patched=true` is placed on the original camera pixel buffer in
the historical central path.

## CMSampleBufferCreateReady

### PROVEN: imported and used

`CMSampleBufferCreateReady` is called at approximately `0x119bc` inside
a separate helper beginning around `0x10d6c`.  The same helper also uses
`CMBlockBufferCreateWithMemoryBlock`.

Recovered callers of the helper include sites near:

- `0x24fb0`;
- `0x26498`;
- `0x2da10`;
- `0x8778c`.

### UNRESOLVED: still-output relationship

No direct call from the central replacement range
`0x175d4..0x1aa0c` to the `0x10d6c` helper was established.

Therefore the binary does **not** justify introducing
`CMSampleBufferCreateReady` into VCAM-PRO solely from import adjacency.

## Other attachment / transfer APIs

### PROVEN

The binary imports and calls:

- `CVBufferGetAttachment`;
- `CVBufferSetAttachment`;
- `CVBufferRemoveAttachment`;
- `VTPixelTransferSessionTransferImage`.

### UNRESOLVED for this central still branch

The audited `VTPixelTransferSessionTransferImage` callsites are outside the
central replacement range.  They are not sufficient to claim that
VideoToolbox transfer is the historical still-output mechanism.

## Requested determinations

### A. Is CMSampleBufferGetImageBuffer the only relevant hooked C function?

**PROVEN within the audited MSHookFunction installer callsites:** the recovered
central installer targets `CMSampleBufferGetImageBuffer`.

No additional still-output C-function hook is established by this audit.
Because the binary is stripped/obfuscated, this statement is limited to the
recovered installer evidence rather than an assertion about every possible
runtime interception mechanism.

### B. Does the binary check StillImageKey on CMSampleBufferRef?

**PROVEN.**

See `0x19798-0x197f4`.

### C. Does CMGetAttachment participate?

**PROVEN.**

The replacement directly calls
`CMGetAttachment(sampleBuffer, @"StillImageKey", ...)`.

### D. Is CMSampleBufferCreateReady reached from still-image-related code?

**UNRESOLVED / NOT PROVEN.**

It is used by the binary, but the audited central replacement does not call
that helper directly.

### E. Is a replacement CMSampleBuffer constructed for still capture?

**UNRESOLVED / NOT PROVEN.**

The evidence does not justify this conclusion.

### F. How do frameQueue / lastObject / CIContext feed the relevant path?

**PROVEN.**

`frameQueue.lastObject.pointerValue` supplies the VIRTUAL pixel buffer.  A
Core Image helper consumes that VIRTUAL buffer as image source and renders
into the ORIGINAL camera pixel buffer.

### G. Are still and preview output separate processing branches?

**STRONGLY_SUPPORTED, with a bounded conclusion.**

The same central replacement explicitly reads `StillImageKey` and passes
that boolean into its pixel-buffer processing helper, proving a still-aware
branch inside the common hook.

A completely separate final still-output hook or a separate replacement
CMSampleBuffer path was **not** established.

## VCAM-PRO remediation relevance

### PROVEN divergence

Before this remediation, VCAM-PRO's `ReferenceCameraHook.mm`:

1. obtains the original camera pixel buffer;
2. asks `MediaserverdRuntime` for a decision;
3. returns the selected virtual `CVPixelBufferRef` directly when non-null.

The recovered IOS-15-USB central implementation instead:

1. obtains the original camera pixel buffer;
2. obtains the virtual frame;
3. renders the virtual content **into the original buffer**;
4. marks the original `vcam_patched=true`;
5. returns the original buffer.

This is an objective central ownership difference relevant to both:

- prepared PHOTO content losing to BLACK/physical pipeline behavior; and
- still/flash paths that may retain or later consume the original sample
  buffer image-buffer identity.

### Evidence-gated change authorization

This binary reconstruction satisfies the packet's reference evidence gate
for a minimum sample-buffer-aware correction in the existing
`CMSampleBufferGetImageBuffer` hook.

It does **not** authorize a new hook target, per-app interception, shutter/UI
suppression, or speculative `CMSampleBufferCreateReady` reconstruction.
