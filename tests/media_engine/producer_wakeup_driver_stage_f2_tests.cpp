#include "ProducerWakeupController.h"

#include <cstdint>
#include <cstdlib>
#include <functional>
#include <iostream>
#include <optional>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {

using namespace vcam::frame_engine;
using namespace vcam::media_engine;

int gTestsRun = 0;
int gFailures = 0;

#define CHECK(condition)                                                        \
    do {                                                                        \
        if (!(condition)) {                                                     \
            std::cerr << "CHECK failed at " << __FILE__ << ":" << __LINE__    \
                      << ": " #condition << std::endl;                          \
            return false;                                                       \
        }                                                                       \
    } while (false)

FramePipelinePumpResult PumpResult(
    FramePipelinePumpStatus status,
    std::optional<MonotonicHostTimeNs> due = std::nullopt) {
    FramePipelinePumpResult result;
    result.status = status;
    result.dueHostTimeNs = due;
    return result;
}

class FakeWakeupSink final : public ProducerWakeupSink {
public:
    enum class Kind : std::uint8_t {
        None = 0,
        Immediate,
        Deadline,
    };

    bool armImmediate(
        std::uint64_t lifecycleToken) noexcept override {
        ++armCalls;
        if (failNextArm) {
            failNextArm = false;
            return false;
        }

        if (active) {
            ++duplicateArmAttempts;
            return false;
        }

        active = true;
        kind = Kind::Immediate;
        token = lifecycleToken;
        dueHostTimeNs.reset();
        return true;
    }

    bool armAtHostTime(
        MonotonicHostTimeNs due,
        std::uint64_t lifecycleToken) noexcept override {
        ++armCalls;
        if (failNextArm) {
            failNextArm = false;
            return false;
        }

        if (active) {
            ++duplicateArmAttempts;
            return false;
        }

        active = true;
        kind = Kind::Deadline;
        token = lifecycleToken;
        dueHostTimeNs = due;
        return true;
    }

    void disarm() noexcept override {
        ++disarmCalls;
        active = false;
        kind = Kind::None;
        token = 0;
        dueHostTimeNs.reset();
    }

    std::optional<ProducerWakeupEventResult> fireIfDue(
        ProducerWakeupController& controller,
        MonotonicHostTimeNs nowHostTimeNs) {
        if (!active) {
            return std::nullopt;
        }

        if (kind == Kind::Deadline &&
            dueHostTimeNs.has_value() &&
            nowHostTimeNs < *dueHostTimeNs) {
            return std::nullopt;
        }

        const std::uint64_t firingToken = token;
        active = false;
        kind = Kind::None;
        token = 0;
        dueHostTimeNs.reset();

        return controller.handleWakeup(
            firingToken,
            nowHostTimeNs);
    }

    bool active = false;
    bool failNextArm = false;
    Kind kind = Kind::None;
    std::uint64_t token = 0;
    std::optional<MonotonicHostTimeNs> dueHostTimeNs;
    int armCalls = 0;
    int disarmCalls = 0;
    int duplicateArmAttempts = 0;
};

class PumpScript final {
public:
    explicit PumpScript(
        std::vector<FramePipelinePumpResult> results)
        : results_(std::move(results)) {}

    FramePipelinePumpResult pump(
        MonotonicHostTimeNs nowHostTimeNs) {
        ++calls;
        observedTimes.push_back(nowHostTimeNs);

        if (results_.empty()) {
            return PumpResult(FramePipelinePumpStatus::NotReady);
        }

        const std::size_t index =
            static_cast<std::size_t>(calls - 1);

        if (index >= results_.size()) {
            return results_.back();
        }

        return results_[index];
    }

    int calls = 0;
    std::vector<MonotonicHostTimeNs> observedTimes;

private:
    std::vector<FramePipelinePumpResult> results_;
};

ProducerWakeupController MakeController(
    PlaybackState& playbackState,
    PumpScript& pump,
    FakeWakeupSink& sink,
    std::uint64_t notReadyRetryNs = 0) {
    ProducerWakeupPolicy policy;
    policy.notReadyRetryNs = notReadyRetryNs;

    return ProducerWakeupController(
        [&playbackState]() {
            return playbackState;
        },
        [&pump](MonotonicHostTimeNs nowHostTimeNs) {
            return pump.pump(nowHostTimeNs);
        },
        sink,
        policy);
}

