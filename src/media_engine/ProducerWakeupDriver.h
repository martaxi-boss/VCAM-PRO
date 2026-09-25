#pragma once

#include "FrameEngineState.h"
#include "FramePipelinePump.h"
#include "ProducerWakeupController.h"

#include <cstdint>
#include <memory>

namespace vcam::media_engine {

struct ProducerWakeupDriverConfig {
    // Explicit retry delay used only when the pump reports NotReady while
    // playback remains Playing. Zero means remain idle until an explicit
    // start/kick rather than poll.
    std::uint64_t notReadyRetryNs = 0;

    // Public libdispatch timer leeway for producer wakeups.
    std::uint64_t timerLeewayNs = 0;
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

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace vcam::media_engine
