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
    std::uint64_t logicalVideoSessionCreationCount = 0;
    std::uint64_t videoReaderOpenCount = 0;
    std::uint64_t videoReaderStartCount = 0;
    std::uint64_t videoSessionReplacementCount = 0;
    std::uint64_t totalVideoPublishedFrameCount = 0;
    bool videoReaderOpen = false;
    bool videoReaderStarted = false;
    std::uint8_t videoReaderError = 0;
    std::uint64_t videoReadFrameCount = 0;
    std::uint8_t videoLastReadResult = 0;
    bool videoHasLastSourcePTS = false;
    std::int64_t videoLastSourcePTSValue = 0;
    std::int32_t videoLastSourcePTSTimescale = 0;
    std::uint64_t videoNormalizeSuccessCount = 0;
    std::uint64_t videoNormalizeFailureCount = 0;
    std::uint64_t videoTransformSuccessCount = 0;
    std::uint64_t videoTransformFailureCount = 0;
    std::uint64_t videoTimelineReadyCount = 0;
    std::uint64_t videoTimelineWaitCount = 0;
    std::uint64_t videoTimelineDropCount = 0;
    std::uint8_t videoDriverState = 0;
    std::uint64_t videoAcquireCount = 0;
    std::uint64_t videoLatestReuseCount = 0;
    std::uint64_t videoPreparedMediaDecisionCount = 0;
    std::uint64_t videoBlackDecisionCount = 0;
    std::uint64_t videoCommitSuccessCount = 0;
    std::uint64_t videoCommitFailureCount = 0;
    std::uint8_t currentTargetOrientation = 0;
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
    bool stopVideoProducerForTesting();
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

    // Callback-safe diagnostic counters only. Serialization is performed
    // later on the mediaserverd control queue.
    void noteCameraCommitResult(
        bool attempted,
        bool succeeded) noexcept;

    CameraConsumerAdapter&
    cameraAdapter() noexcept;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace vcam::product