bool TestInitialProducerWakeup() {
    PlaybackState playbackState = PlaybackState::Playing;
    PumpScript pump({PumpResult(FramePipelinePumpStatus::EndOfStream)});
    FakeWakeupSink sink;
    auto controller =
        MakeController(playbackState, pump, sink);

    const auto start = controller.start();

    CHECK(start.status ==
          ProducerWakeupEventStatus::ArmedInitial);
    CHECK(controller.state() == ProducerWakeupDriverState::Armed);
    CHECK(sink.active);
    CHECK(sink.kind == FakeWakeupSink::Kind::Immediate);
    CHECK(pump.calls == 0);
    CHECK(sink.armCalls == 1);
    return true;
}

bool TestExactWaitDeadlineAndNoEarlyFire() {
    PlaybackState playbackState = PlaybackState::Playing;
    constexpr MonotonicHostTimeNs due = 1'500'000ULL;

    PumpScript pump({
        PumpResult(
            FramePipelinePumpStatus::WaitingForPresentation,
            due),
        PumpResult(FramePipelinePumpStatus::EndOfStream),
    });
    FakeWakeupSink sink;
    auto controller =
        MakeController(playbackState, pump, sink);

    controller.start();

    const auto firstFire = sink.fireIfDue(controller, 1'000'000ULL);
    CHECK(firstFire.has_value());
    CHECK(pump.calls == 1);
    CHECK(firstFire->status ==
          ProducerWakeupEventStatus::PumpedAndWaiting);
    CHECK(firstFire->nextDueHostTimeNs == due);
    CHECK(sink.kind == FakeWakeupSink::Kind::Deadline);
    CHECK(sink.dueHostTimeNs == due);

    const auto early = sink.fireIfDue(controller, due - 1);
    CHECK(!early.has_value());
    CHECK(pump.calls == 1);

    const auto dueFire = sink.fireIfDue(controller, due);
    CHECK(dueFire.has_value());
    CHECK(pump.calls == 2);
    CHECK(pump.observedTimes[1] == due);
    return true;
}

bool TestOnePumpPerFiring() {
    PlaybackState playbackState = PlaybackState::Playing;
    PumpScript pump({
        PumpResult(FramePipelinePumpStatus::Published),
        PumpResult(FramePipelinePumpStatus::Published),
        PumpResult(FramePipelinePumpStatus::EndOfStream),
    });
    FakeWakeupSink sink;
    auto controller =
        MakeController(playbackState, pump, sink);

    controller.start();

    const auto first = sink.fireIfDue(controller, 10);
    CHECK(first.has_value());
    CHECK(first->status ==
          ProducerWakeupEventStatus::PumpedAndRearmed);
    CHECK(pump.calls == 1);
    CHECK(sink.active);
    CHECK(sink.kind == FakeWakeupSink::Kind::Immediate);

    CHECK(pump.calls == 1);

    const auto second = sink.fireIfDue(controller, 11);
    CHECK(second.has_value());
    CHECK(pump.calls == 2);
    return true;
}

bool TestPublishedContinuationIsAsynchronous() {
    PlaybackState playbackState = PlaybackState::Playing;
    PumpScript pump({
        PumpResult(FramePipelinePumpStatus::Published),
        PumpResult(FramePipelinePumpStatus::EndOfStream),
    });
    FakeWakeupSink sink;
    auto controller =
        MakeController(playbackState, pump, sink);

    controller.start();
    const auto fired = sink.fireIfDue(controller, 100);

    CHECK(fired.has_value());
    CHECK(fired->pumpStatus ==
          FramePipelinePumpStatus::Published);
    CHECK(fired->status ==
          ProducerWakeupEventStatus::PumpedAndRearmed);
    CHECK(pump.calls == 1);
    CHECK(sink.active);
    CHECK(sink.armCalls == 2);
    CHECK(sink.duplicateArmAttempts == 0);
    return true;
}

bool TestDroppedLateContinuationNoCatchup() {
    PlaybackState playbackState = PlaybackState::Playing;
    PumpScript pump({
        PumpResult(FramePipelinePumpStatus::DroppedLate),
        PumpResult(FramePipelinePumpStatus::EndOfStream),
    });
    FakeWakeupSink sink;
    auto controller =
        MakeController(playbackState, pump, sink);

    controller.start();
    const auto fired = sink.fireIfDue(controller, 200);

    CHECK(fired.has_value());
    CHECK(fired->pumpStatus ==
          FramePipelinePumpStatus::DroppedLate);
    CHECK(fired->status ==
          ProducerWakeupEventStatus::PumpedAndRearmed);
    CHECK(pump.calls == 1);
    CHECK(sink.active);
    return true;
}

