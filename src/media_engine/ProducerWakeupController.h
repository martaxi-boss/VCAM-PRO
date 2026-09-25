#pragma once

#include "FrameEngineState.h"
#include "FramePipelinePump.h"

#include <cstdint>
#include <functional>
#include <optional>

namespace vcam::media_engine {

enum class ProducerWakeupDriverState : std::uint8_t {
    Stopped = 0,
    Armed,
    Idle,
    Failed,
    Ended,
};

enum class ProducerWakeupEventStatus : std::uint8_t {
    ArmedInitial = 0,
    PumpedAndRearmed,
    PumpedAndWaiting,
    BecameIdle,
    StoppedFatal,
    StoppedEndOfStream,
    IgnoredStaleWakeup,
    ArmFailure,
};

struct ProducerWakeupPolicy {
    // Explicit retry policy for a legitimate Playing + NotReady result.
    // A value of zero means become idle rather than poll.
    std::uint64_t notReadyRetryNs = 0;
};

struct ProducerWakeupEventResult {
    ProducerWakeupEventStatus status =
        ProducerWakeupEventStatus::BecameIdle;
    ProducerWakeupDriverState driverState =
        ProducerWakeupDriverState::Stopped;
    std::optional<FramePipelinePumpStatus> pumpStatus;
    std::optional<frame_engine::MonotonicHostTimeNs> nextDueHostTimeNs;
    std::uint64_t lifecycleToken = 0;
};

class ProducerWakeupSink {
public:
    virtual ~ProducerWakeupSink() = default;

    // These methods schedule a future asynchronous producer turn. They must
    // not synchronously call ProducerWakeupController::handleWakeup().
    virtual bool armImmediate(std::uint64_t lifecycleToken) noexcept = 0;

    virtual bool armAtHostTime(
        frame_engine::MonotonicHostTimeNs dueHostTimeNs,
        std::uint64_t lifecycleToken) noexcept = 0;

    virtual void disarm() noexcept = 0;
};

// Serial producer state machine used by the production libdispatch driver.
//
// All methods belong to one producer execution domain. This class contains no
// mutex and does not claim concurrent mutation support. The production wrapper
// enforces serial execution; deterministic tests provide a fake wakeup sink.
class ProducerWakeupController final {
public:
    using PlaybackStateCallback =
        std::function<frame_engine::PlaybackState()>;
    using PumpCallback = std::function<
        FramePipelinePumpResult(frame_engine::MonotonicHostTimeNs)>;

    ProducerWakeupController(
        PlaybackStateCallback playbackState,
        PumpCallback pump,
        ProducerWakeupSink& wakeupSink,
        ProducerWakeupPolicy policy);

    ProducerWakeupController(const ProducerWakeupController&) = delete;
    ProducerWakeupController& operator=(
        const ProducerWakeupController&) = delete;

    ProducerWakeupEventResult start();
    ProducerWakeupEventResult stop() noexcept;

    ProducerWakeupEventResult handleWakeup(
        std::uint64_t lifecycleToken,
        frame_engine::MonotonicHostTimeNs nowHostTimeNs);

    ProducerWakeupDriverState state() const noexcept;
    std::uint64_t lifecycleToken() const noexcept;
    bool wakeupArmed() const noexcept;

private:
    void advanceLifecycleToken() noexcept;

    bool armImmediate() noexcept;

    bool armAt(
        frame_engine::MonotonicHostTimeNs dueHostTimeNs) noexcept;

    ProducerWakeupEventResult makeResult(
        ProducerWakeupEventStatus status,
        std::optional<FramePipelinePumpStatus> pumpStatus =
            std::nullopt,
        std::optional<frame_engine::MonotonicHostTimeNs>
            nextDueHostTimeNs = std::nullopt) const noexcept;

    ProducerWakeupEventResult stopFatal(
        std::optional<FramePipelinePumpStatus> pumpStatus) noexcept;

    PlaybackStateCallback playbackState_;
    PumpCallback pump_;
    ProducerWakeupSink& wakeupSink_;
    ProducerWakeupPolicy policy_{};

    ProducerWakeupDriverState state_ =
        ProducerWakeupDriverState::Stopped;
    std::uint64_t lifecycleToken_ = 0;
    bool running_ = false;
    bool wakeupArmed_ = false;
};

}  // namespace vcam::media_engine
