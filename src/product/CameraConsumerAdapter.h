#pragma once

#include "ReadyFrameQueue.h"

#include <CoreVideo/CoreVideo.h>

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <optional>

namespace vcam::product {

enum class CameraDecisionKind : std::uint8_t {
    Original = 0,
    Virtual,
};

enum class CameraDecisionSource : std::uint8_t {
    Original = 0,
    PreparedMedia,
    BlackFallback,
    InPlaceBlackOwnershipGuard,
};

enum class CameraFailOpenReason : std::uint8_t {
    None = 0,
    Disabled,
    ReconfigurationContended,
    ProducerUnavailable,
    EmptyOrNoEligibleFrame,
    InvalidLease,
    GeometryMismatch,
    BlackFallbackUnavailable,
    UnsupportedPixelFormat,
};

class CameraDecisionPixelBufferLease final {
public:
    CameraDecisionPixelBufferLease() = default;

    CameraDecisionPixelBufferLease(
        const CameraDecisionPixelBufferLease& other) noexcept {
        retain(other.pixelBuffer_);
    }

    CameraDecisionPixelBufferLease&
    operator=(
        const CameraDecisionPixelBufferLease& other) noexcept {
        if (this != &other) {
            retain(other.pixelBuffer_);
        }
        return *this;
    }

    CameraDecisionPixelBufferLease(
        CameraDecisionPixelBufferLease&& other) noexcept
        : pixelBuffer_(other.pixelBuffer_) {
        other.pixelBuffer_ = nullptr;
    }

    CameraDecisionPixelBufferLease&
    operator=(
        CameraDecisionPixelBufferLease&& other) noexcept {
        if (this != &other) {
            reset();
            pixelBuffer_ = other.pixelBuffer_;
            other.pixelBuffer_ = nullptr;
        }
        return *this;
    }

    ~CameraDecisionPixelBufferLease() {
        reset();
    }

    void retain(
        CVPixelBufferRef pixelBuffer) noexcept {
        if (pixelBuffer_ == pixelBuffer) {
            return;
        }
        if (pixelBuffer != nullptr) {
            CVPixelBufferRetain(pixelBuffer);
        }
        reset();
        pixelBuffer_ = pixelBuffer;
    }

    void reset() noexcept {
        if (pixelBuffer_ != nullptr) {
            CVPixelBufferRelease(
                pixelBuffer_);
            pixelBuffer_ = nullptr;
        }
    }

private:
    CVPixelBufferRef pixelBuffer_ = nullptr;
};

struct CameraDecision {
    CameraDecisionKind kind =
        CameraDecisionKind::Original;
    CameraDecisionSource source =
        CameraDecisionSource::Original;
    CameraFailOpenReason reason =
        CameraFailOpenReason::None;
    CameraFailOpenReason mediaFailureReason =
        CameraFailOpenReason::None;
    CVPixelBufferRef pixelBuffer = nullptr;
    CameraDecisionPixelBufferLease
        pixelBufferLease{};
};

class CameraConsumerAdapter final {
public:
    static constexpr std::size_t
        kPinnedLeaseCapacity = 4;
    static constexpr std::size_t
        kPhotoVariantStructuralCapacity = 12;
    static constexpr std::size_t
        kPhotoVariantCapacity =
            kPhotoVariantStructuralCapacity;
    static constexpr std::size_t
        kPhotoVariantRetainedByteBudget =
            32U * 1024U * 1024U;
    static constexpr std::size_t
        kPhotoWorkingSetCapacity = 16;
    static constexpr std::uint64_t
        kPhotoWorkingSetActiveObservationWindow = 32;
    static constexpr std::size_t
        kBlackFallbackCapacity = 4;
    static constexpr std::size_t
        kVideoLatestFrameCapacity = 4;
    static constexpr std::size_t
        kVideoLatestRetainedByteBudget =
            16U * 1024U * 1024U;
    static constexpr std::uint32_t
        kVideoTransformTransitionReuseBudget = 60;

    CameraConsumerAdapter() = default;
    ~CameraConsumerAdapter();

    CameraConsumerAdapter(
        const CameraConsumerAdapter&) = delete;
    CameraConsumerAdapter& operator=(
        const CameraConsumerAdapter&) = delete;

    void setEnabled(bool enabled) noexcept;

    void bindQueue(
        frame_engine::ReadyFrameQueue* queue,
        std::uint64_t mediaGeneration,
        std::uint64_t timelineEpoch,
        bool producerHealthy,
        bool reusableStaticMedia = false,
        std::uint64_t reusableStaticRevision = 0,
        std::uint64_t mediaTransformRevision = 0);

