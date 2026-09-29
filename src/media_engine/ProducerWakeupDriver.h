#pragma once

#include "FrameEngineState.h"
#include "FramePipelinePump.h"
#include "ProducerWakeupController.h"

#include <cstdint>
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
