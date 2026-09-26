#include "ControlledFrameConsumer.h"

#include <limits>
#include <utility>

namespace vcam::controlled {

struct ControlledFrameLifetimeTracker {
    std::atomic<std::size_t> outstanding{0};
};

ControlledPresentedFrame::ControlledPresentedFrame(
    CVPixelBufferRef pixelBuffer,
    const frame_engine::FrameIdentity& identity,
    std::shared_ptr<
        ControlledFrameLifetimeTracker> tracker)
    : pixelBuffer_(
          pixelBuffer == nullptr
              ? nullptr
              : CVPixelBufferRetain(pixelBuffer)),
      identity_(identity),
      tracker_(std::move(tracker)) {
    if (pixelBuffer_ != nullptr &&
        tracker_ != nullptr) {
        tracker_->outstanding.fetch_add(
            1,
            std::memory_order_acq_rel);
    }
}

ControlledPresentedFrame::ControlledPresentedFrame(
    ControlledPresentedFrame&& other) noexcept
    : pixelBuffer_(other.pixelBuffer_),
      identity_(other.identity_),
      tracker_(std::move(other.tracker_)) {
    other.pixelBuffer_ = nullptr;
    other.identity_ = {};
}

ControlledPresentedFrame&
ControlledPresentedFrame::operator=(
    ControlledPresentedFrame&& other) noexcept {
    if (this != &other) {
        release();

        pixelBuffer_ = other.pixelBuffer_;
        identity_ = other.identity_;
        tracker_ = std::move(other.tracker_);

        other.pixelBuffer_ = nullptr;
        other.identity_ = {};
    }
    return *this;
}

ControlledPresentedFrame::
~ControlledPresentedFrame() {
    release();
}

bool ControlledPresentedFrame::valid() const noexcept {
    return pixelBuffer_ != nullptr &&
           CVPixelBufferGetWidth(pixelBuffer_) > 0 &&
           CVPixelBufferGetHeight(pixelBuffer_) > 0;
}

CVPixelBufferRef
ControlledPresentedFrame::pixelBuffer() const noexcept {
    return pixelBuffer_;
}

const frame_engine::FrameIdentity&
ControlledPresentedFrame::identity() const noexcept {
    return identity_;
}

void ControlledPresentedFrame::release() noexcept {
    if (pixelBuffer_ != nullptr) {
        CVPixelBufferRelease(pixelBuffer_);
        pixelBuffer_ = nullptr;

        if (tracker_ != nullptr) {
            tracker_->outstanding.fetch_sub(
                1,
                std::memory_order_acq_rel);
        }
    }

    tracker_.reset();
    identity_ = {};
}

ControlledFrameConsumer::ControlledFrameConsumer()
    : tracker_(
          std::make_shared<
              ControlledFrameLifetimeTracker>()) {}

void ControlledFrameConsumer::bind(
    frame_engine::ReadyFrameQueue* queue,
    frame_engine::FrameEngineState* state) noexcept {
    queue_ = queue;
    state_ = state;
    lastGeneration_ = 0;
    lastEpoch_ = 0;
    lastSequence_.reset();
}

void ControlledFrameConsumer::unbind() noexcept {
    queue_ = nullptr;
    state_ = nullptr;
    lastGeneration_ = 0;
    lastEpoch_ = 0;
    lastSequence_.reset();
}

void ControlledFrameConsumer::setEnabled(
    bool enabled) noexcept {
    enabled_.store(
        enabled,
        std::memory_order_release);
}

bool ControlledFrameConsumer::enabled() const noexcept {
    return enabled_.load(
        std::memory_order_acquire);
}

ControlledAcquireResult
ControlledFrameConsumer::tryAcquire() noexcept {
    if (!enabled()) {
        return {
            ControlledAcquireKind::Disabled,
            std::nullopt,
        };
    }

    if (queue_ == nullptr ||
        state_ == nullptr) {
        return {
            ControlledAcquireKind::Unbound,
            std::nullopt,
        };
    }

    if (tracker_ != nullptr &&
        tracker_->outstanding.load(
            std::memory_order_acquire) != 0) {
        return {
            ControlledAcquireKind::LeaseBusy,
            std::nullopt,
        };
    }

    if (state_->playbackState() !=
        frame_engine::PlaybackState::Playing) {
        return {
            ControlledAcquireKind::Inactive,
            std::nullopt,
        };
    }

    const std::uint64_t generation =
        state_->mediaGeneration();
    const std::uint64_t epoch =
        state_->timelineEpoch();

    if (generation != lastGeneration_ ||
        epoch != lastEpoch_) {
        lastGeneration_ = generation;
        lastEpoch_ = epoch;
        lastSequence_.reset();
    }

    frame_engine::QueueContext context;
    context.currentMediaGeneration =
        generation;
    context.currentTimelineEpoch =
        epoch;

    if (lastSequence_.has_value() &&
        *lastSequence_ !=
            std::numeric_limits<
                std::uint64_t>::max()) {
        context.minimumSequence =
            *lastSequence_ + 1;
    }

    auto acquired =
        queue_->tryAcquire(context);

    switch (acquired.kind) {
        case frame_engine::
            AcquireResultKind::Empty:
            return {
                ControlledAcquireKind::Empty,
                std::nullopt,
            };

        case frame_engine::
            AcquireResultKind::NoEligibleFrame:
            return {
                ControlledAcquireKind::NoEligibleFrame,
                std::nullopt,
            };

        case frame_engine::
            AcquireResultKind::Contended:
            return {
                ControlledAcquireKind::Contended,
                std::nullopt,
            };

        case frame_engine::
            AcquireResultKind::Acquired:
            break;
    }

    if (!acquired.lease.has_value() ||
        !acquired.lease->valid()) {
        return {
            ControlledAcquireKind::NoEligibleFrame,
            std::nullopt,
        };
    }

    const frame_engine::FrameLease*
        frameLease =
            acquired.lease->frameLease();

    if (frameLease == nullptr ||
        !frameLease->isValid() ||
        frameLease->pixelBuffer() == nullptr) {
        return {
            ControlledAcquireKind::NoEligibleFrame,
            std::nullopt,
        };
    }

    lastSequence_ =
        frameLease->identity().sequence;

    ControlledAcquireResult result;
    result.kind =
        ControlledAcquireKind::Presented;
    result.frame.emplace(
        frameLease->pixelBuffer(),
        frameLease->identity(),
        tracker_);
    return result;
}

std::size_t
ControlledFrameConsumer::
outstandingFrameCount() const noexcept {
    return tracker_ == nullptr
        ? 0
        : tracker_->outstanding.load(
              std::memory_order_acquire);
}

}  // namespace vcam::controlled