bool TestLoopRestartedContinuation() {
    PlaybackState playbackState = PlaybackState::Playing;
    PumpScript pump({
        PumpResult(FramePipelinePumpStatus::LoopRestarted),
        PumpResult(FramePipelinePumpStatus::EndOfStream),
    });
    FakeWakeupSink sink;
    auto controller =
        MakeController(playbackState, pump, sink);

    controller.start();
    const auto fired = sink.fireIfDue(controller, 300);

    CHECK(fired.has_value());
    CHECK(fired->pumpStatus ==
          FramePipelinePumpStatus::LoopRestarted);
    CHECK(fired->status ==
          ProducerWakeupEventStatus::PumpedAndRearmed);
    CHECK(pump.calls == 1);
    CHECK(sink.active);
    return true;
}

bool TestQueueDroppedContinuation() {
    PlaybackState playbackState = PlaybackState::Playing;
    PumpScript pump({
        PumpResult(FramePipelinePumpStatus::QueueDropped),
        PumpResult(FramePipelinePumpStatus::EndOfStream),
    });
    FakeWakeupSink sink;
    auto controller =
        MakeController(playbackState, pump, sink);

    controller.start();
    const auto fired = sink.fireIfDue(controller, 400);

    CHECK(fired.has_value());
    CHECK(fired->pumpStatus ==
          FramePipelinePumpStatus::QueueDropped);
    CHECK(fired->status ==
          ProducerWakeupEventStatus::PumpedAndRearmed);
    CHECK(pump.calls == 1);
    CHECK(sink.active);
    return true;
}

bool TestNotReadyUsesExplicitRetryPolicy() {
    PlaybackState playbackState = PlaybackState::Playing;
    constexpr std::uint64_t retryNs = 250'000ULL;

    PumpScript pump({
        PumpResult(FramePipelinePumpStatus::NotReady),
        PumpResult(FramePipelinePumpStatus::EndOfStream),
    });
    FakeWakeupSink sink;
    auto controller =
        MakeController(
            playbackState,
            pump,
            sink,
            retryNs);

    controller.start();
    const MonotonicHostTimeNs now = 5'000'000ULL;
    const auto fired = sink.fireIfDue(controller, now);

    CHECK(fired.has_value());
    CHECK(fired->status ==
          ProducerWakeupEventStatus::PumpedAndWaiting);
    CHECK(fired->nextDueHostTimeNs == now + retryNs);
    CHECK(sink.kind == FakeWakeupSink::Kind::Deadline);
    CHECK(sink.dueHostTimeNs == now + retryNs);
    CHECK(pump.calls == 1);

    const auto early =
        sink.fireIfDue(controller, now + retryNs - 1);
    CHECK(!early.has_value());
    CHECK(pump.calls == 1);
    return true;
}

bool TestNotReadyZeroPolicyDoesNotSpin() {
    PlaybackState playbackState = PlaybackState::Playing;
    PumpScript pump({PumpResult(FramePipelinePumpStatus::NotReady)});
    FakeWakeupSink sink;
    auto controller =
        MakeController(playbackState, pump, sink, 0);

    controller.start();
    const auto fired = sink.fireIfDue(controller, 10);

    CHECK(fired.has_value());
    CHECK(fired->status ==
          ProducerWakeupEventStatus::BecameIdle);
    CHECK(controller.state() == ProducerWakeupDriverState::Idle);
    CHECK(!sink.active);
    CHECK(pump.calls == 1);
    return true;
}

bool TestPausedPlaybackStaysIdleUntilExplicitKick() {
    PlaybackState playbackState = PlaybackState::Paused;
    PumpScript pump({PumpResult(FramePipelinePumpStatus::EndOfStream)});
    FakeWakeupSink sink;
    auto controller =
        MakeController(playbackState, pump, sink);

    const auto pausedStart = controller.start();
    CHECK(pausedStart.status ==
          ProducerWakeupEventStatus::BecameIdle);
    CHECK(controller.state() == ProducerWakeupDriverState::Idle);
    CHECK(!sink.active);
    CHECK(pump.calls == 0);

    playbackState = PlaybackState::Playing;
    const auto resumedKick = controller.start();

    CHECK(resumedKick.status ==
          ProducerWakeupEventStatus::ArmedInitial);
    CHECK(sink.active);
    CHECK(sink.kind == FakeWakeupSink::Kind::Immediate);
    CHECK(pump.calls == 0);
    return true;
}

bool TestStopCancelsFutureExecution() {
    PlaybackState playbackState = PlaybackState::Playing;
    PumpScript pump({PumpResult(FramePipelinePumpStatus::Published)});
    FakeWakeupSink sink;
    auto controller =
        MakeController(playbackState, pump, sink);

    controller.start();
    const std::uint64_t staleToken = controller.lifecycleToken();

    controller.stop();

    CHECK(controller.state() == ProducerWakeupDriverState::Stopped);
    CHECK(!sink.active);
    CHECK(controller.lifecycleToken() != staleToken);

    const auto stale =
        controller.handleWakeup(staleToken, 100);

    CHECK(stale.status ==
          ProducerWakeupEventStatus::IgnoredStaleWakeup);
    CHECK(pump.calls == 0);
    return true;
}

