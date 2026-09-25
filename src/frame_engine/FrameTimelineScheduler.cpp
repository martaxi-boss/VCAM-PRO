#include "FrameTimelineScheduler.h"

#include <algorithm>
#include <limits>

namespace vcam::frame_engine {

namespace {

constexpr std::uint64_t kNanosecondsPerSecond = 1000000000ULL;

}  // namespace

FrameTimelineScheduler::FrameTimelineScheduler(
    MonotonicHostTimeNs maxLatenessNs) noexcept
    : maxLatenessNs_(maxLatenessNs) {}

TimelineScheduleResult FrameTimelineScheduler::evaluate(
    const PreparedFrame& frame,
    std::uint64_t currentMediaGeneration,
    std::uint64_t currentTimelineEpoch,
    MonotonicHostTimeNs nowHostTimeNs) noexcept {
    if (frame.identity().mediaGeneration != currentMediaGeneration) {
        return {
            TimelineScheduleStatus::GenerationMismatch,
            std::nullopt,
        };
    }

    if (frame.identity().timelineEpoch != currentTimelineEpoch) {
        return {
            TimelineScheduleStatus::TimelineMismatch,
            std::nullopt,
        };
    }

    const CMTime sourcePTS = frame.timing().sourcePTS;
    if (!isNumericTime(sourcePTS)) {
        return {
            TimelineScheduleStatus::InvalidTiming,
            std::nullopt,
        };
    }

    if (!anchored_ ||
        mediaGeneration_ != currentMediaGeneration ||
        timelineEpoch_ != currentTimelineEpoch) {
        reset();
        initializeContext(
            frame,
            currentMediaGeneration,
            currentTimelineEpoch,
            nowHostTimeNs);

        return classify(lastDueHostTimeNs_, nowHostTimeNs);
    }

    if (hasLastScheduledFrame_ &&
        sameIdentity(lastIdentity_, frame.identity())) {
        if (!isNumericTime(lastSourcePTS_) ||
            CMTimeCompare(sourcePTS, lastSourcePTS_) != 0) {
            return {
                TimelineScheduleStatus::InvalidTiming,
                std::nullopt,
            };
        }

        return classify(lastDueHostTimeNs_, nowHostTimeNs);
    }

    if (frame.identity().loopIteration < loopIteration_) {
        return {
            TimelineScheduleStatus::InvalidTiming,
            std::nullopt,
        };
    }

    MonotonicHostTimeNs dueHostTimeNs = 0;

    if (frame.identity().loopIteration != loopIteration_) {
        MonotonicHostTimeNs newHostAnchorNs = std::max(
            nowHostTimeNs,
            lastDueHostTimeNs_);

        MonotonicHostTimeNs previousDurationNs = 0;
        if (positiveDurationToNanoseconds(
                lastDuration_,
                &previousDurationNs)) {
            MonotonicHostTimeNs previousEndNs = 0;
            if (!checkedAdd(
                    lastDueHostTimeNs_,
                    previousDurationNs,
                    &previousEndNs)) {
                return {
                    TimelineScheduleStatus::InvalidTiming,
                    std::nullopt,
                };
            }
            newHostAnchorNs = std::max(
                newHostAnchorNs,
                previousEndNs);
        }

        loopIteration_ = frame.identity().loopIteration;
        sourceAnchor_ = sourcePTS;
        hostAnchorNs_ = newHostAnchorNs;
        dueHostTimeNs = hostAnchorNs_;
    } else {
        if (!isNumericTime(lastSourcePTS_) ||
            CMTimeCompare(sourcePTS, lastSourcePTS_) <= 0) {
            return {
                TimelineScheduleStatus::InvalidTiming,
                std::nullopt,
            };
        }

        MonotonicHostTimeNs deltaNs = 0;
        if (!nonNegativeDeltaToNanoseconds(
                sourcePTS,
                sourceAnchor_,
                &deltaNs) ||
            !checkedAdd(
                hostAnchorNs_,
                deltaNs,
                &dueHostTimeNs)) {
            return {
                TimelineScheduleStatus::InvalidTiming,
                std::nullopt,
            };
        }

        if (dueHostTimeNs < lastDueHostTimeNs_) {
            return {
                TimelineScheduleStatus::InvalidTiming,
                std::nullopt,
            };
        }
    }

    lastIdentity_ = frame.identity();
    lastSourcePTS_ = sourcePTS;
    lastDuration_ = frame.timing().duration;
    lastDueHostTimeNs_ = dueHostTimeNs;
    hasLastScheduledFrame_ = true;

    return classify(dueHostTimeNs, nowHostTimeNs);
}

void FrameTimelineScheduler::reset() noexcept {
    anchored_ = false;
    mediaGeneration_ = 0;
    timelineEpoch_ = 0;
    loopIteration_ = 0;
    sourceAnchor_ = kCMTimeInvalid;
    hostAnchorNs_ = 0;
    hasLastScheduledFrame_ = false;
    lastIdentity_ = {};
    lastSourcePTS_ = kCMTimeInvalid;
    lastDuration_ = kCMTimeInvalid;
    lastDueHostTimeNs_ = 0;
}

MonotonicHostTimeNs FrameTimelineScheduler::maxLatenessNs() const noexcept {
    return maxLatenessNs_;
}

bool FrameTimelineScheduler::sameIdentity(
    const FrameIdentity& lhs,
    const FrameIdentity& rhs) noexcept {
    return lhs.sequence == rhs.sequence &&
           lhs.mediaGeneration == rhs.mediaGeneration &&
           lhs.timelineEpoch == rhs.timelineEpoch &&
           lhs.loopIteration == rhs.loopIteration;
}

bool FrameTimelineScheduler::isNumericTime(CMTime time) noexcept {
    return CMTIME_IS_NUMERIC(time) && time.timescale > 0;
}

bool FrameTimelineScheduler::nonNegativeDeltaToNanoseconds(
    CMTime later,
    CMTime earlier,
    MonotonicHostTimeNs* result) noexcept {
    if (result == nullptr ||
        !isNumericTime(later) ||
        !isNumericTime(earlier) ||
        CMTimeCompare(later, earlier) < 0) {
        return false;
    }

    const CMTime delta = CMTimeSubtract(later, earlier);
    if (!isNumericTime(delta) ||
        CMTimeCompare(delta, kCMTimeZero) < 0) {
        return false;
    }

    const __int128 scaled =
        static_cast<__int128>(delta.value) *
        static_cast<__int128>(kNanosecondsPerSecond);

    if (scaled < 0) {
        return false;
    }

    const __int128 nanoseconds =
        scaled / static_cast<__int128>(delta.timescale);

    if (nanoseconds < 0 ||
        nanoseconds >
            static_cast<__int128>(
                std::numeric_limits<MonotonicHostTimeNs>::max())) {
        return false;
    }

    *result = static_cast<MonotonicHostTimeNs>(nanoseconds);
    return true;
}

bool FrameTimelineScheduler::positiveDurationToNanoseconds(
    CMTime duration,
    MonotonicHostTimeNs* result) noexcept {
    if (result == nullptr ||
        !isNumericTime(duration) ||
        CMTimeCompare(duration, kCMTimeZero) <= 0) {
        return false;
    }

    const __int128 scaled =
        static_cast<__int128>(duration.value) *
        static_cast<__int128>(kNanosecondsPerSecond);

    if (scaled <= 0) {
        return false;
    }

    const __int128 nanoseconds =
        scaled / static_cast<__int128>(duration.timescale);

    if (nanoseconds <= 0 ||
        nanoseconds >
            static_cast<__int128>(
                std::numeric_limits<MonotonicHostTimeNs>::max())) {
        return false;
    }

    *result = static_cast<MonotonicHostTimeNs>(nanoseconds);
    return true;
}

bool FrameTimelineScheduler::checkedAdd(
    MonotonicHostTimeNs lhs,
    MonotonicHostTimeNs rhs,
    MonotonicHostTimeNs* result) noexcept {
    if (result == nullptr ||
        rhs >
            std::numeric_limits<MonotonicHostTimeNs>::max() - lhs) {
        return false;
    }

    *result = lhs + rhs;
    return true;
}

TimelineScheduleResult FrameTimelineScheduler::classify(
    MonotonicHostTimeNs dueHostTimeNs,
    MonotonicHostTimeNs nowHostTimeNs) const noexcept {
    TimelineScheduleResult result;
    result.dueHostTimeNs = dueHostTimeNs;

    if (nowHostTimeNs < dueHostTimeNs) {
        result.status = TimelineScheduleStatus::WaitUntilDue;
        return result;
    }

    const MonotonicHostTimeNs latenessNs =
        nowHostTimeNs - dueHostTimeNs;

    result.status =
        latenessNs > maxLatenessNs_
            ? TimelineScheduleStatus::DropLate
            : TimelineScheduleStatus::ReadyNow;
    return result;
}

void FrameTimelineScheduler::initializeContext(
    const PreparedFrame& frame,
    std::uint64_t currentMediaGeneration,
    std::uint64_t currentTimelineEpoch,
    MonotonicHostTimeNs nowHostTimeNs) noexcept {
    anchored_ = true;
    mediaGeneration_ = currentMediaGeneration;
    timelineEpoch_ = currentTimelineEpoch;
    loopIteration_ = frame.identity().loopIteration;

    sourceAnchor_ = frame.timing().sourcePTS;
    hostAnchorNs_ = nowHostTimeNs;

    hasLastScheduledFrame_ = true;
    lastIdentity_ = frame.identity();
    lastSourcePTS_ = frame.timing().sourcePTS;
    lastDuration_ = frame.timing().duration;
    lastDueHostTimeNs_ = nowHostTimeNs;
}

}  // namespace vcam::frame_engine
