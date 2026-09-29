#pragma once

#include "FrameEngineState.h"
#include "FramePipelinePump.h"
#include "ProducerWakeupController.h"

#include <cstdint>
#include <limits>
#include <memory>
#include <optional>

namespace vcam::media_engine {

struct ProducerRuntimeDiagnosticsSnapshot {
    std::uint64_t readFrameCount = 0;
    ReadResultKind lastReadResult =
        ReadResultKind::NotReady;
    frame_engine::ReaderErrorCode lastReaderError =
        frame_engine::ReaderErrorCode::None;
    bool hasLastSourcePTS = false;
    std::int64_t lastSourcePTSValue = 0;
    std::int32_t lastSourcePTSTimescale = 0;
    std::uint64_t normalizeSuccessCount = 0;
    std::uint64_t normalizeFailureCount = 0;
    std::uint64_t transformSuccessCount = 0;
    std::uint64_t transformFailureCount = 0;
    std::uint64_t timelineReadyCount = 0;
    std::uint64_t timelineWaitCount = 0;
    std::uint64_t timelineDropCount = 0;
    std::uint64_t publishCount = 0;
};

inline void AccumulateProducerRuntimeDiagnostics(
    ProducerRuntimeDiagnosticsSnapshot* snapshot,
    const FramePipelinePumpResult& result) noexcept {
    if (snapshot == nullptr) {
        return;
    }

    auto increment =
        [](std::uint64_t* value) noexcept {
            if (value != nullptr &&
                *value !=
                    std::numeric_limits<std::uint64_t>::max()) {
                ++*value;
            }
        };

    snapshot->lastReadResult =
        result.readResult;
    snapshot->lastReaderError =
        result.readerError;

    if (result.readResult ==
        ReadResultKind::Frame) {
        increment(
            &snapshot->readFrameCount);
    }

    if (result.frameTiming.has_value() &&
        CMTIME_IS_NUMERIC(
            result.frameTiming->sourcePTS)) {
        snapshot->hasLastSourcePTS = true;
        snapshot->lastSourcePTSValue =
            result.frameTiming->sourcePTS.value;
        snapshot->lastSourcePTSTimescale =
            result.frameTiming->sourcePTS.timescale;
    }

    if (result.readResult ==
        ReadResultKind::Frame) {
        if (result.normalizationStatus ==
                NormalizationStatus::ReadyPassthrough ||
            result.normalizationStatus ==
                NormalizationStatus::TransformRequired) {
            increment(
                &snapshot->normalizeSuccessCount);
        } else {
            increment(
                &snapshot->normalizeFailureCount);
        }
    }

    if (result.transformStatus ==
        FrameTransformStatus::Transformed) {
        increment(
            &snapshot->transformSuccessCount);
    } else if (
        result.status ==
            FramePipelinePumpStatus::TransformRequired ||
        result.status ==
            FramePipelinePumpStatus::TransformFailed) {
        increment(
            &snapshot->transformFailureCount);
    }

    switch (result.timelineStatus) {
        case frame_engine::
            TimelineScheduleStatus::ReadyNow:
            increment(
                &snapshot->timelineReadyCount);
            break;
        case frame_engine::
            TimelineScheduleStatus::WaitUntilDue:
            increment(
                &snapshot->timelineWaitCount);
            break;
        case frame_engine::
            TimelineScheduleStatus::DropLate:
            increment(
                &snapshot->timelineDropCount);
            break;
        case frame_engine::
            TimelineScheduleStatus::InvalidTiming:
        case frame_engine::
            TimelineScheduleStatus::GenerationMismatch:
        case frame_engine::
            TimelineScheduleStatus::TimelineMismatch:
            break;
    }
}

struct ProducerWakeupDriverConfig {
    // Explicit retry delay used only when the pump reports NotReady while
    // playback remains Playing. Zero means remain idle until an explicit
    // start/kick rather than poll.
    std::uint64_t notReadyRetryNs = 0;

    // Public libdispatch timer leeway for producer wakeups.
    std::uint64_t timerLeewayNs = 0;

    // Static media policy: after one successful publication, stop rearming
    // the producer. Camera callbacks reuse the generation/epoch-bound
    // prepared lease through CameraConsumerAdapter.
    bool singlePublication = false;
};

// Production Stage F2 wrapper.
//
// Owns exactly one serial producer dispatch queue and one reusable timer source.
// The timer callback invokes the F1 timed pump at most once per firing.
class ProducerWakeupDriver final {
public:
    ProducerWakeupDriver(
        frame_engine::FrameEngineState& state,
        FramePipelinePump& pump,
        ProducerWakeupDriverConfig config);

    ~ProducerWakeupDriver();

    ProducerWakeupDriver(const ProducerWakeupDriver&) = delete;
    ProducerWakeupDriver& operator=(const ProducerWakeupDriver&) = delete;
    ProducerWakeupDriver(ProducerWakeupDriver&&) = delete;
    ProducerWakeupDriver& operator=(ProducerWakeupDriver&&) = delete;

    bool valid() const noexcept;

    // Idempotent. If already running and currently idle (for example after a
    // pause), start() acts as an explicit asynchronous producer kick.
    bool start();

    // Idempotent and deterministic. A stale event already queued before stop
    // cannot later invoke the producer.
    void stop();

    ProducerWakeupDriverState state() const;
    std::uint64_t lifecycleToken() const;
    std::optional<FramePipelinePumpStatus> lastPumpStatus() const;
    std::uint64_t publishedFrameCount() const;
    ProducerRuntimeDiagnosticsSnapshot
    runtimeDiagnostics() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace vcam::media_engine
