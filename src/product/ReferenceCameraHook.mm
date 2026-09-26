#include "ReferenceCameraHook.h"

#include "MediaserverdRuntime.h"

#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

#include <os/log.h>

namespace vcam::product {

namespace {

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

    return decision.pixelBuffer != nullptr
        ? decision.pixelBuffer
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

}  // namespace vcam::product