    void updateContext(
        std::uint64_t mediaGeneration,
        std::uint64_t timelineEpoch,
        bool producerHealthy,
        bool reusableStaticMedia = false,
        std::uint64_t reusableStaticRevision = 0,
        std::uint64_t mediaTransformRevision = 0);

    void unbindQueue();

    bool bindBlackFallback(
        CVPixelBufferRef pixelBuffer);
    void clearBlackFallback() noexcept;

    CameraDecision decide(
        CVPixelBufferRef original) noexcept;

    std::size_t pinnedLeaseCount() const;
    std::size_t photoVariantCount() const;
    std::size_t photoVariantRetainedBytes() const;
    std::size_t photoVariantWorkingSetCount() const;
    std::uint64_t photoVariantEvictionCount() const;
    std::uint64_t photoVariantReprepareCount() const;
    std::size_t videoLatestFrameCount() const;
    std::size_t videoLatestRetainedBytes() const;
    std::uint64_t videoLatestReuseDecisionCount() const noexcept;
    std::uint64_t videoAcquireCount() const noexcept;
    std::size_t blackFallbackCacheCount() const;

    void notePhotoGeometryObserved(
        std::size_t width,
        std::size_t height,
        OSType pixelFormat,
        std::uint64_t mediaGeneration,
        std::uint64_t timelineEpoch,
        std::uint64_t transformRevision);

    bool hasReusablePhotoVariant(
        std::size_t width,
        std::size_t height,
        OSType pixelFormat,
        std::uint64_t mediaGeneration,
        std::uint64_t timelineEpoch,
        std::uint64_t transformRevision) const;

    bool hasCompatibleBlackFallback(
        CVPixelBufferRef original) const noexcept;

    std::uint64_t decisionCount() const noexcept;
    std::uint64_t virtualDecisionCount() const noexcept;
    std::uint64_t mediaVirtualDecisionCount() const noexcept;
    std::uint64_t blackVirtualDecisionCount() const noexcept;
    std::uint64_t emergencyOriginalDecisionCount() const noexcept;
    std::uint64_t inPlaceBlackGuardDecisionCount() const noexcept;
    std::uint64_t unsupportedFormatDecisionCount() const noexcept;
    std::uint64_t enabledSupportedOriginalDecisionCount() const noexcept;

private:
    struct PhotoVariantSlot {
        CVPixelBufferRef pixelBuffer = nullptr;
        std::uint64_t mediaGeneration = 0;
        std::uint64_t timelineEpoch = 0;
        std::uint64_t transformRevision = 0;
        std::size_t width = 0;
        std::size_t height = 0;
        OSType pixelFormat = 0;
        std::size_t retainedBytes = 0;
        std::uint64_t lastUseSerial = 0;
    };

    struct VideoLatestFrameSlot {
        CVPixelBufferRef pixelBuffer = nullptr;
        std::uint64_t mediaGeneration = 0;
        std::uint64_t timelineEpoch = 0;
        std::uint64_t transformRevision = 0;
        std::size_t width = 0;
        std::size_t height = 0;
        OSType pixelFormat = 0;
        std::size_t retainedBytes = 0;
        std::uint64_t lastUseSerial = 0;
    };

    struct PhotoWorkingSetEntry {
        bool valid = false;
        std::uint64_t mediaGeneration = 0;
        std::uint64_t timelineEpoch = 0;
        std::uint64_t transformRevision = 0;
        std::size_t width = 0;
        std::size_t height = 0;
        OSType pixelFormat = 0;
        std::uint64_t lastObservedSerial = 0;
        std::uint64_t observationCount = 0;
        bool preparedOnce = false;
        bool repreparePending = false;
    };

    bool matchesOriginalGeometry(
        CVPixelBufferRef original,
        const frame_engine::FrameLease& lease) const noexcept;

    bool matchesOriginalGeometry(
        CVPixelBufferRef original,
        CVPixelBufferRef candidate) const noexcept;

    void pin(
        frame_engine::ReadyFrameLease lease);

