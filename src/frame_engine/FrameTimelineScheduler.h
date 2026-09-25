#pragma once

#include "PreparedFrame.h"

#include <CoreMedia/CoreMedia.h>

#include <cstdint>
#include <optional>

namespace vcam::frame_engine {

// Stage F1 public host-time contract.
//
// All host times used by FrameTimelineScheduler are explicit monotonic
// nanoseconds supplied by the caller. The scheduler never samples a clock,
// sleeps, creates threads, or owns a timer.
using MonotonicHostTimeNs = std::uint64_t;

enum class TimelineScheduleStatus : std::uint8_t {
    ReadyNow = 0,
    WaitUntilDue,
    DropLate,
    InvalidTiming,
    GenerationMismatch,
    TimelineMismatch,
};

struct TimelineScheduleResult {
    TimelineScheduleStatus status = TimelineScheduleStatus::InvalidTiming;
    std::optional<MonotonicHostTimeNs> dueHostTimeNs;
};

class FrameTimelineScheduler final {
public:
    explicit FrameTimelineScheduler(
        MonotonicHostTimeNs maxLatenessNs) noexcept;

    FrameTimelineScheduler(const FrameTimelineScheduler&) = delete;
    FrameTimelineScheduler& operator=(const FrameTimelineScheduler&) = delete;
    FrameTimelineScheduler(FrameTimelineScheduler&&) = delete;
    FrameTimelineScheduler& operator=(FrameTimelineScheduler&&) = delete;

    TimelineScheduleResult evaluate(
        const PreparedFrame& frame,
        std::uint64_t currentMediaGeneration,
        std::uint64_t currentTimelineEpoch,
        MonotonicHostTimeNs nowHostTimeNs) noexcept;

    void reset() noexcept;

    MonotonicHostTimeNs maxLatenessNs() const noexcept;

private:
    static bool sameIdentity(
        const FrameIdentity& lhs,
        const FrameIdentity& rhs) noexcept;

    static bool isNumericTime(CMTime time) noexcept;

    static bool nonNegativeDeltaToNanoseconds(
        CMTime later,
        CMTime earlier,
        MonotonicHostTimeNs* result) noexcept;

    static bool positiveDurationToNanoseconds(
        CMTime duration,
        MonotonicHostTimeNs* result) noexcept;

    static bool checkedAdd(
        MonotonicHostTimeNs lhs,
        MonotonicHostTimeNs rhs,
        MonotonicHostTimeNs* result) noexcept;

    TimelineScheduleResult classify(
        MonotonicHostTimeNs dueHostTimeNs,
        MonotonicHostTimeNs nowHostTimeNs) const noexcept;

    void initializeContext(
        const PreparedFrame& frame,
        std::uint64_t currentMediaGeneration,
        std::uint64_t currentTimelineEpoch,
        MonotonicHostTimeNs nowHostTimeNs) noexcept;

    bool anchored_ = false;
    std::uint64_t mediaGeneration_ = 0;
    std::uint64_t timelineEpoch_ = 0;
    std::uint64_t loopIteration_ = 0;

    CMTime sourceAnchor_ = kCMTimeInvalid;
    MonotonicHostTimeNs hostAnchorNs_ = 0;

    bool hasLastScheduledFrame_ = false;
    FrameIdentity lastIdentity_{};
    CMTime lastSourcePTS_ = kCMTimeInvalid;
    CMTime lastDuration_ = kCMTimeInvalid;
    MonotonicHostTimeNs lastDueHostTimeNs_ = 0;

    MonotonicHostTimeNs maxLatenessNs_ = 0;
};

}  // namespace vcam::frame_engine
