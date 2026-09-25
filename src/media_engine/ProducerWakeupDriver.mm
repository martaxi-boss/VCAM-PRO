#include "ProducerWakeupDriver.h"

#include "MonotonicHostClock.h"

#include <dispatch/dispatch.h>

#include <cstdint>
#include <limits>
#include <utility>

namespace vcam::media_engine {

namespace {

char kProducerWakeupQueueKey;

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
                return pump_.pumpOnceAtHostTime(nowHostTimeNs);
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

        __block bool success = false;
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

        __block ProducerWakeupDriverState value =
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

        __block std::uint64_t value = 0;

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
        controller_->handleWakeup(
            firingToken,
            nowHostTimeNs);
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

}  // namespace vcam::media_engine
