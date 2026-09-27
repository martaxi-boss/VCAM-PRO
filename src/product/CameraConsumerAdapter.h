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
};

class CameraConsumerAdapter final {
public:
    static constexpr std::size_t
        kPinnedLeaseCapacity = 4;
    static constexpr std::size_t
        kBlackFallbackCapacity = 4;

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
        bool producerHealthy);

    void updateContext(
        std::uint64_t mediaGeneration,
        std::uint64_t timelineEpoch,
        bool producerHealthy);

    void unbindQueue();

    bool bindBlackFallback(
        CVPixelBufferRef pixelBuffer);
    void clearBlackFallback() noexcept;

    CameraDecision decide(
        CVPixelBufferRef original) noexcept;

    std::size_t pinnedLeaseCount() const;
    std::size_t blackFallbackCacheCount() const;

    std::uint64_t decisionCount() const noexcept;
    std::uint64_t virtualDecisionCount() const noexcept;
    std::uint64_t mediaVirtualDecisionCount() const noexcept;
    std::uint64_t blackVirtualDecisionCount() const noexcept;
    std::uint64_t emergencyOriginalDecisionCount() const noexcept;

private:
    bool matchesOriginalGeometry(
        CVPixelBufferRef original,
        const frame_engine::FrameLease& lease) const noexcept;

    bool matchesOriginalGeometry(
        CVPixelBufferRef original,
        CVPixelBufferRef candidate) const noexcept;

    void pin(
        frame_engine::ReadyFrameLease lease);

    CameraDecision blackOrEmergencyOriginal(
        CVPixelBufferRef original,
        CameraFailOpenReason mediaFailureReason) noexcept;

    std::atomic<bool> enabled_{false};
    std::atomic<std::uint64_t> decisionCount_{0};
    std::atomic<std::uint64_t> virtualDecisionCount_{0};
    std::atomic<std::uint64_t> mediaVirtualDecisionCount_{0};
    std::atomic<std::uint64_t> blackVirtualDecisionCount_{0};
    std::atomic<std::uint64_t> emergencyOriginalDecisionCount_{0};

    mutable std::mutex mutex_;
    frame_engine::ReadyFrameQueue* queue_ = nullptr;
    frame_engine::QueueContext context_{};
    bool producerHealthy_ = false;

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