bool TestGenerationResetSchedulesOneNextTurn() {
    PlaybackState playbackState = PlaybackState::Playing;
    PumpScript pump({
        PumpResult(FramePipelinePumpStatus::GenerationReset),
        PumpResult(FramePipelinePumpStatus::EndOfStream),
    });
    FakeWakeupSink sink;
    auto controller =
        MakeController(playbackState, pump, sink);

    controller.start();
    const auto reset = sink.fireIfDue(controller, 100);

    CHECK(reset.has_value());
    CHECK(reset->pumpStatus ==
          FramePipelinePumpStatus::GenerationReset);
    CHECK(reset->status ==
          ProducerWakeupEventStatus::PumpedAndRearmed);
    CHECK(pump.calls == 1);
    CHECK(sink.active);

    const auto next = sink.fireIfDue(controller, 101);
    CHECK(next.has_value());
    CHECK(pump.calls == 2);
    return true;
}

bool TestEpochResetSchedulesOneNextTurn() {
    PlaybackState playbackState = PlaybackState::Playing;
    PumpScript pump({
        PumpResult(FramePipelinePumpStatus::EpochReset),
        PumpResult(FramePipelinePumpStatus::EndOfStream),
    });
    FakeWakeupSink sink;
    auto controller =
        MakeController(playbackState, pump, sink);

    controller.start();
    const auto reset = sink.fireIfDue(controller, 200);

    CHECK(reset.has_value());
    CHECK(reset->pumpStatus ==
          FramePipelinePumpStatus::EpochReset);
    CHECK(reset->status ==
          ProducerWakeupEventStatus::PumpedAndRearmed);
    CHECK(pump.calls == 1);
    CHECK(sink.active);
    return true;
}

bool TestFatalResultStopsWithoutSpin() {
    PlaybackState playbackState = PlaybackState::Playing;
    PumpScript pump({
        PumpResult(FramePipelinePumpStatus::InvalidTiming),
    });
    FakeWakeupSink sink;
    auto controller =
        MakeController(playbackState, pump, sink);

    controller.start();
    const auto fatal = sink.fireIfDue(controller, 300);

    CHECK(fatal.has_value());
    CHECK(fatal->status ==
          ProducerWakeupEventStatus::StoppedFatal);
    CHECK(fatal->pumpStatus ==
          FramePipelinePumpStatus::InvalidTiming);
    CHECK(controller.state() == ProducerWakeupDriverState::Failed);
    CHECK(!sink.active);
    CHECK(pump.calls == 1);
    return true;
}

bool TestEndOfStreamStopsWithoutRetry() {
    PlaybackState playbackState = PlaybackState::Playing;
    PumpScript pump({
        PumpResult(FramePipelinePumpStatus::EndOfStream),
    });
    FakeWakeupSink sink;
    auto controller =
        MakeController(playbackState, pump, sink);

    controller.start();
    const auto ended = sink.fireIfDue(controller, 400);

    CHECK(ended.has_value());
    CHECK(ended->status ==
          ProducerWakeupEventStatus::StoppedEndOfStream);
    CHECK(controller.state() == ProducerWakeupDriverState::Ended);
    CHECK(!sink.active);
    CHECK(pump.calls == 1);
    return true;
}

bool TestPlaybackChangeAfterPumpBecomesIdle() {
    PlaybackState playbackState = PlaybackState::Playing;
    FakeWakeupSink sink;

    ProducerWakeupPolicy policy;
    int calls = 0;

    ProducerWakeupController controller(
        [&playbackState]() {
            return playbackState;
        },
        [&playbackState, &calls](MonotonicHostTimeNs) {
            ++calls;
            playbackState = PlaybackState::Paused;
            return PumpResult(FramePipelinePumpStatus::Published);
        },
        sink,
        policy);

    controller.start();
    const auto fired = sink.fireIfDue(controller, 500);

    CHECK(fired.has_value());
    CHECK(fired->status ==
          ProducerWakeupEventStatus::BecameIdle);
    CHECK(controller.state() == ProducerWakeupDriverState::Idle);
    CHECK(!sink.active);
    CHECK(calls == 1);
    return true;
}

