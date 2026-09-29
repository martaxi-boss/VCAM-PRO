#include "ProducerWakeupDriver.h"

#include "MonotonicHostClock.h"

#include <dispatch/dispatch.h>

#include <cstdint>
#include <limits>
#include <utility>

namespace vcam::media_engine {

namespace {

char kProducerWakeupQueueKey;

void IncrementSaturated(
    std::uint64_t* value) noexcept {
    if (value != nullptr &&
        *value !=
            std::numeric_limits<std::uint64_t>::max()) {
        ++*value;
    }
}

void ObserveProducerRuntimeDiagnostics(
    ProducerRuntimeDiagnosticsSnapshot* snapshot,
    const FramePipelinePumpResult& result) noexcept {
    if (snapshot == nullptr) {
        return;
    }

    snapshot->lastReadResult =
        result.readResult;
    snapshot->lastReaderError =
        result.readerError;

    if (result.readResult ==
        ReadResultKind::Frame) {
        IncrementSaturated(
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
            IncrementSaturated(
                &snapshot->normalizeSuccessCount);
        } else {
            IncrementSaturated(
                &snapshot->normalizeFailureCount);
        }
    }

    if (result.transformStatus ==
        FrameTransformStatus::Transformed) {
        IncrementSaturated(
            &snapshot->transformSuccessCount);
    } else if (
        result.status ==
            FramePipelinePumpStatus::TransformRequired ||
        result.status ==
            FramePipelinePumpStatus::TransformFailed) {
        IncrementSaturated(
            &snapshot->transformFailureCount);
    }

    switch (result.timelineStatus) {
        case frame_engine::
            TimelineScheduleStatus::ReadyNow:
            IncrementSaturated(
                &snapshot->timelineReadyCount);
            break;
        case frame_engine::
            TimelineScheduleStatus::WaitUntilDue:
            IncrementSaturated(
                &snapshot->timelineWaitCount);
            break;
        case frame_engine::
            TimelineScheduleStatus::DropLate:
            IncrementSaturated(
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

}  // namespace

struct ProducerWakeupDriver::Impl final : ProducerWakeupSink {
    Impl(
        frame_engine::FrameEngineState& state,
        FramePipelinePump& pump,
        ProducerWakeupDriverConfig config)
        : state_(state),
          pump_(pump),
          config_(config) {
        queue_ = dispatch_queue_create(
            "com.vcampro.frame-engine.f2-producer",
            DISPATCH_QUEUE_SERIAL);
        if (queue_ == nullptr) {
            return;
        }

        dispatch_queue_set_specific(
            queue_,
            &kProducerWakeupQueueKey,
            this,
            nullptr);

        timer_ = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_TIMER,
            0,
            0,
            queue_);
        if (timer_ == nullptr) {
            return;
        }

        ProducerWakeupPolicy policy;
        policy.notReadyRetryNs = config_.notReadyRetryNs;

        controller_ = std::make_unique<ProducerWakeupController>(
            [this]() {
                return state_.playbackState();
            },
            [this](frame_engine::MonotonicHostTimeNs nowHostTimeNs) {
                const FramePipelinePumpResult result =
                    pump_.pumpOnceAtHostTime(nowHostTimeNs);
                observePumpResult(result);
                return result;
            },
            *this,
            policy);

        dispatch_source_set_event_handler(timer_, ^{
            this->handleTimerFired();
        });

        dispatch_source_set_timer(
            timer_,
            DISPATCH_TIME_FOREVER,
            DISPATCH_TIME_FOREVER,
            0);
        dispatch_resume(timer_);

        valid_ = true;
    }

    ~Impl() override {
        if (queue_ == nullptr) {
            return;
        }

        auto cleanup = [this]() {
            if (controller_) {
                controller_->stop();
            }

            disarm();

            if (timer_ != nullptr) {
                dispatch_source_set_event_handler(timer_, ^{});
                dispatch_source_cancel(timer_);
            }

            valid_ = false;
        };

        if (isOnProducerQueue()) {
            cleanup();
        } else {
            dispatch_sync(queue_, ^{
                cleanup();
            });
        }
    }

    bool start() {
        if (!valid_ || !controller_) {
            return false;
        }

        bool success = false;
        auto operation = [this, &success]() {
            const auto result = controller_->start();
            success =
                result.driverState != ProducerWakeupDriverState::Failed;
        };

        if (isOnProducerQueue()) {
            operation();
        } else {
            dispatch_sync(queue_, ^{
                operation();
            });
        }

        return success;
    }

    void stop() {
        if (!valid_ || !controller_) {
            return;
        }

        auto operation = [this]() {
            controller_->stop();
        };

        if (isOnProducerQueue()) {
            operation();
        } else {
            dispatch_sync(queue_, ^{
                operation();
            });
        }
    }

    ProducerWakeupDriverState state() const {
        if (!valid_ || !controller_) {
            return ProducerWakeupDriverState::Stopped;
        }

        ProducerWakeupDriverState value =
            ProducerWakeupDriverState::Stopped;

        auto operation = [this, &value]() {
            value = controller_->state();
        };

        if (isOnProducerQueue()) {
            operation();
        } else {
            dispatch_sync(queue_, ^{
                operation();
            });
        }

        return value;
    }

    std::uint64_t lifecycleToken() const {
        if (!valid_ || !controller_) {
            return 0;
        }

        std::uint64_t value = 0;

        auto operation = [this, &value]() {
            value = controller_->lifecycleToken();
        };

        if (isOnProducerQueue()) {
            operation();
        } else {
            dispatch_sync(queue_, ^{
                operation();
            });
        }

        return value;
    }

    std::optional<FramePipelinePumpStatus> lastPumpStatus() const {
        if (!valid_ || !controller_) return std::nullopt;
        std::optional<FramePipelinePumpStatus> value;
        auto operation = [this, &value]() { value = lastPumpStatus_; };
        if (isOnProducerQueue()) operation();
        else dispatch_sync(queue_, ^{ operation(); });
        return value;
    }

    std::uint64_t publishedFrameCount() const {
        if (!valid_ || !controller_) return 0;
        std::uint64_t value = 0;
        auto operation = [this, &value]() { value = publishedFrameCount_; };
        if (isOnProducerQueue()) operation();
        else dispatch_sync(queue_, ^{ operation(); });
        return value;
    }

    ProducerRuntimeDiagnosticsSnapshot
    runtimeDiagnostics() const {
        ProducerRuntimeDiagnosticsSnapshot value;
        if (!valid_ || !controller_) {
            return value;
        }
        auto operation = [this, &value]() {
            value = runtimeDiagnostics_;
            value.publishCount =
                publishedFrameCount_;
        };
        if (isOnProducerQueue()) {
            operation();
        } else {
            dispatch_sync(queue_, ^{
                operation();
            });
        }
        return value;
    }

    void observePumpResult(
        const FramePipelinePumpResult& result) noexcept {
        ObserveProducerRuntimeDiagnostics(
            &runtimeDiagnostics_,
            result);
    }

    bool armImmediate(
        std::uint64_t lifecycleToken) noexcept override {
        if (!valid_ || timer_ == nullptr) {
            return false;
        }

        if (timerArmed_) {
            return true;
        }

        armedLifecycleToken_ = lifecycleToken;
        timerArmed_ = true;

        dispatch_source_set_timer(
            timer_,
            DISPATCH_TIME_NOW,
            DISPATCH_TIME_FOREVER,
            config_.timerLeewayNs);

        return true;
    }

    bool armAtHostTime(
        frame_engine::MonotonicHostTimeNs dueHostTimeNs,
        std::uint64_t lifecycleToken) noexcept override {
        if (!valid_ || timer_ == nullptr) {
            return false;
        }

        if (timerArmed_) {
            return true;
        }

        frame_engine::MonotonicHostTimeNs nowHostTimeNs = 0;
        if (!frame_engine::MonotonicHostClock::nowNanoseconds(
                &nowHostTimeNs)) {
            return false;
        }

        if (dueHostTimeNs <= nowHostTimeNs) {
            return armImmediate(lifecycleToken);
        }

        const auto deltaNs = dueHostTimeNs - nowHostTimeNs;
        if (deltaNs >
            static_cast<std::uint64_t>(
                std::numeric_limits<std::int64_t>::max())) {
            return false;
        }

        armedLifecycleToken_ = lifecycleToken;
        timerArmed_ = true;

        dispatch_source_set_timer(
            timer_,
            dispatch_time(
                DISPATCH_TIME_NOW,
                static_cast<std::int64_t>(deltaNs)),
            DISPATCH_TIME_FOREVER,
            config_.timerLeewayNs);

        return true;
    }

    void disarm() noexcept override {
        timerArmed_ = false;
        armedLifecycleToken_ = 0;

        if (timer_ != nullptr) {
            dispatch_source_set_timer(
                timer_,
                DISPATCH_TIME_FOREVER,
                DISPATCH_TIME_FOREVER,
                0);
        }
    }

    bool isOnProducerQueue() const noexcept {
        return dispatch_get_specific(
                   &kProducerWakeupQueueKey) == this;
    }

    void handleTimerFired() {
        if (!valid_ ||
            !controller_ ||
            !timerArmed_) {
            return;
        }

        const std::uint64_t firingToken =
            armedLifecycleToken_;

        timerArmed_ = false;
        armedLifecycleToken_ = 0;
        dispatch_source_set_timer(
            timer_,
            DISPATCH_TIME_FOREVER,
            DISPATCH_TIME_FOREVER,
            0);

        frame_engine::MonotonicHostTimeNs nowHostTimeNs = 0;
        if (!frame_engine::MonotonicHostClock::nowNanoseconds(
                &nowHostTimeNs)) {
            controller_->failPlatform();
            return;
        }

        // Exactly one controller event is processed for this timer firing.
        // The controller invokes pumpOnceAtHostTime() at most once and any
        // continuation is scheduled asynchronously through this same source.
        const ProducerWakeupEventResult result =
            controller_->handleWakeup(
                firingToken,
                nowHostTimeNs);
        if (result.pumpStatus.has_value()) {
            lastPumpStatus_ = result.pumpStatus;
            if (*result.pumpStatus ==
                    FramePipelinePumpStatus::Published &&
                publishedFrameCount_ !=
                    std::numeric_limits<std::uint64_t>::max()) {
                ++publishedFrameCount_;
            }

            if (config_.singlePublication &&
                *result.pumpStatus ==
                    FramePipelinePumpStatus::Published) {
                controller_->stop();
                disarm();
            }
        }
    }

    frame_engine::FrameEngineState& state_;
    FramePipelinePump& pump_;
    ProducerWakeupDriverConfig config_{};

    dispatch_queue_t queue_ = nullptr;
    dispatch_source_t timer_ = nullptr;

    std::unique_ptr<ProducerWakeupController> controller_;

    bool valid_ = false;
    bool timerArmed_ = false;
    std::uint64_t armedLifecycleToken_ = 0;
    std::optional<FramePipelinePumpStatus> lastPumpStatus_;
    std::uint64_t publishedFrameCount_ = 0;
    ProducerRuntimeDiagnosticsSnapshot
        runtimeDiagnostics_{};
};

ProducerWakeupDriver::ProducerWakeupDriver(
    frame_engine::FrameEngineState& state,
    FramePipelinePump& pump,
    ProducerWakeupDriverConfig config)
    : impl_(std::make_unique<Impl>(
          state,
          pump,
          config)) {}

ProducerWakeupDriver::~ProducerWakeupDriver() = default;

bool ProducerWakeupDriver::valid() const noexcept {
    return impl_ && impl_->valid_;
}

bool ProducerWakeupDriver::start() {
    return impl_ && impl_->start();
}

void ProducerWakeupDriver::stop() {
    if (impl_) {
        impl_->stop();
    }
}

ProducerWakeupDriverState ProducerWakeupDriver::state() const {
    return impl_
        ? impl_->state()
        : ProducerWakeupDriverState::Stopped;
}

std::uint64_t ProducerWakeupDriver::lifecycleToken() const {
    return impl_
        ? impl_->lifecycleToken()
        : 0;
}

std::optional<FramePipelinePumpStatus>
ProducerWakeupDriver::lastPumpStatus() const {
    return impl_ ? impl_->lastPumpStatus() : std::nullopt;
}

std::uint64_t ProducerWakeupDriver::publishedFrameCount() const {
    return impl_ ? impl_->publishedFrameCount() : 0;
}

ProducerRuntimeDiagnosticsSnapshot
ProducerWakeupDriver::runtimeDiagnostics() const {
    return impl_
        ? impl_->runtimeDiagnostics()
        : ProducerRuntimeDiagnosticsSnapshot{};
}

#if defined(VCAM_TESTING)
void ObserveProducerRuntimeDiagnosticsForTesting(
    ProducerRuntimeDiagnosticsSnapshot* snapshot,
    const FramePipelinePumpResult& result) noexcept {
    ObserveProducerRuntimeDiagnostics(
        snapshot,
        result);
}
#endif

}  // namespace vcam::media_engine
