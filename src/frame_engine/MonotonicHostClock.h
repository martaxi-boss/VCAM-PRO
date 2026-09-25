#pragma once

#include "FrameTimelineScheduler.h"

namespace vcam::frame_engine {

// Public monotonic production clock for Stage F2.
//
// Uses mach_absolute_time() converted through mach_timebase_info() into the
// same nanosecond unit accepted by FrameTimelineScheduler.
class MonotonicHostClock final {
public:
    static bool nowNanoseconds(
        MonotonicHostTimeNs* result) noexcept;
};

}  // namespace vcam::frame_engine
