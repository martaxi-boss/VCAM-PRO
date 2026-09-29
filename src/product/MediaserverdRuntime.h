#pragma once

#include "CameraConsumerAdapter.h"

#include <CoreVideo/CoreVideo.h>

#include <array>
#include <cstdint>
#include <memory>
#include <string>

namespace vcam::product {

#if defined(VCAM_TESTING)
struct MediaserverdRuntimeTestSnapshot {
    bool enabled = false;
    bool photoSelected = false;
    bool videoSelected = false;
    bool hasMedia = false;
    std::uint64_t selectionGeneration = 0;
    std::uint64_t controlRefreshCount = 0;
    bool sessionExists = false;
    bool producerHealthy = false;
    std::size_t readyQueueSize = 0;
    std::uint64_t queueGeneration = 0;
    std::uint64_t queueEpoch = 0;
    std::uint64_t publishedFrameCount = 0;
    std::uint64_t photoDecodeCount = 0;
    std::uint64_t loopIteration = 0;
    std::uint64_t logicalPhotoSessionCreationCount = 0;
    std::uint64_t totalPhotoDecodeCount = 0;
    std::uint64_t photoVariantPreparationCount = 0;
    std::size_t photoVariantRetainedBytes = 0;
    std::size_t photoVariantWorkingSetCount = 0;
    std::uint64_t photoVariantEvictionCount = 0;
    std::uint64_t photoVariantReprepareCount = 0;
    std::array<std::uint64_t, 8> appliedGeometryHistory{};
    std::size_t appliedGeometryHistoryCount = 0;
};
#endif

class MediaserverdRuntime final {
public:
    MediaserverdRuntime();
#if defined(VCAM_TESTING)
    MediaserverdRuntime(
        std::string controlPath,
        std::string notificationName);

    bool drainControlQueueForTesting();
    bool suspendControlQueueForTesting();
    bool resumeControlQueueForTesting();
    MediaserverdRuntimeTestSnapshot
    snapshotForTesting();
#endif
    ~MediaserverdRuntime();

    MediaserverdRuntime(
        const MediaserverdRuntime&) = delete;
    MediaserverdRuntime& operator=(
        const MediaserverdRuntime&) = delete;

    static MediaserverdRuntime& shared();

    bool start();

    void observeRealCameraBuffer(
        CVPixelBufferRef buffer) noexcept;

    CameraDecision decideCameraBuffer(
        CVPixelBufferRef original) noexcept;

    CameraConsumerAdapter&
    cameraAdapter() noexcept;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace vcam::product
