#include "FramePipelinePump.h"

#include <new>
#include <utility>

namespace vcam::media_engine {

namespace {

FramePipelinePumpResult MakeTimedReaderResult(
    FramePipelinePumpStatus status,
    const ReadResult& read) {
    FramePipelinePumpResult result;
    result.status = status;
    result.readResult = read.kind;
    result.readerError = read.error;
    return result;
}

class ProducerCallGuard final {
public:
    explicit ProducerCallGuard(std::atomic_flag& flag) noexcept
        : flag_(flag) {}

    ProducerCallGuard(const ProducerCallGuard&) = delete;
    ProducerCallGuard& operator=(const ProducerCallGuard&) = delete;

    ~ProducerCallGuard() {
        flag_.clear(std::memory_order_release);
    }

private:
    std::atomic_flag& flag_;
};

}  // namespace

FramePipelinePumpResult FramePipelinePump::pumpOnceAtHostTime(
    frame_engine::MonotonicHostTimeNs nowHostTimeNs) {
    if (scheduler_ == nullptr) {
        FramePipelinePumpResult result;
        result.status = FramePipelinePumpStatus::TimedModeUnavailable;
        return result;
    }

    if (timedProducerActive_.test_and_set(std::memory_order_acquire)) {
        FramePipelinePumpResult result;
        result.status =
            FramePipelinePumpStatus::ConcurrentProducerCallRejected;
        return result;
    }
    ProducerCallGuard guard(timedProducerActive_);

    FramePipelinePumpResult resetResult =
        resetTimedContextIfNeeded();
    if (resetResult.status == FramePipelinePumpStatus::GenerationReset ||
        resetResult.status == FramePipelinePumpStatus::EpochReset) {
        return resetResult;
    }

    if (pendingTimedFrame_.has_value()) {
        frame_engine::PreparedFrame pending =
            std::move(*pendingTimedFrame_);
        pendingTimedFrame_.reset();

        FramePipelinePumpResult preparedResult =
            pendingPreparedResult_;
        pendingPreparedResult_ = {};

        return evaluateTimedPreparedFrame(
            std::move(pending),
            nowHostTimeNs,
            std::move(preparedResult),
            true);
    }

    ReadResult read =
        timedReadCallback_
            ? timedReadCallback_()
            : reader_.readNext();

    switch (read.kind) {
        case ReadResultKind::EndOfStream:
            return MakeTimedReaderResult(
                FramePipelinePumpStatus::EndOfStream,
                read);
        case ReadResultKind::LoopRestarted:
            return MakeTimedReaderResult(
                FramePipelinePumpStatus::LoopRestarted,
                read);
        case ReadResultKind::NotReady:
            return MakeTimedReaderResult(
                FramePipelinePumpStatus::NotReady,
                read);
        case ReadResultKind::Failed:
            return MakeTimedReaderResult(
                FramePipelinePumpStatus::ReaderFailed,
                read);
        case ReadResultKind::Cancelled:
            return MakeTimedReaderResult(
                FramePipelinePumpStatus::Cancelled,
                read);
        case ReadResultKind::Frame:
            break;
    }

    FramePipelinePumpResult result;
    result.readResult = read.kind;
    result.readerError = read.error;

    if (!read.frame.has_value()) {
        result.status = FramePipelinePumpStatus::ReaderFailed;
        result.readerError = frame_engine::ReaderErrorCode::Unknown;
        return result;
    }

    const std::optional<SourceVideoInfo> info =
        timedSourceInfoCallback_
            ? timedSourceInfoCallback_()
            : reader_.sourceInfo();
    if (!info.has_value()) {
        result.status = FramePipelinePumpStatus::NormalizationRejected;
        result.normalizationStatus = NormalizationStatus::UnsupportedTarget;
        return result;
    }

    PreparedPipelineResult prepared = prepareFrame(
        std::move(*read.frame),
        *info,
        state_.mediaGeneration(),
        state_.timelineEpoch());

    if (!prepared.frame.has_value()) {
        return prepared.result;
    }

    return evaluateTimedPreparedFrame(
        std::move(*prepared.frame),
        nowHostTimeNs,
        std::move(prepared.result),
        true);
}

FramePipelinePumpResult FramePipelinePump::evaluateTimedPreparedFrame(
    frame_engine::PreparedFrame frame,
    frame_engine::MonotonicHostTimeNs nowHostTimeNs,
    FramePipelinePumpResult preparedResult,
    bool allowPendingStorage) {
    const frame_engine::TimelineScheduleResult schedule =
        scheduler_->evaluate(
            frame,
            state_.mediaGeneration(),
            state_.timelineEpoch(),
            nowHostTimeNs);

    preparedResult.timelineStatus = schedule.status;
    preparedResult.dueHostTimeNs = schedule.dueHostTimeNs;
    preparedResult.frameIdentity = frame.identity();
    preparedResult.frameTiming = frame.timing();

    switch (schedule.status) {
        case frame_engine::TimelineScheduleStatus::ReadyNow:
            return publishTimedFrame(
                std::move(frame),
                nowHostTimeNs,
                preparedResult);

        case frame_engine::TimelineScheduleStatus::WaitUntilDue:
            if (allowPendingStorage) {
                try {
                    pendingTimedFrame_.emplace(std::move(frame));
                    pendingPreparedResult_ = preparedResult;
                } catch (const std::bad_alloc&) {
                    pendingTimedFrame_.reset();
                    pendingPreparedResult_ = {};
                    preparedResult.status =
                        FramePipelinePumpStatus::AllocationFailed;
                    return preparedResult;
                }
            }
            preparedResult.status =
                FramePipelinePumpStatus::WaitingForPresentation;
            return preparedResult;

        case frame_engine::TimelineScheduleStatus::DropLate:
            preparedResult.status = FramePipelinePumpStatus::DroppedLate;
            return preparedResult;

        case frame_engine::TimelineScheduleStatus::GenerationMismatch:
            preparedResult.status =
                FramePipelinePumpStatus::GenerationMismatch;
            return preparedResult;

        case frame_engine::TimelineScheduleStatus::TimelineMismatch:
            preparedResult.status =
                FramePipelinePumpStatus::TimelineMismatch;
            return preparedResult;

        case frame_engine::TimelineScheduleStatus::InvalidTiming:
            preparedResult.status = FramePipelinePumpStatus::InvalidTiming;
            return preparedResult;
    }

    preparedResult.status = FramePipelinePumpStatus::InvalidTiming;
    return preparedResult;
}

FramePipelinePumpResult FramePipelinePump::publishTimedFrame(
    frame_engine::PreparedFrame frame,
    frame_engine::MonotonicHostTimeNs nowHostTimeNs,
    const FramePipelinePumpResult& preparedResult) {
    FramePipelinePumpResult result = preparedResult;

    try {
        frame_engine::FrameTiming stampedTiming = frame.timing();
        stampedTiming.producedAtHostTime = nowHostTimeNs;

        frame_engine::PreparedFrame stamped(
            frame.pixelBuffer(),
            frame.identity(),
            stampedTiming,
            frame.orientation(),
            frame.validity(),
            frame.colorPrimaries(),
            frame.transferFunction(),
            frame.yCbCrMatrix(),
            frame.attachments());

        if (!stamped.isInternallyConsistent() ||
            stamped.validity() != frame_engine::FrameValidity::Ready) {
            result.status = FramePipelinePumpStatus::NormalizationRejected;
            return result;
        }

        result.frameIdentity = stamped.identity();
        result.frameTiming = stamped.timing();

        frame_engine::QueueContext queueContext;
        queueContext.currentMediaGeneration = state_.mediaGeneration();
        queueContext.currentTimelineEpoch = state_.timelineEpoch();
        queueContext.minimumSequence = stamped.identity().sequence;

        result.purgedQueueEntries = queue_.purgeStale(queueContext);
        result.publishResult =
            queue_.publish(std::move(stamped), queueContext);

        result.status =
            result.publishResult == frame_engine::PublishResult::Published
                ? FramePipelinePumpStatus::Published
                : FramePipelinePumpStatus::QueueDropped;
        return result;
    } catch (const std::bad_alloc&) {
        result.status = FramePipelinePumpStatus::AllocationFailed;
        return result;
    }
}

FramePipelinePumpResult FramePipelinePump::resetTimedContextIfNeeded() {
    FramePipelinePumpResult result;

    const std::uint64_t generation = state_.mediaGeneration();
    const std::uint64_t epoch = state_.timelineEpoch();

    if (!timedContextInitialized_) {
        timedContextInitialized_ = true;
        timedMediaGeneration_ = generation;
        timedTimelineEpoch_ = epoch;
        scheduler_->reset();
        return result;
    }

    if (generation != timedMediaGeneration_) {
        pendingTimedFrame_.reset();
        pendingPreparedResult_ = {};
        scheduler_->reset();

        timedMediaGeneration_ = generation;
        timedTimelineEpoch_ = epoch;

        result.purgedQueueEntries =
            queue_.purgeGeneration(generation);
        result.status = FramePipelinePumpStatus::GenerationReset;
        return result;
    }

    if (epoch != timedTimelineEpoch_) {
        pendingTimedFrame_.reset();
        pendingPreparedResult_ = {};
        scheduler_->reset();

        timedTimelineEpoch_ = epoch;

        result.purgedQueueEntries =
            queue_.purgeEpoch(generation, epoch);
        result.status = FramePipelinePumpStatus::EpochReset;
        return result;
    }

    return result;
}

}  // namespace vcam::media_engine
