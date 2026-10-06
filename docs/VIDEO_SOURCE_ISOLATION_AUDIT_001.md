# VIDEO source isolation audit 001

Owner scope: audit, correct defects and continuous hygiene in VCAM-PRO only.
Starting HEAD: `7d54d864829980eb307f4898aae43fda2a7a9603`.
Date: 2026-10-06. Main remains frozen; references remain read only.

## Critical defect: local decoder enters the camera hook

`LocalVideoReader::readNext` calls `CMSampleBufferGetImageBuffer` after
`AVAssetReaderTrackOutput::copyNextSampleBuffer`. Production installs a global
`MSHookFunction` replacement for that same accessor in mediaserverd. The old
replacement observes every returned buffer as real camera geometry and applies
the camera ownership decision. With VCAM ON before a prepared frame exists,
that path sanitizes the decoder's source image to BLACK in place. With a
prepared frame it can overwrite the source with previously presented media.
It also feeds the video's source dimensions back as camera destination requests.
Reading, normalization and publication counters can all increase despite the
source pixels having been corrupted. This is an additional defect beyond the
previous queue/timer remediation, which is retained.

The previous host suites compiled hook ownership helpers or called runtime
decisions directly. They did not interpose the source reader accessor through
the installed callback. Thus their success did not cover this boundary.

Correction: a scoped, thread-local source access marker surrounds only decoder
sample extraction and image-buffer access. The hook obtains the original buffer
and returns it before camera geometry observation or ownership when this marker
is active. Camera callbacks on other threads remain fully owned; this introduces
no app list, orientation policy, transport, decoding in callback or new pipeline.
Nested scopes restore the previous marker automatically. No generation, epoch,
source PTS, playback or per-geometry presentation semantics are changed.

## Validation defect and hygiene

Live run `37143462806` passed the VIDEO gate. Central gate `37143462782`
failed before regressions, in its reference assertion step. The log shows the
now-removed `ORIGINAL_CAMERA_PIXEL_BUFFER` documentation token check. Replaced
it with the canonical explicit `VCAM_OFF_OUTPUT=ORIGINAL` check. No ownership
assertion is weakened. The two gates must run on the corrected implementation.

The VIDEO candidate receives a distinct version `0.1.0+roothide24~sourcefix1`
and filename `VCAM-PRO-RootHide-Video-Source-Isolation-001.deb`, so it is not
confused with the old installed presentation candidate. Existing packaging,
RootHide patcher, iOS 15 minimum, arm64 build and rollback history are preserved.
The packaging input builder previously removed the entire output directory,
erasing regression logs produced earlier in the same run. It now cleans only
packaging input subdirectories; the packaging audit separately clears its own
final/extracted/evidence directories. Current regression evidence survives the
build without reusing a stale package. The input builder's executable mode is
preserved.

## Added regression evidence

The source isolation test compiles the actual reader implementation with its
accessor redirected into the real hook callback. A generated local H.264 MOV
must retain nonblack luma while VCAM is enabled, without increasing camera
adapter decisions. Synthetic source samples additionally cover nested scopes,
a concurrent ON camera callback, camera ownership after scope exit and OFF
original pixels. Callback and reader are separate translation units, exercising
shared TLS identity. A negative fixture removes only the hook bypass and must
fail at the decoded source luma assertion, reproducing the prior corruption.

The normal A–F2, product composition, orientation and package audits remain in
the canonical gates. No host result certifies physical iPhone injection.

## Remaining runtime gate

After both exact-source gates pass, install the source-isolation candidate on
the certification iPhone and prove continuous VIDEO injection, pause/resume,
EOS-only loop, ON empty BLACK and OFF original output. Device installation and
observation are physical facts; the source defect's contribution to this exact
phone symptom is an inference until that retry. No device action, merge,
release or deployment occurs in this audit.

## Certification recovery

Initial source-isolation CI `37461527263` failed before the new source regression
in the prior continuity fixture: publication advanced `3 -> 8` in its fixed
0.5-second sample, exactly five rather than more than five. Source PTS advanced,
reader and scheduler remained healthy, and the queue remained populated. The
fixture now requires the same six additional publications against a monotonic
2-second deadline and reports elapsed milliseconds. This proves bounded
continuing publication, not A9 frame-rate performance. No production timing
policy changes or blind same-SHA reruns are used. The immutable successor task
`VCAM-PRO-VIDEO-CERTIFICATION-002` binds this existing regression file before
its mutation and carries the certification forward.

## Final metadata hygiene

Both source-isolation gates passed on `c3c52417be047cec7560155719eb1e8f34938161`
(runs `37461906600` and `37461906602`). The real reader/hook test preserved
source luma, the negative test reproduced source BLACK corruption, and the
continuity test observed six additional publications in 527 ms. These are
intermediate exact-code evidence, not certification of later package metadata.
The final metadata cleanup declares Maintainer, labels old 5 ms diagnostic
findings as historical, names the source-isolation package role and points the
canonical ledger to the immutable final Worker Result. Required gates recertify
this material metadata revision before handoff. No new physical VIDEO PASS is
claimed from any host run.
