#pragma once

#include <notify.h>

#include <array>
#include <algorithm>
#include <cstddef>
#include <cstdint>

namespace vcam::product::video_diagnostics {

enum class Field : std::size_t {
    State = 0,
    ReadFrameCount,
    LastSourcePTS,
    NormalizeCounts,
    TransformCounts,
    TimelineReadyCount,
    TimelineWaitCount,
    TimelineDropCount,
    PublishCount,
    QueueDepth,
    AcquireCount,
    LatestReuseCount,
    DecisionCounts,
    CommitCounts,
    Count,
};

inline constexpr std::size_t kFieldCount =
    static_cast<std::size_t>(Field::Count);

inline constexpr std::array<const char*, kFieldCount>
    kFieldNames = {{
        "com.vcampro.video-diagnostic.state",
        "com.vcampro.video-diagnostic.read-frame-count",
        "com.vcampro.video-diagnostic.last-source-pts",
        "com.vcampro.video-diagnostic.normalize-counts",
        "com.vcampro.video-diagnostic.transform-counts",
        "com.vcampro.video-diagnostic.timeline-ready-count",
        "com.vcampro.video-diagnostic.timeline-wait-count",
        "com.vcampro.video-diagnostic.timeline-drop-count",
        "com.vcampro.video-diagnostic.publish-count",
        "com.vcampro.video-diagnostic.queue-depth",
        "com.vcampro.video-diagnostic.acquire-count",
        "com.vcampro.video-diagnostic.latest-reuse-count",
        "com.vcampro.video-diagnostic.decision-counts",
        "com.vcampro.video-diagnostic.commit-counts",
    }};

inline constexpr std::uint64_t kSelected =
    UINT64_C(1) << 0U;
inline constexpr std::uint64_t kPlaying =
    UINT64_C(1) << 1U;
inline constexpr std::uint64_t kReaderOpen =
    UINT64_C(1) << 2U;
inline constexpr std::uint64_t kReaderStarted =
    UINT64_C(1) << 3U;
inline constexpr std::uint64_t kDriverRunning =
    UINT64_C(1) << 4U;
inline constexpr std::uint64_t kHasSourcePTS =
    UINT64_C(1) << 5U;

inline constexpr unsigned kReaderErrorShift = 8U;
inline constexpr unsigned kLastReadResultShift = 16U;
inline constexpr unsigned kDriverStateShift = 24U;

inline std::uint64_t PackPair32(
    std::uint64_t low,
    std::uint64_t high) noexcept {
    const std::uint64_t lo =
        std::min<std::uint64_t>(
            low,
            UINT32_MAX);
    const std::uint64_t hi =
        std::min<std::uint64_t>(
            high,
            UINT32_MAX);
    return lo | (hi << 32U);
}

inline std::uint64_t PackSourcePTS(
    std::int64_t value,
    std::int32_t timescale) noexcept {
    const auto value32 =
        static_cast<std::uint32_t>(
            static_cast<std::int32_t>(value));
    const auto timescale32 =
        static_cast<std::uint32_t>(
            timescale);
    return
        static_cast<std::uint64_t>(value32) |
        (static_cast<std::uint64_t>(
             timescale32) << 32U);
}

inline std::uint32_t Low32(
    std::uint64_t value) noexcept {
    return static_cast<std::uint32_t>(
        value & UINT64_C(0xffffffff));
}

inline std::uint32_t High32(
    std::uint64_t value) noexcept {
    return static_cast<std::uint32_t>(
        value >> 32U);
}

struct Snapshot {
    std::array<std::uint64_t, kFieldCount>
        values{};

    std::uint64_t value(
        Field field) const noexcept {
        return values[
            static_cast<std::size_t>(field)];
    }
};

// Fixed-size Darwin notify state transport. Camera callbacks never invoke
// this type; mediaserverd publishes snapshots from its serial control queue.
class Transport final {
public:
    Transport() noexcept {
        tokens_.fill(-1);
        for (std::size_t index = 0;
             index < kFieldCount;
             ++index) {
            int token = -1;
            if (notify_register_check(
                    kFieldNames[index],
                    &token) == NOTIFY_STATUS_OK) {
                tokens_[index] = token;
            }
        }
    }

    ~Transport() {
        for (int token : tokens_) {
            if (token >= 0) {
                (void)notify_cancel(token);
            }
        }
    }

    Transport(const Transport&) = delete;
    Transport& operator=(const Transport&) = delete;

    bool valid() const noexcept {
        return std::all_of(
            tokens_.begin(),
            tokens_.end(),
            [](int token) {
                return token >= 0;
            });
    }

    void clear() noexcept {
        for (int token : tokens_) {
            if (token >= 0) {
                (void)notify_set_state(
                    token,
                    UINT64_C(0));
            }
        }
    }

    bool set(
        Field field,
        std::uint64_t value) noexcept {
        const std::size_t index =
            static_cast<std::size_t>(field);
        if (index >= tokens_.size() ||
            tokens_[index] < 0) {
            return false;
        }
        return notify_set_state(
                   tokens_[index],
                   value) ==
               NOTIFY_STATUS_OK;
    }

    bool read(
        Snapshot* snapshot) const noexcept {
        if (snapshot == nullptr) {
            return false;
        }

        Snapshot value;
        bool complete = true;
        for (std::size_t index = 0;
             index < tokens_.size();
             ++index) {
            std::uint64_t state = 0;
            if (tokens_[index] < 0 ||
                notify_get_state(
                    tokens_[index],
                    &state) !=
                    NOTIFY_STATUS_OK) {
                complete = false;
                state = 0;
            }
            value.values[index] = state;
        }

        *snapshot = value;
        return complete;
    }

private:
    std::array<int, kFieldCount> tokens_{};
};

}  // namespace vcam::product::video_diagnostics
