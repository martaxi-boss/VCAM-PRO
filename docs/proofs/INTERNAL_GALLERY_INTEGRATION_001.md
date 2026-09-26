# VCAM PRO — Internal Gallery Integration 001

## Implemented path

VCAM PRO control (PHPickerViewController, selectionLimit=1)
-> immediate copy to VCAM-owned local cache
-> selected-media record + generation
-> Video: existing LocalVideoReader
   Photo: LocalPhotoReader (decode/orientation/RGB->420 once per selection)
-> LocalFrameSource contract
-> existing FramePipelinePump
-> existing FrameNormalizer / FrameTransformer
-> existing ReadyFrameQueue
-> existing F1 scheduler / F2 ProducerWakeupDriver

LocalVideoReader remains the video reader. The only pump generalization is the
producer-side LocalFrameSource boundary used by both local video and still-photo sources.

Photos are decoded once with public ImageIO/CoreGraphics APIs, orientation-normalized,
converted once with public Accelerate/vImage into explicit 420f/420v storage, and reuse
that CVPixelBuffer while the selection stays active. Each emitted still frame receives a
new FrameIdentity and coherent source PTS/duration from the explicit FPS ratio (default 30/1).

Changing media stops the current producer/source before opening the replacement.
The replacement advances media generation and stale queue entries are purged.
clearMedia() is the minimal explicit no-media transition: it advances generation/epoch,
returns playback to Empty, resets reader state, and makes old frames ineligible.
No synthetic black fallback is generated.

The picker never retains a provider temporary URL. Its file representation is copied
immediately into the VCAM control-session cache. Duplicate/stale async picker completions
are rejected by SelectionCompletionGate.

## STATIC / BUILD PROVEN

- public iOS APIs only
- arm64 build
- deployment target iOS 15.0
- -Werror and -Werror=unguarded-availability-new
- UIKit + PhotosUI integration harness links
- photo and video terminate in the accepted pump/queue path
- no OBS dependency
- no network API
- no PrivateFrameworks
- no camera hook/frame substitution
- no Gate 1 dependency or Load Probe mutation
- deterministic gallery/media regression coverage

## DEVICE / RUNTIME NOT YET PROVEN

No device action is part of this workstream. Picker presentation on the certification
device, Photos-library behavior, real-media compatibility breadth, sustained memory/
performance, and future end-to-end camera substitution remain runtime facts for a later
Supervisor-authorized proof.
