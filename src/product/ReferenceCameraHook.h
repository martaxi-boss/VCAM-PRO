#pragma once

#include "CameraConsumerAdapter.h"

#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

namespace vcam::product {

bool CommitVirtualCameraOutputIntoOriginal(
    CVPixelBufferRef virtualBuffer,
    CVPixelBufferRef original) noexcept;

bool SanitizeSupportedCameraBufferToBlackInPlace(
    CVPixelBufferRef original) noexcept;

CVImageBufferRef ApplyCameraDecisionToOriginal(
    const CameraDecision& decision,
    CVImageBufferRef original,
    bool* commitAttempted = nullptr,
    bool* commitSucceeded = nullptr,
    bool* ownershipGuardApplied = nullptr) noexcept;

bool ReferenceSampleBufferHasStillImageKey(
    CMSampleBufferRef sampleBuffer) noexcept;

bool InstallReferenceCameraHook();

#if defined(VCAM_REFERENCE_CAMERA_HOOK_SOURCE_ISOLATION_TEST)
CVImageBufferRef InvokeReferenceCameraHookForTesting(
    CMSampleBufferRef sampleBuffer);
#endif

}  // namespace vcam::product
