#include "CameraConsumerAdapter.h"

#include <utility>

namespace vcam::product {

void CameraConsumerAdapter::setEnabled(
    bool enabled) noexcept {
    enabled_.store(
        enabled,
        std::memory_order_release);
}

void CameraConsumerAdapter::bindQueue(
    frame_engine::ReadyFrameQueue* queue,
    std::uint64_t mediaGeneration,
    std::uint64_t timelineEpoch,
    bool producerHealthy) {
    std::lock_guard<std::mutex> lock(mutex_);
    queue_ = queue;
    context_.currentMediaGeneration =
        mediaGeneration;
    context_.currentTimelineEpoch =
        timelineEpoch;
    context_.minimumSequence =
        std::nullopt;
    producerHealthy_ = producerHealthy;
}

void CameraConsumerAdapter::updateContext(
    std::uint64_t mediaGeneration,
    std::uint64_t timelineEpoch,
    bool producerHealthy) {
    std::lock_guard<std::mutex> lock(mutex_);
    context_.currentMediaGeneration =
        mediaGeneration;
    context_.currentTimelineEpoch =
        timelineEpoch;
    context_.minimumSequence =
        std::nullopt;
    producerHealthy_ = producerHealthy;
}

void CameraConsumerAdapter::unbindQueue() {
    std::lock_guard<std::mutex> lock(mutex_);
    queue_ = nullptr;
    producerHealthy_ = false;
    context_ = {};
}

CameraDecision CameraConsumerAdapter::decide(
    CVPixelBufferRef original) noexcept {
    decisionCount_.fetch_add(
        1,
        std::memory_order_relaxed);

    CameraDecision decision;
    decision.pixelBuffer = original;

    if (!enabled_.load(
            std::memory_order_acquire)) {
        decision.reason =
            CameraFailOpenReason::Disabled;
        return decision;
    }

    std::unique_lock<std::mutex> lock(
        mutex_,
        std::try_to_lock);
    if (!lock.owns_lock()) {
        decision.reason =
            CameraFailOpenReason::
                ReconfigurationContended;
        return decision;
    }

    if (queue_ == nullptr ||
        !producerHealthy_) {
        decision.reason =
            CameraFailOpenReason::
                ProducerUnavailable;
        return decision;
    }

    auto acquired =
        queue_->tryAcquire(context_);
    if (acquired.kind !=
            frame_engine::AcquireResultKind::Acquired ||
        !acquired.lease.has_value()) {
        decision.reason =
            CameraFailOpenReason::
                EmptyOrNoEligibleFrame;
        return decision;
    }

    const frame_engine::FrameLease* lease =
        acquired.lease->frameLease();
    if (!acquired.lease->valid() ||
        lease == nullptr ||
        lease->pixelBuffer() == nullptr) {
        decision.reason =
            CameraFailOpenReason::InvalidLease;
        return decision;
    }

    if (!matchesOriginalGeometry(
            original,
            *lease)) {
        decision.reason =
            CameraFailOpenReason::
                GeometryMismatch;
        return decision;
    }

    CVPixelBufferRef selected =
        lease->pixelBuffer();

    pin(std::move(*acquired.lease));

    virtualDecisionCount_.fetch_add(
        1,
        std::memory_order_relaxed);

    decision.kind =
        CameraDecisionKind::Virtual;
    decision.reason =
        CameraFailOpenReason::None;
    decision.pixelBuffer = selected;
    return decision;
}

std::size_t
CameraConsumerAdapter::pinnedLeaseCount() const {
    std::lock_guard<std::mutex> lock(mutex_);
    std::size_t count = 0;
    for (const auto& entry : pinned_) {
        if (entry.has_value() &&
            entry->valid()) {
            ++count;
        }
    }
    return count;
}

std::uint64_t
CameraConsumerAdapter::decisionCount() const noexcept {
    return decisionCount_.load(
        std::memory_order_relaxed);
}

std::uint64_t
CameraConsumerAdapter::virtualDecisionCount() const noexcept {
    return virtualDecisionCount_.load(
        std::memory_order_relaxed);
}

bool CameraConsumerAdapter::
matchesOriginalGeometry(
    CVPixelBufferRef original,
    const frame_engine::FrameLease& lease)
    const noexcept {
    if (original == nullptr) {
        return false;
    }

    return
        CVPixelBufferGetWidth(original) ==
            lease.width() &&
        CVPixelBufferGetHeight(original) ==
            lease.height() &&
        CVPixelBufferGetPixelFormatType(
            original) ==
            lease.pixelFormat();
}

void CameraConsumerAdapter::pin(
    frame_engine::ReadyFrameLease lease) {
    pinned_[nextPinnedIndex_].reset();
    pinned_[nextPinnedIndex_].emplace(
        std::move(lease));

    nextPinnedIndex_ =
        (nextPinnedIndex_ + 1) %
        kPinnedLeaseCapacity;
}

}  // namespace vcam::product