bool TestRepeatedStartStopIsIdempotent() {
    PlaybackState playbackState = PlaybackState::Playing;
    PumpScript pump({PumpResult(FramePipelinePumpStatus::Published)});
    FakeWakeupSink sink;
    auto controller =
        MakeController(playbackState, pump, sink);

    controller.start();
    const std::uint64_t token = controller.lifecycleToken();
    controller.start();
    controller.start();

    CHECK(controller.lifecycleToken() == token);
    CHECK(sink.armCalls == 1);
    CHECK(sink.duplicateArmAttempts == 0);

    controller.stop();
    const std::uint64_t stoppedToken =
        controller.lifecycleToken();
    controller.stop();

    CHECK(controller.lifecycleToken() == stoppedToken);
    CHECK(controller.state() == ProducerWakeupDriverState::Stopped);
    CHECK(!sink.active);
    return true;
}

bool TestAlreadyDueWaitUsesImmediateAsyncArm() {
    PlaybackState playbackState = PlaybackState::Playing;
    PumpScript pump({
        PumpResult(
            FramePipelinePumpStatus::WaitingForPresentation,
            999),
        PumpResult(FramePipelinePumpStatus::EndOfStream),
    });
    FakeWakeupSink sink;
    auto controller =
        MakeController(playbackState, pump, sink);

    controller.start();
    const auto fired = sink.fireIfDue(controller, 1'000);

    CHECK(fired.has_value());
    CHECK(fired->status ==
          ProducerWakeupEventStatus::PumpedAndWaiting);
    CHECK(sink.active);
    CHECK(sink.kind == FakeWakeupSink::Kind::Immediate);
    CHECK(pump.calls == 1);
    return true;
}

bool TestArmFailureBecomesFatal() {
    PlaybackState playbackState = PlaybackState::Playing;
    PumpScript pump({PumpResult(FramePipelinePumpStatus::EndOfStream)});
    FakeWakeupSink sink;
    sink.failNextArm = true;

    auto controller =
        MakeController(playbackState, pump, sink);

    const auto start = controller.start();

    CHECK(start.status ==
          ProducerWakeupEventStatus::StoppedFatal);
    CHECK(controller.state() == ProducerWakeupDriverState::Failed);
    CHECK(!sink.active);
    CHECK(pump.calls == 0);
    return true;
}

void Run(
    const std::string& name,
    const std::function<bool()>& test) {
    ++gTestsRun;
    try {
        if (!test()) {
            ++gFailures;
            std::cerr << "[FAIL] " << name << std::endl;
            return;
        }

        std::cout << "[PASS] " << name << std::endl;
    } catch (const std::exception& error) {
        ++gFailures;
        std::cerr << "[FAIL] " << name
                  << ": " << error.what() << std::endl;
    }
}

}  // namespace

int main() {
    Run("initial producer wakeup", TestInitialProducerWakeup);
    Run(
        "exact WAIT deadline and no early fire",
        TestExactWaitDeadlineAndNoEarlyFire);
    Run("one pump per firing", TestOnePumpPerFiring);
    Run(
        "Published continuation asynchronous",
        TestPublishedContinuationIsAsynchronous);
    Run(
        "late-drop continuation no catch-up",
        TestDroppedLateContinuationNoCatchup);
    Run("LoopRestarted continuation", TestLoopRestartedContinuation);
    Run("QueueDropped continuation", TestQueueDroppedContinuation);
    Run(
        "NotReady explicit retry policy",
        TestNotReadyUsesExplicitRetryPolicy);
    Run(
        "NotReady zero policy idle",
        TestNotReadyZeroPolicyDoesNotSpin);
    Run(
        "paused playback idle until kick",
        TestPausedPlaybackStaysIdleUntilExplicitKick);
    Run(
        "stop cancels future execution",
        TestStopCancelsFutureExecution);
    Run(
        "generation reset one next turn",
        TestGenerationResetSchedulesOneNextTurn);
    Run(
        "epoch reset one next turn",
        TestEpochResetSchedulesOneNextTurn);
    Run(
        "fatal result stops",
        TestFatalResultStopsWithoutSpin);
    Run(
        "end of stream stops",
        TestEndOfStreamStopsWithoutRetry);
    Run(
        "playback change becomes idle",
        TestPlaybackChangeAfterPumpBecomesIdle);
    Run(
        "repeated start stop idempotent",
        TestRepeatedStartStopIsIdempotent);
    Run(
        "already due WAIT immediate async",
        TestAlreadyDueWaitUsesImmediateAsyncArm);
    Run("arm failure fatal", TestArmFailureBecomesFatal);

    std::cout << "Stage F2 driver tests run: "
              << gTestsRun
              << ", failures: " << gFailures << std::endl;

    return gFailures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
