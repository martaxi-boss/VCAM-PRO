#include "ReadyFrameQueue.h"

#include <atomic>
#include <stdexcept>
#include <utility>

namespace vcam::frame_engine {

struct ReadyFrameLeaseTracker {
    std::atomic<bool> leased{false};
    std::atomic<bool> consumed{false};
};

struct ReadyFrameQueue::Entry {
    explicit Entry(PreparedFrame&& preparedFrame)
        : frame(std::move(preparedFrame)),
          tracker(std::make_shared<ReadyFrameLeaseTracker>()) {}

    PreparedFrame frame;
    std::shared_ptr<ReadyFrameLeaseTracker> tracker;
};

ReadyFrameLease::ReadyFrameLease(
    FrameLease&& lease,
    std::shared_ptr<ReadyFrameLeaseTracker> tracker)
    : lease_(std::move(lease)),
      tracker_(std::move(tracker)) {}

ReadyFrameLease::ReadyFrameLease(ReadyFrameLease&& other) noexcept
    : lease_(std::move(other.lease_)),
      tracker_(std::move(other.tracker_)) {
    other.lease_.reset();
}

ReadyFrameLease& ReadyFrameLease::operator=(
    ReadyFrameLease&& other) noexcept {
    if (this != &other) {
        releaseTracking();
        lease_.reset();

        lease_ = std::move(other.lease_);
        tracker_ = std::move(other.tracker_);
        other.lease_.reset();
    }
    return *this;
}

ReadyFrameLease::~ReadyFrameLease() {
    releaseTracking();
}

bool ReadyFrameLease::valid() const noexcept {
    return lease_.has_value() && lease_->isValid();
}

const FrameLease* ReadyFrameLease::frameLease() const noexcept {
    return lease_ ? &(*lease_) : nullptr;
}

void ReadyFrameLease::releaseTracking() noexcept {
    if (tracker_ != nullptr) {
        tracker_->consumed.store(true, std::memory_order_release);
        tracker_->leased.store(false, std::memory_order_release);
        tracker_.reset();
    }
}

ReadyFrameQueue::ReadyFrameQueue(std::size_t capacity)
    : capacity_(capacity) {
    if (capacity_ == 0) {
        throw std::invalid_argument(
            "ReadyFrameQueue capacity must be greater than zero.");
    }
}

ReadyFrameQueue::~ReadyFrameQueue() = default;

std::size_t ReadyFrameQueue::capacity() const noexcept {
    return capacity_;
}

std::size_t ReadyFrameQueue::size() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return entries_.size();
}

PublishResult ReadyFrameQueue::publish(
    PreparedFrame frame,
    const QueueContext& context) {
    if (frame.validity() != FrameValidity::Ready ||
        !frame.isInternallyConsistent() ||
        frame.orientation() != OrientationState::Normalized) {
        return PublishResult::DroppedInvalid;
    }

    if (!frameMatchesContext(frame, context)) {
        return PublishResult::DroppedStale;
    }

    std::lock_guard<std::mutex> lock(mutex_);
    purgeContextLocked(context);

    if (entries_.size() >= capacity_) {
        auto reclaim = entries_.end();
        for (auto it = entries_.begin(); it != entries_.end(); ++it) {
            if (!(*it)->tracker->leased.load(std::memory_order_acquire)) {
                reclaim = it;
                break;
            }
        }

        if (reclaim == entries_.end()) {
            return PublishResult::DroppedFullLeased;
        }

        entries_.erase(reclaim);
    }

    entries_.push_back(std::make_shared<Entry>(std::move(frame)));
    return PublishResult::Published;
}

AcquireResult ReadyFrameQueue::tryAcquire(
    const QueueContext& context) {
    std::unique_lock<std::mutex> lock(mutex_, std::try_to_lock);
    if (!lock.owns_lock()) {
        return {AcquireResultKind::Contended, std::nullopt};
    }

    const bool wasEmpty = entries_.empty();
    purgeContextLocked(context);

    if (entries_.empty()) {
        return {
            wasEmpty ? AcquireResultKind::Empty
                     : AcquireResultKind::NoEligibleFrame,
            std::nullopt,
        };
    }

    for (const auto& entry : entries_) {
        if (entryIsLogicallyConsumed(entry) ||
            entry->tracker->leased.load(std::memory_order_acquire) ||
            !frameMatchesContext(entry->frame, context)) {
            continue;
        }

        entry->tracker->leased.store(true, std::memory_order_release);
        auto frameLease = entry->frame.acquireLease(
            context.currentMediaGeneration,
            context.currentTimelineEpoch);

        if (!frameLease.has_value()) {
            entry->tracker->leased.store(false,
                                         std::memory_order_release);
            continue;
        }

        AcquireResult result;
        result.kind = AcquireResultKind::Acquired;
        result.lease.emplace(
            std::move(*frameLease),
            entry->tracker);
        return result;
    }

    return {AcquireResultKind::NoEligibleFrame, std::nullopt};
}

std::size_t ReadyFrameQueue::purgeGeneration(
    std::uint64_t currentMediaGeneration) {
    std::lock_guard<std::mutex> lock(mutex_);
    const std::size_t before = entries_.size();

    for (auto it = entries_.begin(); it != entries_.end();) {
        if (entryIsLogicallyConsumed(*it) ||
            (*it)->frame.identity().mediaGeneration !=
                currentMediaGeneration) {
            it = entries_.erase(it);
        } else {
            ++it;
        }
    }

    return before - entries_.size();
}

std::size_t ReadyFrameQueue::purgeEpoch(
    std::uint64_t currentMediaGeneration,
    std::uint64_t currentTimelineEpoch) {
    std::lock_guard<std::mutex> lock(mutex_);
    const std::size_t before = entries_.size();

    for (auto it = entries_.begin(); it != entries_.end();) {
        const FrameIdentity& identity = (*it)->frame.identity();
        if (entryIsLogicallyConsumed(*it) ||
            identity.mediaGeneration != currentMediaGeneration ||
            identity.timelineEpoch != currentTimelineEpoch) {
            it = entries_.erase(it);
        } else {
            ++it;
        }
    }

    return before - entries_.size();
}

std::size_t ReadyFrameQueue::purgeStale(
    const QueueContext& context) {
    std::lock_guard<std::mutex> lock(mutex_);
    return purgeContextLocked(context);
}

bool ReadyFrameQueue::frameMatchesContext(
    const PreparedFrame& frame,
    const QueueContext& context) noexcept {
    if (!frame.isEligible(context.currentMediaGeneration,
                          context.currentTimelineEpoch)) {
        return false;
    }

    if (frame.orientation() != OrientationState::Normalized) {
        return false;
    }

    if (context.minimumSequence.has_value() &&
        frame.identity().sequence < *context.minimumSequence) {
        return false;
    }

    return true;
}

bool ReadyFrameQueue::entryIsLogicallyConsumed(
    const std::shared_ptr<Entry>& entry) noexcept {
    return entry == nullptr ||
           entry->tracker == nullptr ||
           entry->tracker->consumed.load(std::memory_order_acquire);
}

std::size_t ReadyFrameQueue::purgeContextLocked(
    const QueueContext& context) {
    const std::size_t before = entries_.size();

    for (auto it = entries_.begin(); it != entries_.end();) {
        if (entryIsLogicallyConsumed(*it) ||
            !frameMatchesContext((*it)->frame, context)) {
            it = entries_.erase(it);
        } else {
            ++it;
        }
    }

    return before - entries_.size();
}

}  // namespace vcam::frame_engine
