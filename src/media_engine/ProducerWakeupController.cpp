#include "ProducerWakeupController.h"

#include <limits>
#include <new>
#include <utility>

namespace vcam::media_engine {

ProducerWakeupController::ProducerWakeupController(
    PlaybackStateCallback playbackState,
    PumpCallback pump,
    ProducerWakeupSink& wakeupSink,
    ProducerWakeupPolicy policy)
    : playbackState_(std::move(playbackState)),
      pump_(std::move(pump)),
      wakeupSink_(wakeupSink),
      policy_(policy) {}

ProducerWakeupEventResult ProducerWakeupController::start() {
    if (!running_) {
        running_ = true;
        advanceLifecycleToken();
    }

    if (wakeupArmed_) {
        return makeResult(
            ProducerWakeupEventStatus::ArmedInitial);
    }

    if (!playbackState_ ||
        playbackState_() != frame_engine::PlaybackState::Playing) {
        state_ = ProducerWakeupDriverState::Idle;
        return makeResult(
            ProducerWakeupEventStatus::BecameIdle);
    }

    if (!armImmediate()) {
        return stopFatal(std::nullopt);
    }

    return makeResult(
        ProducerWakeupEventStatus::ArmedInitial);
}

ProducerWakeupEventResult ProducerWakeupController::stop() noexcept {
    if (!running_ &&
        state_ == ProducerWakeupDriverState::Stopped) {
        return makeResult(
            ProducerWakeupEventStatus::BecameIdle);
    }

    running_ = false;
    wakeupArmed_ = false;
    advanceLifecycleToken();
    wakeupSink_.disarm();
    state_ = ProducerWakeupDriverState::Stopped;

    return makeResult(
        ProducerWakeupEventStatus::BecameIdle);
}

ProducerWakeupEventResult ProducerWakeupController::handleWakeup(
    std::uint64_t lifecycleToken,
    frame_engine::MonotonicHostTimeNs nowHostTimeNs) {
    if (!running_ ||
        !wakeupArmed_ ||
        lifecycleToken != lifecycleToken_) {
        return makeResult(
            ProducerWakeupEventStatus::IgnoredStaleWakeup);
    }

    wakeupArmed_ = false;

    if (!playbackState_ ||
        playbackState_() != frame_engine::PlaybackState::Playing) {
        state_ = ProducerWakeupDriverState::Idle;
        return makeResult(
            ProducerWakeupEventStatus::BecameIdle);
    }

    FramePipelinePumpResult result;
    try {
        result = pump_(nowHostTimeNs);
    } catch (const std::bad_alloc&) {
        return stopFatal(
            FramePipelinePumpStatus::AllocationFailed);
    }

    const auto currentPlaybackState =
        playbackState_
            ? playbackState_()
            : frame_engine::PlaybackState::Failed;

    switch (result.status) {
        case FramePipelinePumpStatus::WaitingForPresentation: {
            if (!result.dueHostTimeNs.has_value()) {
                return stopFatal(
                    FramePipelinePumpStatus::InvalidTiming);
            }

            if (currentPlaybackState !=
                frame_engine::PlaybackState::Playing) {
                state_ = ProducerWakeupDriverState::Idle;
                return makeResult(
                    ProducerWakeupEventStatus::BecameIdle,
                    result.status);
            }

            const auto dueHostTimeNs = *result.dueHostTimeNs;
            const bool armed =
                dueHostTimeNs <= nowHostTimeNs
                    ? armImmediate()
                    : armAt(dueHostTimeNs);

            if (!armed) {
                return stopFatal(result.status);
            }

            return makeResult(
                ProducerWakeupEventStatus::PumpedAndWaiting,
                result.status,
                dueHostTimeNs);
        }

        case FramePipelinePumpStatus::Published:
        case FramePipelinePumpStatus::DroppedLate:
        case FramePipelinePumpStatus::LoopRestarted:
        case FramePipelinePumpStatus::QueueDropped:
        case FramePipelinePumpStatus::GenerationReset:
        case FramePipelinePumpStatus::EpochReset: {
            if (currentPlaybackState !=
                frame_engine::PlaybackState::Playing) {
                state_ = ProducerWakeupDriverState::Idle;
                return makeResult(
                    ProducerWakeupEventStatus::BecameIdle,
                    result.status);
            }

            if (!armImmediate()) {
                return stopFatal(result.status);
            }

            return makeResult(
                ProducerWakeupEventStatus::PumpedAndRearmed,
                result.status);
        }

        case FramePipelinePumpStatus::NotReady: {
            if (currentPlaybackState !=
                    frame_engine::PlaybackState::Playing ||
                policy_.notReadyRetryNs == 0) {
                state_ = ProducerWakeupDriverState::Idle;
                return makeResult(
                    ProducerWakeupEventStatus::BecameIdle,
                    result.status);
            }

            if (policy_.notReadyRetryNs >
                std::numeric_limits<
                    frame_engine::MonotonicHostTimeNs>::max() -
                    nowHostTimeNs) {
                return stopFatal(
                    FramePipelinePumpStatus::InvalidTiming);
            }

            const auto retryDueHostTimeNs =
                nowHostTimeNs + policy_.notReadyRetryNs;

            if (!armAt(retryDueHostTimeNs)) {
                return stopFatal(result.status);
            }

            return makeResult(
                ProducerWakeupEventStatus::PumpedAndWaiting,
                result.status,
                retryDueHostTimeNs);
        }

        case FramePipelinePumpStatus::EndOfStream: {
            running_ = false;
            wakeupArmed_ = false;
            advanceLifecycleToken();
            wakeupSink_.disarm();
            state_ = ProducerWakeupDriverState::Ended;
            return makeResult(
                ProducerWakeupEventStatus::StoppedEndOfStream,
                result.status);
        }

        case FramePipelinePumpStatus::TransformRequired:
        case FramePipelinePumpStatus::TransformFailed:
        case FramePipelinePumpStatus::ReaderFailed:
        case FramePipelinePumpStatus::Cancelled:
        case FramePipelinePumpStatus::NormalizationRejected:
        case FramePipelinePumpStatus::InvalidTiming:
        case FramePipelinePumpStatus::GenerationMismatch:
        case FramePipelinePumpStatus::TimelineMismatch:
        case FramePipelinePumpStatus::ConcurrentProducerCallRejected:
        case FramePipelinePumpStatus::TimedModeUnavailable:
        case FramePipelinePumpStatus::AllocationFailed:
            return stopFatal(result.status);
    }

    return stopFatal(FramePipelinePumpStatus::ReaderFailed);
}

ProducerWakeupDriverState ProducerWakeupController::state() const noexcept {
    return state_;
}

std::uint64_t ProducerWakeupController::lifecycleToken() const noexcept {
    return lifecycleToken_;
}

bool ProducerWakeupController::wakeupArmed() const noexcept {
    return wakeupArmed_;
}

void ProducerWakeupController::advanceLifecycleToken() noexcept {
    ++lifecycleToken_;
    if (lifecycleToken_ == 0) {
        ++lifecycleToken_;
    }
}

bool ProducerWakeupController::armImmediate() noexcept {
    if (wakeupArmed_) {
        return true;
    }

    if (!wakeupSink_.armImmediate(lifecycleToken_)) {
        return false;
    }

    wakeupArmed_ = true;
    state_ = ProducerWakeupDriverState::Armed;
    return true;
}

bool ProducerWakeupController::armAt(
    frame_engine::MonotonicHostTimeNs dueHostTimeNs) noexcept {
    if (wakeupArmed_) {
        return true;
    }

    if (!wakeupSink_.armAtHostTime(
            dueHostTimeNs,
            lifecycleToken_)) {
        return false;
    }

    wakeupArmed_ = true;
    state_ = ProducerWakeupDriverState::Armed;
    return true;
}

ProducerWakeupEventResult ProducerWakeupController::makeResult(
    ProducerWakeupEventStatus status,
    std::optional<FramePipelinePumpStatus> pumpStatus,
    std::optional<frame_engine::MonotonicHostTimeNs>
        nextDueHostTimeNs) const noexcept {
    ProducerWakeupEventResult result;
    result.status = status;
    result.driverState = state_;
    result.pumpStatus = pumpStatus;
    result.nextDueHostTimeNs = nextDueHostTimeNs;
    result.lifecycleToken = lifecycleToken_;
    return result;
}

ProducerWakeupEventResult ProducerWakeupController::stopFatal(
    std::optional<FramePipelinePumpStatus> pumpStatus) noexcept {
    running_ = false;
    wakeupArmed_ = false;
    advanceLifecycleToken();
    wakeupSink_.disarm();
    state_ = ProducerWakeupDriverState::Failed;

    return makeResult(
        ProducerWakeupEventStatus::StoppedFatal,
        pumpStatus);
}

}  // namespace vcam::media_engine
