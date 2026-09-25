#include "FramePipelinePump.h"

#include <new>
#include <utility>

namespace vcam::media_engine {

namespace {

FramePipelinePumpResult MakeReaderResult(
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

FramePipelinePump::FramePipelinePump(
    frame_engine::FrameEngineState& state,
    LocalVideoReader& reader,
    FrameNormalizer& normalizer,
    frame_engine::ReadyFrameQueue& queue,
    const NormalizationTarget& target)
    : state_(state),
      reader_(reader),
      normalizer_(normalizer),
      queue_(queue),
      target_(target) {}

FramePipelinePumpResult FramePipelinePump::pumpOnce() {
    // Producer-side only. A future camera/injector callback must never call
    // this method because readNext() may perform AVAssetReader file I/O and
    // decode work. The future consumer fast path is ReadyFrameQueue::tryAcquire.
    ReadResult read = reader_.readNext();

    switch (read.kind) {
        case ReadResultKind::EndOfStream:
            return MakeReaderResult(
                FramePipelinePumpStatus::EndOfStream,
                read);
        case ReadResultKind::LoopRestarted:
            return MakeReaderResult(
                FramePipelinePumpStatus::LoopRestarted,
                read);
        case ReadResultKind::NotReady:
            return MakeReaderResult(
                FramePipelinePumpStatus::NotReady,
                read);
        case ReadResultKind::Failed:
            return MakeReaderResult(
                FramePipelinePumpStatus::ReaderFailed,
                read);
        case ReadResultKind::Cancelled:
            return MakeReaderResult(
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

    const std::optional<SourceVideoInfo> info = reader_.sourceInfo();
    if (!info.has_value()) {
        result.status = FramePipelinePumpStatus::NormalizationRejected;
        result.normalizationStatus = NormalizationStatus::UnsupportedTarget;
        return result;
    }

    return processFrame(
        std::move(*read.frame),
        *info,
        state_.mediaGeneration(),
        state_.timelineEpoch());
}

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

    ReadResult read = reader_.readNext();

    switch (read.kind) {
        case ReadResultKind::EndOfStream:
            return MakeReaderResult(
                FramePipelinePumpStatus::EndOfStream,
                read);
        case ReadResultKind::LoopRestarted:
            return MakeReaderResult(
                FramePipelinePumpStatus::LoopRestarted,
                read);
        case ReadResultKind::NotReady:
            return MakeReaderResult(
                FramePipelinePumpStatus::NotReady,
                read);
        case ReadResultKind::Failed:
            return MakeReaderResult(
                FramePipelinePumpStatus::ReaderFailed,
                read);
        case ReadResultKind::Cancelled:
            return MakeReaderResult(
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

    const std::optional<SourceVideoInfo> info = reader_.sourceInfo();
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

FramePipelinePump::PreparedPipelineResult
FramePipelinePump::prepareFrame(
    frame_engine::PreparedFrame frame,
    const SourceVideoInfo& info,
    std::uint64_t generation,
    std::uint64_t epoch) {
    PreparedPipelineResult prepared;
    prepared.result.readResult = ReadResultKind::Frame;

    try {
        SourceGeometry geometry;
        geometry.naturalSize = info.naturalSize;
        geometry.preferredTransform = info.preferredTransform;

        NormalizationResult normalized = normalizer_.prepare(
            frame,
            geometry,
            target_,
            generation,
            epoch);

        prepared.result.normalizationStatus = normalized.status;
        prepared.result.transformRequirement = normalized.requirement;

        if (normalized.status == NormalizationStatus::TransformRequired) {
            if (!transformCallback_) {
                // Stage D1/D2 compatibility path. Historical constructors
                // intentionally stop before transform work.
                prepared.result.status =
                    FramePipelinePumpStatus::TransformRequired;
                return prepared;
            }

            FrameTransformResult transformed = transformCallback_(
                frame,
                geometry,
                target_,
                generation,
                epoch);
            prepared.result.transformStatus = transformed.status;

            if (transformed.status != FrameTransformStatus::Transformed ||
                !transformed.frame.has_value()) {
                prepared.result.status =
                    FramePipelinePumpStatus::TransformFailed;
                return prepared;
            }

            const frame_engine::PreparedFrame& validated =
                *transformed.frame;

            const bool exactTarget =
                validated.validity() ==
                    frame_engine::FrameValidity::Ready &&
                validated.isInternallyConsistent() &&
                validated.identity().mediaGeneration == generation &&
                validated.identity().timelineEpoch == epoch &&
                validated.width() == target_.width &&
                validated.height() == target_.height &&
                validated.pixelFormat() == target_.pixelFormat &&
                validated.orientation() ==
                    frame_engine::OrientationState::Normalized;

            if (!exactTarget) {
                prepared.result.status =
                    FramePipelinePumpStatus::TransformFailed;
                return prepared;
            }

            prepared.result.normalizationStatus =
                NormalizationStatus::ReadyPassthrough;
            normalized.status = NormalizationStatus::ReadyPassthrough;
            normalized.requirement = TransformRequirement::None;
            normalized.frame.emplace(std::move(*transformed.frame));
        }

        if (normalized.status != NormalizationStatus::ReadyPassthrough ||
            !normalized.frame.has_value()) {
            prepared.result.status =
                FramePipelinePumpStatus::NormalizationRejected;
            return prepared;
        }

        prepared.result.frameIdentity = normalized.frame->identity();
        prepared.result.frameTiming = normalized.frame->timing();
        prepared.frame.emplace(std::move(*normalized.frame));
        return prepared;
    } catch (const std::bad_alloc&) {
        prepared.result.status =
            FramePipelinePumpStatus::AllocationFailed;
        prepared.frame.reset();
        return prepared;
    }
}

FramePipelinePumpResult FramePipelinePump::processFrame(
    frame_engine::PreparedFrame frame,
    const SourceVideoInfo& info,
    std::uint64_t generation,
    std::uint64_t epoch) {
    PreparedPipelineResult prepared = prepareFrame(
        std::move(frame),
        info,
        generation,
        epoch);

    if (!prepared.frame.has_value()) {
        return prepared.result;
    }

    frame_engine::QueueContext queueContext;
    queueContext.currentMediaGeneration = generation;
    queueContext.currentTimelineEpoch = epoch;
    queueContext.minimumSequence = std::nullopt;

    prepared.result.publishResult =
        queue_.publish(std::move(*prepared.frame), queueContext);

    if (prepared.result.publishResult ==
        frame_engine::PublishResult::Published) {
        prepared.result.status = FramePipelinePumpStatus::Published;
    } else {
        prepared.result.status = FramePipelinePumpStatus::QueueDropped;
    }

    return prepared.result;
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

const NormalizationTarget& FramePipelinePump::target() const noexcept {
    return target_;
}

}  // namespace vcam::media_engine
