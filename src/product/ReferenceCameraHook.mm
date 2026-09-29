#include "ReferenceCameraHook.h"

#include "MediaserverdRuntime.h"

#if defined(VCAM_ACTIVATION_PARITY_DEVICE_REMEDIATION_PROOF)
#include "ActivationParityDeviceRemediationProof.h"
#endif

#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>

#include <os/log.h>

namespace vcam::product {

namespace {

#if !defined(VCAM_REFERENCE_CAMERA_HOOK_OUTPUT_OWNERSHIP_TEST)
using CMSampleBufferGetImageBufferFunction =
    CVImageBufferRef (*)(
        CMSampleBufferRef);

CMSampleBufferGetImageBufferFunction
    gOriginalCMSampleBufferGetImageBuffer =
        nullptr;

extern "C" void MSHookFunction(
    void* symbol,
    void* replacement,
    void** original);
#endif

bool SameGeometryAndFormat(
    CVPixelBufferRef source,
    CVPixelBufferRef destination) noexcept {
    return
        source != nullptr &&
        destination != nullptr &&
        CVPixelBufferGetWidth(source) ==
            CVPixelBufferGetWidth(destination) &&
        CVPixelBufferGetHeight(source) ==
            CVPixelBufferGetHeight(destination) &&
        CVPixelBufferGetPixelFormatType(source) ==
            CVPixelBufferGetPixelFormatType(destination);
}

void CopyAttachmentIfPresent(
    CVPixelBufferRef source,
    CVPixelBufferRef destination,
    CFStringRef key) noexcept {
    if (source == nullptr ||
        destination == nullptr ||
        key == nullptr) {
        return;
    }

    CVAttachmentMode mode =
        kCVAttachmentMode_ShouldPropagate;
    CFTypeRef value =
        CVBufferGetAttachment(
            source,
            key,
            &mode);

    if (value != nullptr) {
        CVBufferSetAttachment(
            destination,
            key,
            value,
            mode);
    }
}

bool IsStillImageSampleBuffer(
    CMSampleBufferRef sampleBuffer) noexcept {
    if (sampleBuffer == nullptr) {
        return false;
    }

    CFTypeRef value =
        CMGetAttachment(
            sampleBuffer,
            CFSTR("StillImageKey"),
            nullptr);

    return value == kCFBooleanTrue;
}

#if defined(VCAM_ACTIVATION_PARITY_DEVICE_REMEDIATION_PROOF)
std::uint64_t PixelBufferGeometryKey(
    CVPixelBufferRef buffer) noexcept {
    if (buffer == nullptr) {
        return 0;
    }

    const std::size_t width =
        CVPixelBufferGetWidth(buffer);
    const std::size_t height =
        CVPixelBufferGetHeight(buffer);
    const OSType pixelFormat =
        CVPixelBufferGetPixelFormatType(
            buffer);

    if (width > 0xffffU ||
        height > 0xffffU) {
        return 0;
    }

    return
        static_cast<std::uint64_t>(width) |
        (static_cast<std::uint64_t>(height) << 16U) |
        (static_cast<std::uint64_t>(pixelFormat) << 32U);
}
#endif

}  // namespace

bool CommitVirtualCameraOutputIntoOriginal(
    CVPixelBufferRef virtualBuffer,
    CVPixelBufferRef original) noexcept {
    if (virtualBuffer == nullptr ||
        original == nullptr ||
        virtualBuffer == original ||
        !SameGeometryAndFormat(
            virtualBuffer,
            original) ||
        !CVPixelBufferIsPlanar(virtualBuffer) ||
        !CVPixelBufferIsPlanar(original) ||
        CVPixelBufferGetPlaneCount(
            virtualBuffer) != 2 ||
        CVPixelBufferGetPlaneCount(
            original) != 2) {
        return false;
    }

    const OSType pixelFormat =
        CVPixelBufferGetPixelFormatType(
            virtualBuffer);
    if (pixelFormat !=
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
        pixelFormat !=
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
        return false;
    }

    if (CVPixelBufferLockBaseAddress(
            virtualBuffer,
            kCVPixelBufferLock_ReadOnly) !=
        kCVReturnSuccess) {
        return false;
    }

    if (CVPixelBufferLockBaseAddress(
            original,
            0) != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(
            virtualBuffer,
            kCVPixelBufferLock_ReadOnly);
        return false;
    }

    bool success = true;

    for (std::size_t plane = 0;
         plane < 2;
         ++plane) {
        const auto* sourceBase =
            static_cast<const std::uint8_t*>(
                CVPixelBufferGetBaseAddressOfPlane(
                    virtualBuffer,
                    plane));
        auto* destinationBase =
            static_cast<std::uint8_t*>(
                CVPixelBufferGetBaseAddressOfPlane(
                    original,
                    plane));

        const std::size_t sourceStride =
            CVPixelBufferGetBytesPerRowOfPlane(
                virtualBuffer,
                plane);
        const std::size_t destinationStride =
            CVPixelBufferGetBytesPerRowOfPlane(
                original,
                plane);
        const std::size_t sourceHeight =
            CVPixelBufferGetHeightOfPlane(
                virtualBuffer,
                plane);
        const std::size_t destinationHeight =
            CVPixelBufferGetHeightOfPlane(
                original,
                plane);
        const std::size_t sourcePlaneWidth =
            CVPixelBufferGetWidthOfPlane(
                virtualBuffer,
                plane);
        const std::size_t destinationPlaneWidth =
            CVPixelBufferGetWidthOfPlane(
                original,
                plane);

        const std::size_t bytesPerSample =
            plane == 0 ? 1U : 2U;

        if (sourceBase == nullptr ||
            destinationBase == nullptr ||
            sourceHeight == 0 ||
            sourceHeight != destinationHeight ||
            sourcePlaneWidth == 0 ||
            sourcePlaneWidth !=
                destinationPlaneWidth ||
            sourcePlaneWidth >
                static_cast<std::size_t>(-1) /
                    bytesPerSample) {
            success = false;
            break;
        }

        const std::size_t activeBytes =
            sourcePlaneWidth *
            bytesPerSample;

        if (sourceStride < activeBytes ||
            destinationStride < activeBytes) {
            success = false;
            break;
        }

        for (std::size_t row = 0;
             row < sourceHeight;
             ++row) {
            std::memcpy(
                destinationBase +
                    row * destinationStride,
                sourceBase +
                    row * sourceStride,
                activeBytes);
        }
    }

    CVPixelBufferUnlockBaseAddress(
        original,
        0);
    CVPixelBufferUnlockBaseAddress(
        virtualBuffer,
        kCVPixelBufferLock_ReadOnly);

    if (!success) {
        return false;
    }

    CopyAttachmentIfPresent(
        virtualBuffer,
        original,
        kCVImageBufferColorPrimariesKey);
    CopyAttachmentIfPresent(
        virtualBuffer,
        original,
        kCVImageBufferTransferFunctionKey);
    CopyAttachmentIfPresent(
        virtualBuffer,
        original,
        kCVImageBufferYCbCrMatrixKey);

    CVBufferSetAttachment(
        original,
        CFSTR("vcam_patched"),
        kCFBooleanTrue,
        kCVAttachmentMode_ShouldPropagate);

    return true;
}

bool SanitizeSupportedCameraBufferToBlackInPlace(
    CVPixelBufferRef original) noexcept {
    if (original == nullptr ||
        !CVPixelBufferIsPlanar(original) ||
        CVPixelBufferGetPlaneCount(original) != 2) {
        return false;
    }

    const OSType format =
        CVPixelBufferGetPixelFormatType(
            original);
    std::uint8_t yValue = 0;
    if (format ==
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
        yValue = 16;
    } else if (
        format !=
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
        return false;
    }

    if (CVPixelBufferLockBaseAddress(
            original,
            0) != kCVReturnSuccess) {
        return false;
    }

    bool success = true;
    for (std::size_t plane = 0;
         plane < 2;
         ++plane) {
        auto* base =
            static_cast<std::uint8_t*>(
                CVPixelBufferGetBaseAddressOfPlane(
                    original,
                    plane));
        const std::size_t stride =
            CVPixelBufferGetBytesPerRowOfPlane(
                original,
                plane);
        const std::size_t height =
            CVPixelBufferGetHeightOfPlane(
                original,
                plane);

        if (base == nullptr ||
            stride == 0 ||
            height == 0) {
            success = false;
            break;
        }

        const std::uint8_t value =
            plane == 0
                ? yValue
                : 128;
        for (std::size_t row = 0;
             row < height;
             ++row) {
            std::memset(
                base + row * stride,
                value,
                stride);
        }
    }

    CVPixelBufferUnlockBaseAddress(
        original,
        0);

    if (success) {
        CVBufferSetAttachment(
            original,
            CFSTR("vcam_patched"),
            kCFBooleanTrue,
            kCVAttachmentMode_ShouldPropagate);
    }

    return success;
}

CVImageBufferRef ApplyCameraDecisionToOriginal(
    const CameraDecision& decision,
    CVImageBufferRef original,
    bool* commitAttempted,
    bool* commitSucceeded,
    bool* ownershipGuardApplied) noexcept {
    if (commitAttempted != nullptr) {
        *commitAttempted = false;
    }
    if (commitSucceeded != nullptr) {
        *commitSucceeded = false;
    }
    if (ownershipGuardApplied != nullptr) {
        *ownershipGuardApplied = false;
    }

    if (original == nullptr) {
        return nullptr;
    }

    if (decision.kind ==
            CameraDecisionKind::Original) {
        return original;
    }

    if (decision.source ==
            CameraDecisionSource::
                InPlaceBlackOwnershipGuard &&
        decision.pixelBuffer == original) {
        const bool guarded =
            SanitizeSupportedCameraBufferToBlackInPlace(
                original);
        if (ownershipGuardApplied != nullptr) {
            *ownershipGuardApplied = guarded;
        }
        return original;
    }

    if (decision.pixelBuffer != nullptr &&
        decision.pixelBuffer != original) {
        if (commitAttempted != nullptr) {
            *commitAttempted = true;
        }

        const bool committed =
            CommitVirtualCameraOutputIntoOriginal(
                decision.pixelBuffer,
                original);
        if (commitSucceeded != nullptr) {
            *commitSucceeded = committed;
        }

        if (committed) {
            return original;
        }

        const bool guarded =
            SanitizeSupportedCameraBufferToBlackInPlace(
                original);
        if (ownershipGuardApplied != nullptr) {
            *ownershipGuardApplied = guarded;
        }

        return guarded
            ? original
            : decision.pixelBuffer;
    }

    return original;
}

bool ReferenceSampleBufferHasStillImageKey(
    CMSampleBufferRef sampleBuffer) noexcept {
    return
        IsStillImageSampleBuffer(
            sampleBuffer);
}

#if !defined(VCAM_REFERENCE_CAMERA_HOOK_OUTPUT_OWNERSHIP_TEST)
namespace {

CVImageBufferRef HookedCMSampleBufferGetImageBuffer(
    CMSampleBufferRef sampleBuffer) {
    if (gOriginalCMSampleBufferGetImageBuffer ==
        nullptr) {
        return nullptr;
    }

    CVImageBufferRef original =
        gOriginalCMSampleBufferGetImageBuffer(
            sampleBuffer);

    if (original == nullptr) {
        return nullptr;
    }

    auto& runtime =
        MediaserverdRuntime::shared();

    runtime.observeRealCameraBuffer(
        original);

    const CameraDecision decision =
        runtime.decideCameraBuffer(
            original);

    bool commitAttempted = false;
    bool commitSucceeded = false;
    bool ownershipGuardApplied = false;

    CVImageBufferRef output =
        ApplyCameraDecisionToOriginal(
            decision,
            original,
            &commitAttempted,
            &commitSucceeded,
            &ownershipGuardApplied);

#if defined(VCAM_ACTIVATION_PARITY_DEVICE_REMEDIATION_PROOF)
    proof::ActivationParityHookObservation
        observation;
    observation.stillImageKeyPresent =
        IsStillImageSampleBuffer(
            sampleBuffer);
    observation.source =
        decision.source;
    observation.kind =
        decision.kind;
    observation.mediaFailureReason =
        decision.mediaFailureReason;
    observation.virtualCommitAttempted =
        commitAttempted;
    observation.virtualCommitSucceeded =
        commitSucceeded;
    observation.blackFallbackCompatible =
        runtime.cameraAdapter().
            hasCompatibleBlackFallback(
                original);
    observation.preparedFallbackExisted =
        decision.source ==
            CameraDecisionSource::PreparedMedia ||
        decision.mediaFailureReason ==
            CameraFailOpenReason::GeometryMismatch ||
        decision.mediaFailureReason ==
            CameraFailOpenReason::InvalidLease;
    observation.originalGeometry =
        PixelBufferGeometryKey(
            original);

    proof::ObserveActivationParityHook(
        observation);
#endif

    return output != nullptr
        ? output
        : original;
}

}  // namespace

bool InstallReferenceCameraHook() {
    os_log_with_type(
        OS_LOG_DEFAULT,
        OS_LOG_TYPE_DEFAULT,
        "[VCAM PRO] Hooking CMSampleBufferGetImageBuffer");

    MSHookFunction(
        reinterpret_cast<void*>(
            &CMSampleBufferGetImageBuffer),
        reinterpret_cast<void*>(
            &HookedCMSampleBufferGetImageBuffer),
        reinterpret_cast<void**>(
            &gOriginalCMSampleBufferGetImageBuffer));

    return
        gOriginalCMSampleBufferGetImageBuffer !=
        nullptr;
}
#endif

}  // namespace vcam::product
