#include "MonotonicHostClock.h"

#include <mach/mach_time.h>

#include <cstdint>
#include <limits>

namespace vcam::frame_engine {

namespace {

bool convertTicksToNanoseconds(
    std::uint64_t ticks,
    const mach_timebase_info_data_t& timebase,
    MonotonicHostTimeNs* result) noexcept {
    if (result == nullptr ||
        timebase.numer == 0 ||
        timebase.denom == 0) {
        return false;
    }

    const std::uint64_t denominator =
        static_cast<std::uint64_t>(timebase.denom);
    const std::uint64_t numerator =
        static_cast<std::uint64_t>(timebase.numer);

    const std::uint64_t whole = ticks / denominator;
    const std::uint64_t remainder = ticks % denominator;

    if (whole >
        std::numeric_limits<MonotonicHostTimeNs>::max() /
            numerator) {
        return false;
    }

    const MonotonicHostTimeNs wholeNs = whole * numerator;

    // remainder < denominator <= UINT32_MAX and numerator <= UINT32_MAX,
    // therefore this product fits in uint64_t.
    const MonotonicHostTimeNs fractionalNs =
        (remainder * numerator) / denominator;

    if (fractionalNs >
        std::numeric_limits<MonotonicHostTimeNs>::max() -
            wholeNs) {
        return false;
    }

    *result = wholeNs + fractionalNs;
    return true;
}

const mach_timebase_info_data_t& timebaseInfo() noexcept {
    static const mach_timebase_info_data_t info = [] {
        mach_timebase_info_data_t value{};
        if (mach_timebase_info(&value) != KERN_SUCCESS) {
            value.numer = 0;
            value.denom = 0;
        }
        return value;
    }();

    return info;
}

}  // namespace

bool MonotonicHostClock::nowNanoseconds(
    MonotonicHostTimeNs* result) noexcept {
    if (result == nullptr) {
        return false;
    }

    const auto& timebase = timebaseInfo();
    if (timebase.numer == 0 || timebase.denom == 0) {
        return false;
    }

    return convertTicksToNanoseconds(
        mach_absolute_time(),
        timebase,
        result);
}

}  // namespace vcam::frame_engine
