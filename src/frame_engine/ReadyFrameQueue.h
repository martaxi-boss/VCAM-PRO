#pragma once

#include "PreparedFrame.h"

#include <cstddef>
#include <cstdint>
#include <deque>
#include <memory>
#include <mutex>
#include <optional>

namespace vcam::frame_engine {

struct ReadyFrameLeaseTracker;

struct QueueContext {
    std::uint64_t currentMediaGeneration = 0;
    std::uint64_t currentTimelineEpoch = 0;
    std::optional<std::uint64_t> minimumSequence;
};

enum class PublishResult : std::uint8_t {
    Published = 0,
    DroppedInvalid,
    DroppedStale,
    DroppedFullLeased,
};

enum class AcquireResultKind : std::uint8_t {
    Acquired = 0,
    Empty,
    NoEligibleFrame,
    Contended,
};

class ReadyFrameLease final {
public:
    ReadyFrameLease(ReadyFrameLease&& other) noexcept;
    ReadyFrameLease& operator=(ReadyFrameLease&& other) noexcept;
    ReadyFrameLease(const ReadyFrameLease&) = delete;
    ReadyFrameLease& operator=(const ReadyFrameLease&) = delete;
    ~ReadyFrameLease();

    bool valid() const noexcept;
    const FrameLease* frameLease() const noexcept;

private:
    friend class ReadyFrameQueue;

    ReadyFrameLease(FrameLease&& lease,
                    std::shared_ptr<ReadyFrameLeaseTracker> tracker);

    void releaseTracking() noexcept;

    std::optional<FrameLease> lease_;
    std::shared_ptr<ReadyFrameLeaseTracker> tracker_;
};

struct AcquireResult {
    AcquireResultKind kind = AcquireResultKind::Empty;
    std::optional<ReadyFrameLease> lease;
};

class ReadyFrameQueue final {
public:
    explicit ReadyFrameQueue(std::size_t capacity);
    ~ReadyFrameQueue();

    ReadyFrameQueue(const ReadyFrameQueue&) = delete;
    ReadyFrameQueue& operator=(const ReadyFrameQueue&) = delete;
    ReadyFrameQueue(ReadyFrameQueue&&) = delete;
    ReadyFrameQueue& operator=(ReadyFrameQueue&&) = delete;

    std::size_t capacity() const noexcept;
    std::size_t size() const;

    PublishResult publish(PreparedFrame frame,
                          const QueueContext& context);

    AcquireResult tryAcquire(const QueueContext& context);

    std::size_t purgeGeneration(std::uint64_t currentMediaGeneration);
    std::size_t purgeEpoch(std::uint64_t currentMediaGeneration,
                           std::uint64_t currentTimelineEpoch);
    std::size_t purgeStale(const QueueContext& context);

private:
    friend class ReadyFrameQueueTestAccess;

    struct Entry;

    static bool frameMatchesContext(const PreparedFrame& frame,
                                    const QueueContext& context) noexcept;
    static bool entryIsLogicallyConsumed(
        const std::shared_ptr<Entry>& entry) noexcept;

    std::size_t purgeContextLocked(const QueueContext& context);

    const std::size_t capacity_;
    mutable std::mutex mutex_;
    std::deque<std::shared_ptr<Entry>> entries_;
};

}  // namespace vcam::frame_engine
