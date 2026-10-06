// Test-only interposition: import system declarations before redirecting the
// accessor in the actual production reader translation unit.
#import <AVFoundation/AVFoundation.h>
#include "ReferenceCameraHook.h"
#define CMSampleBufferGetImageBuffer vcam::product::InvokeReferenceCameraHookForTesting
#include "../../src/media_engine/LocalVideoReader.mm"
#undef CMSampleBufferGetImageBuffer
