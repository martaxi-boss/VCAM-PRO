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

enum class CameraFailOpenReason : std::uint8_t {
    None = 0,
    Disabled,
    ReconfigurationContended,
    ProducerUnavailable,
    EmptyOrNoEligibleFrame,
    InvalidLease,
    GeometryMismatch,
};

struct CameraDecision {
    CameraDecisionKind kind =
        CameraDecisionKind::Original;
    CameraFailOpenReason reason =
        CameraFailOpenReason::None;
    CVPixelBufferRef pixelBuffer = nullptr;
};

class CameraConsumerAdapter final {
public:
    static constexpr std::size_t
        kPinnedLeaseCapacity = 4;

    CameraConsumerAdapter() = default;
    ~CameraConsumerAdapter() = default;

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

    CameraDecision decide(
        CVPixelBufferRef original) noexcept;

    std::size_t pinnedLeaseCount() const;
    std::uint64_t decisionCount() const noexcept;
    std::uint64_t virtualDecisionCount() const noexcept;

private:
    bool matchesOriginalGeometry(
        CVPixelBufferRef original,
        const frame_engine::FrameLease& lease) const noexcept;

    void pin(
        frame_engine::ReadyFrameLease lease);

    std::atomic<bool> enabled_{false};
    std::atomic<std::uint64_t> decisionCount_{0};
    std::atomic<std::uint64_t> virtualDecisionCount_{0};

    mutable std::mutex mutex_;
    frame_engine::ReadyFrameQueue* queue_ = nullptr;
    frame_engine::QueueContext context_{};
    bool producerHealthy_ = false;

    std::array<
        std::optional<frame_engine::ReadyFrameLease>,
        kPinnedLeaseCapacity>
        pinned_{};
    std::size_t nextPinnedIndex_ = 0;
};

}  // namespace vcam::product
