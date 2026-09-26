# VCAM PRO — Full Camera + Internal Gallery Test DEB 001

## Static reference-derived system contract

IOS-15-USB at a908bccbcddb4efc072bb1bc8fbeb6ee89b1af9d proves:

- rootless MobileSubstrate payload and mediaserverd/SpringBoard/UIKit filter;
- undefined MSHookFunction and CMSampleBufferGetImageBuffer symbols;
- constructor-side MSHookFunction target = CMSampleBufferGetImageBuffer;
- reference replacement/original pointer registration through MSHookFunction;
- CVPixelBufferRetain / CVPixelBufferRelease lifetime behavior;
- shared rootless preferences plus Darwin notification;
- RPATHs for /var/jb/Library/Frameworks, /var/jb/usr/lib and .jbroot equivalents.

IOS-16-USB-4k at cc20d787070c67565173d4a46c218e2549cecc93 confirms the same system topology and adds pool/rotation primitives. VCAM PRO retains its already accepted E1/F1/F2 equivalents rather than replacing them.

## VCAM PRO product path

Control side:

PHPicker -> copy/validate candidate -> /var/jb/var/mobile/Library/VCAMPro/Media/
-> com.vcampro.control plist -> com.vcampro.controlChanged Darwin notification.

System side:

mediaserverd control observer -> cached snapshot -> accepted InternalGalleryMediaSession
-> accepted LocalVideoReader / LocalPhotoReader -> FramePipelinePump -> E1 -> ReadyFrameQueue -> F1/F2.

Camera fast path:

original CMSampleBufferGetImageBuffer -> cached VCAM enabled state
-> CameraConsumerAdapter -> tryAcquire eligible frame -> bounded retained lease ring
-> virtual CVPixelBuffer only when generation/epoch/geometry/lifetime are valid
-> otherwise original buffer.

The camera hook performs no file reads, picker work, decode, scaling, rotation, conversion, sleeps, or network work.

## Product lifecycle

The SpringBoard control owner survives dismissal of the gallery panel. Closing the UI does not clear selected media.

Replacement is transactional on the control side: a picker/provider candidate is copied and validated before shared state changes. The previous owned media file is removed only after the new state is committed. Cancellation or invalid media leaves the previous selection intact.

The mediaserverd runtime also builds a replacement InternalGalleryMediaSession before switching the CameraConsumerAdapter binding. Geometry changes observed from the real camera only schedule asynchronous producer reconstruction; the current camera callback fails open until a matching prepared frame exists.

## Install/reload

The package postinst only creates/chowns/chmods the VCAM shared media directory. It does not execute a camera proof, restart mediaserverd, respring, restart SpringBoard, reboot userspace, perform login setup, or initialize networking.

Because MobileSubstrate injection occurs when target processes start, the normal post-install device proof should install fully in Sileo and then perform one normal userspace restart from the jailbreak/UI environment before testing. This is a later device action and is not performed or claimed by this build task.

## Static/build proof versus device proof

STATIC/BUILD candidate includes the reference-derived hook seam, local control plane, accepted Frame Engine A-F2, internal gallery, rootless payload and one deb.

DEVICE/RUNTIME remains unproven for actual dylib loading, real callback compatibility, real frame substitution, Photos behavior on the certification device, and A9 performance.
