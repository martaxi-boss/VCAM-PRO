#pragma once

#include "FrameEngineState.h"
#include "FrameNormalizer.h"
#include "FrameTimelineScheduler.h"
#include "FrameTransformer.h"
#include "LocalVideoReader.h"
#include "ReadyFrameQueue.h"

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <optional>

namespace vcam::media_engine {

enum class FramePipelinePumpStatus : std::uint8_t {
    Published = 0,
    TransformRequired,
    TransformFailed,
    QueueDropped,
    EndOfStream,
    LoopRestarted,
    NotReady,
    ReaderFailed,
    Cancelled,
    NormalizationRejected,
    WaitingForPresentation,
    DroppedLate,
    InvalidTiming,
    GenerationMismatch,
    TimelineMismatch,
    GenerationReset,
    EpochReset,
    ConcurrentProducerCallRejected,
    TimedModeUnavailable,
    AllocationFailed,
};

struct FramePipelinePumpResult {
    FramePipelinePumpStatus status = FramePipelinePumpStatus::NotReady;

    ReadResultKind readResult = ReadResultKind::NotReady;
    frame_engine::ReaderErrorCode readerError =
        frame_engine::ReaderErrorCode::None;

    NormalizationStatus normalizationStatus =
        NormalizationStatus::InvalidFrame;
    TransformRequirement transformRequirement =
        TransformRequirement::None;
    FrameTransformStatus transformStatus =
        FrameTransformStatus::TransformFailure;

    frame_engine::TimelineScheduleStatus timelineStatus =
        frame_engine::TimelineScheduleStatus::InvalidTiming;
    std::optional<frame_engine::MonotonicHostTimeNs> dueHostTimeNs;

    frame_engine::PublishResult publishResult =
        frame_engine::PublishResult::DroppedInvalid;

    std::size_t purgedQueueEntries = 0;

    std::optional<frame_engine::FrameIdentity> frameIdentity;
    std::optional<frame_engine::FrameTiming> frameTiming;
};

class FramePipelinePump final {
public:
    FramePipelinePump(
        frame_engine::FrameEngineState& state,
        LocalVideoReader& reader,
        FrameNormalizer& normalizer,
        frame_engine::ReadyFrameQueue& queue,
        const NormalizationTarget& target);

    FramePipelinePump(
        frame_engine::FrameEngineState& state,
        LocalVideoReader& reader,
        FrameNormalizer& normalizer,
        FrameTransformer& transformer,
        frame_engine::ReadyFrameQueue& queue,
        const NormalizationTarget& target)
        : FramePipelinePump(state, reader, normalizer, queue, target) {
        installTransformer(transformer);
    }

    FramePipelinePump(
        frame_engine::FrameEngineState& state,
        LocalVideoReader& reader,
        FrameNormalizer& normalizer,
        FrameTransformer& transformer,
        frame_engine::FrameTimelineScheduler& scheduler,
        frame_engine::ReadyFrameQueue& queue,
        const NormalizationTarget& target)
        : FramePipelinePump(
              state,
              reader,
              normalizer,
              transformer,
              queue,
              target) {
        scheduler_ = &scheduler;
    }

    // Historical A-D2/E1 behavior. This remains immediate producer
    // publication and intentionally performs no Stage F1 pacing.
    FramePipelinePumpResult pumpOnce();

    // Stage F1 serial-producer API. nowHostTimeNs is supplied by the caller
    // in monotonic nanoseconds. This method never sleeps or creates a timer.
    FramePipelinePumpResult pumpOnceAtHostTime(
        frame_engine::MonotonicHostTimeNs nowHostTimeNs);

    const NormalizationTarget& target() const noexcept;

private:
    friend class FramePipelinePumpStageE1TestAccess;
    friend class FramePipelinePumpStageF1TestAccess;

    struct PreparedPipelineResult {
        FramePipelinePumpResult result;
        std::optional<frame_engine::PreparedFrame> frame;
    };

    void installTransformer(FrameTransformer& transformer) {
        transformCallback_ =
            [&transformer](
                const frame_engine::PreparedFrame& source,
                const SourceGeometry& geometry,
                const NormalizationTarget& transformTarget,
                std::uint64_t generation,
                std::uint64_t epoch) {
                return transformer.transform(
                    source,
                    geometry,
                    transformTarget,
                    generation,
                    epoch);
            };
    }

    PreparedPipelineResult prepareFrame(
        frame_engine::PreparedFrame frame,
        const SourceVideoInfo& info,
        std::uint64_t generation,
        std::uint64_t epoch);

    FramePipelinePumpResult processFrame(
        frame_engine::PreparedFrame frame,
        const SourceVideoInfo& info,
        std::uint64_t generation,
        std::uint64_t epoch);

    FramePipelinePumpResult publishTimedFrame(
        frame_engine::PreparedFrame frame,
        frame_engine::MonotonicHostTimeNs nowHostTimeNs,
        const FramePipelinePumpResult& preparedResult);

    FramePipelinePumpResult evaluateTimedPreparedFrame(
        frame_engine::PreparedFrame frame,
        frame_engine::MonotonicHostTimeNs nowHostTimeNs,
        FramePipelinePumpResult preparedResult,
        bool allowPendingStorage);

    FramePipelinePumpResult resetTimedContextIfNeeded();

    frame_engine::FrameEngineState& state_;
    LocalVideoReader& reader_;
    FrameNormalizer& normalizer_;
    frame_engine::ReadyFrameQueue& queue_;
    NormalizationTarget target_;

    using TransformCallback = std::function<
        FrameTransformResult(
            const frame_engine::PreparedFrame&,
            const SourceGeometry&,
            const NormalizationTarget&,
            std::uint64_t,
            std::uint64_t)>;
    using TimedReadCallback = std::function<ReadResult()>;
    using TimedSourceInfoCallback =
        std::function<std::optional<SourceVideoInfo>()>;

    TransformCallback transformCallback_;
    TimedReadCallback timedReadCallback_;
    TimedSourceInfoCallback timedSourceInfoCallback_;

    frame_engine::FrameTimelineScheduler* scheduler_ = nullptr;
    std::optional<frame_engine::PreparedFrame> pendingTimedFrame_;
    FramePipelinePumpResult pendingPreparedResult_{};

    bool timedContextInitialized_ = false;
    std::uint64_t timedMediaGeneration_ = 0;
    std::uint64_t timedTimelineEpoch_ = 0;

    // Fail-fast re-entry detector only. It deliberately does not serialize
    // producer mutations or advertise concurrent producer support.
    std::atomic_flag timedProducerActive_ = ATOMIC_FLAG_INIT;
};

}  // namespace vcam::media_engine