    void clearPhotoVariantsLocked() noexcept;
    void clearVideoLatestFramesLocked() noexcept;
    VideoLatestFrameSlot* findVideoLatestFrameLocked(
        CVPixelBufferRef original) noexcept;
    CVPixelBufferRef retainVideoLatestFrameLocked(
        CVPixelBufferRef pixelBuffer,
        std::uint64_t mediaGeneration,
        std::uint64_t timelineEpoch,
        std::uint64_t transformRevision) noexcept;
    std::uint64_t nextVideoLatestUseSerialLocked() noexcept;
    PhotoVariantSlot* findPhotoVariantLocked(
        CVPixelBufferRef original) noexcept;
    const PhotoVariantSlot* findPhotoVariantLocked(
        std::size_t width,
        std::size_t height,
        OSType pixelFormat,
        std::uint64_t mediaGeneration,
        std::uint64_t timelineEpoch,
        std::uint64_t transformRevision) const noexcept;
    CVPixelBufferRef retainPhotoVariantLocked(
        CVPixelBufferRef pixelBuffer,
        std::uint64_t mediaGeneration,
        std::uint64_t timelineEpoch,
        std::uint64_t transformRevision) noexcept;
    PhotoWorkingSetEntry* findPhotoWorkingSetEntryLocked(
        std::size_t width,
        std::size_t height,
        OSType pixelFormat,
        std::uint64_t mediaGeneration,
        std::uint64_t timelineEpoch,
        std::uint64_t transformRevision) noexcept;
    const PhotoWorkingSetEntry* findPhotoWorkingSetEntryLocked(
        std::size_t width,
        std::size_t height,
        OSType pixelFormat,
        std::uint64_t mediaGeneration,
        std::uint64_t timelineEpoch,
        std::uint64_t transformRevision) const noexcept;
    bool photoGeometryActiveLocked(
        const PhotoVariantSlot& slot) const noexcept;
    std::uint64_t nextPhotoVariantUseSerialLocked() noexcept;

    CameraDecision blackOrEmergencyOriginal(
        CVPixelBufferRef original,
        CameraFailOpenReason mediaFailureReason) noexcept;

    std::atomic<bool> enabled_{false};
    std::atomic<std::uint64_t> decisionCount_{0};
    std::atomic<std::uint64_t> virtualDecisionCount_{0};
    std::atomic<std::uint64_t> mediaVirtualDecisionCount_{0};
    std::atomic<std::uint64_t> blackVirtualDecisionCount_{0};
    std::atomic<std::uint64_t> emergencyOriginalDecisionCount_{0};
    std::atomic<std::uint64_t> inPlaceBlackGuardDecisionCount_{0};
    std::atomic<std::uint64_t> unsupportedFormatDecisionCount_{0};
    std::atomic<std::uint64_t> enabledSupportedOriginalDecisionCount_{0};
    std::atomic<std::uint64_t> videoLatestReuseDecisionCount_{0};
    std::atomic<std::uint64_t> videoAcquireCount_{0};

    mutable std::mutex mutex_;
    frame_engine::ReadyFrameQueue* queue_ = nullptr;
    frame_engine::QueueContext context_{};
    bool producerHealthy_ = false;
    bool reusableStaticMedia_ = false;
    std::uint64_t reusableStaticRevision_ = 0;
    std::uint64_t mediaTransformRevision_ = 0;
    std::uint32_t videoStaleTransformReuseBudget_ = 0;
    std::array<
        PhotoVariantSlot,
        kPhotoVariantStructuralCapacity>
        photoVariants_{};
    std::size_t photoVariantRetainedBytes_ = 0;
    std::array<
        PhotoWorkingSetEntry,
        kPhotoWorkingSetCapacity>
        photoWorkingSet_{};
    std::uint64_t photoGeometryObservationSerial_ = 0;
    std::uint64_t photoVariantUseSerial_ = 0;
    std::uint64_t photoVariantEvictionCount_ = 0;
    std::uint64_t photoVariantReprepareCount_ = 0;

    std::array<
        VideoLatestFrameSlot,
        kVideoLatestFrameCapacity>
        videoLatestFrames_{};
    std::size_t videoLatestRetainedBytes_ = 0;
    std::uint64_t videoLatestUseSerial_ = 0;

    std::array<
        std::optional<frame_engine::ReadyFrameLease>,
        kPinnedLeaseCapacity>
        pinned_{};
    std::size_t nextPinnedIndex_ = 0;

    std::atomic<CVPixelBufferRef>
        blackFallback_{nullptr};
    mutable std::mutex blackMutex_;
    std::array<
        CVPixelBufferRef,
        kBlackFallbackCapacity>
        blackFallbackHistory_{};
    std::size_t blackFallbackHistoryCount_ = 0;
};

}  // namespace vcam::product
