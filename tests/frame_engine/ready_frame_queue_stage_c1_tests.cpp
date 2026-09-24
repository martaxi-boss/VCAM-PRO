#include "ReadyFrameQueue.h"

#include <CoreVideo/CoreVideo.h>

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <future>
#include <iostream>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>
#include <utility>

namespace vcam::frame_engine {

class ReadyFrameQueueTestAccess final {
public:
    static std::unique_lock<std::mutex> lock(
        ReadyFrameQueue& queue) {
        return std::unique_lock<std::mutex>(queue.mutex_);
    }
};

}  // namespace vcam::frame_engine

namespace {

using namespace vcam::frame_engine;

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

CVPixelBufferRef CreatePixelBuffer(
    OSType format =
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    std::size_t width = 8,
    std::size_t height = 6) {
    CVPixelBufferRef pixelBuffer = nullptr;
    const CVReturn result = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        format,
        nullptr,
        &pixelBuffer);
    return result == kCVReturnSuccess ? pixelBuffer : nullptr;
}

PreparedFrame MakeFrame(
    std::uint64_t generation,
    std::uint64_t epoch,
    std::uint64_t sequence,
    FrameValidity validity = FrameValidity::Ready,
    OrientationState orientation = OrientationState::Normalized,
    OSType format =
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
    CVPixelBufferRef pixelBuffer = CreatePixelBuffer(format);
    if (pixelBuffer == nullptr) {
        throw std::runtime_error("Unable to create CVPixelBuffer fixture.");
    }

    FrameIdentity identity{
        sequence,
        generation,
        epoch,
        0,
    };
    FrameTiming timing;
    timing.sourcePTS = CMTimeMake(
        static_cast<std::int64_t>(sequence),
        30);
    timing.presentationTimestamp = kCMTimeInvalid;
    timing.duration = CMTimeMake(1, 30);

    PreparedFrame frame(
        pixelBuffer,
        identity,
        timing,
        orientation,
        FrameValidity::Ready);
    CVPixelBufferRelease(pixelBuffer);

    if (validity == FrameValidity::Invalidated) {
        frame.invalidate();
    } else if (validity == FrameValidity::Failed) {
        frame.markFailed();
    }

    return frame;
}

QueueContext Context(
    std::uint64_t generation = 1,
    std::uint64_t epoch = 1,
    std::optional<std::uint64_t> minimumSequence =
        std::nullopt) {
    return {generation, epoch, minimumSequence};
}

bool TestCapacityZeroRejected() {
    bool rejected = false;
    try {
        ReadyFrameQueue queue(0);
    } catch (const std::invalid_argument&) {
        rejected = true;
    }
    CHECK(rejected);
    return true;
}

bool TestPublishReadySucceeds() {
    ReadyFrameQueue queue(2);
    CHECK(queue.publish(MakeFrame(1, 1, 0), Context()) ==
          PublishResult::Published);
    CHECK(queue.size() == 1);
    return true;
}

bool TestSizeNeverExceedsCapacity() {
    ReadyFrameQueue queue(2);
    for (std::uint64_t sequence = 0; sequence < 20; ++sequence) {
        CHECK(queue.publish(
                  MakeFrame(1, 1, sequence),
                  Context()) == PublishResult::Published);
        CHECK(queue.size() <= queue.capacity());
    }
    CHECK(queue.size() == 2);
    return true;
}

bool TestAcquireEmptyImmediate() {
    ReadyFrameQueue queue(1);
    AcquireResult result = queue.tryAcquire(Context());
    CHECK(result.kind == AcquireResultKind::Empty);
    CHECK(!result.lease.has_value());
    return true;
}

bool TestAcquireMatchingContext() {
    ReadyFrameQueue queue(2);
    CHECK(queue.publish(MakeFrame(3, 4, 7),
                        Context(3, 4)) ==
          PublishResult::Published);

    AcquireResult result = queue.tryAcquire(Context(3, 4));
    CHECK(result.kind == AcquireResultKind::Acquired);
    CHECK(result.lease.has_value());
    CHECK(result.lease->valid());
    CHECK(result.lease->frameLease() != nullptr);
    CHECK(result.lease->frameLease()->identity().sequence == 7);
    return true;
}

bool TestOldGenerationPurged() {
    ReadyFrameQueue queue(2);
    CHECK(queue.publish(MakeFrame(1, 5, 0),
                        Context(1, 5)) ==
          PublishResult::Published);

    AcquireResult result = queue.tryAcquire(Context(2, 5));
    CHECK(result.kind == AcquireResultKind::NoEligibleFrame);
    CHECK(queue.size() == 0);
    return true;
}

bool TestOldEpochPurged() {
    ReadyFrameQueue queue(2);
    CHECK(queue.publish(MakeFrame(2, 4, 0),
                        Context(2, 4)) ==
          PublishResult::Published);

    AcquireResult result = queue.tryAcquire(Context(2, 5));
    CHECK(result.kind == AcquireResultKind::NoEligibleFrame);
    CHECK(queue.size() == 0);
    return true;
}

bool TestMinimumSequencePurgesStale() {
    ReadyFrameQueue queue(3);
    CHECK(queue.publish(MakeFrame(1, 1, 3),
                        Context()) ==
          PublishResult::Published);

    AcquireResult result =
        queue.tryAcquire(Context(1, 1, 4));
    CHECK(result.kind == AcquireResultKind::NoEligibleFrame);
    CHECK(queue.size() == 0);
    return true;
}

bool TestInvalidatedNotPublished() {
    ReadyFrameQueue queue(2);
    CHECK(queue.publish(
              MakeFrame(1, 1, 0, FrameValidity::Invalidated),
              Context()) == PublishResult::DroppedInvalid);
    CHECK(queue.size() == 0);
    return true;
}

bool TestFailedNotPublished() {
    ReadyFrameQueue queue(2);
    CHECK(queue.publish(
              MakeFrame(1, 1, 0, FrameValidity::Failed),
              Context()) == PublishResult::DroppedInvalid);
    CHECK(queue.size() == 0);
    return true;
}

bool TestLeaseSurvivesEntryPurge() {
    ReadyFrameQueue queue(1);
    CHECK(queue.publish(MakeFrame(1, 1, 0),
                        Context()) ==
          PublishResult::Published);

    AcquireResult result = queue.tryAcquire(Context());
    CHECK(result.kind == AcquireResultKind::Acquired);
    CHECK(result.lease.has_value());
    CHECK(result.lease->frameLease() != nullptr);

    CVPixelBufferRef held =
        result.lease->frameLease()->pixelBuffer();
    CHECK(held != nullptr);
    CHECK(CVPixelBufferGetWidth(held) == 8);

    CHECK(queue.purgeGeneration(2) == 1);
    CHECK(queue.size() == 0);

    CHECK(result.lease->valid());
    CHECK(CVPixelBufferGetWidth(
              result.lease->frameLease()->pixelBuffer()) == 8);
    return true;
}

bool TestFullQueueEvictsOldestUnleased() {
    ReadyFrameQueue queue(2);
    CHECK(queue.publish(MakeFrame(1, 1, 1),
                        Context()) ==
          PublishResult::Published);
    CHECK(queue.publish(MakeFrame(1, 1, 2),
                        Context()) ==
          PublishResult::Published);
    CHECK(queue.publish(MakeFrame(1, 1, 3),
                        Context()) ==
          PublishResult::Published);
    CHECK(queue.size() == 2);

    AcquireResult result = queue.tryAcquire(Context());
    CHECK(result.kind == AcquireResultKind::Acquired);
    CHECK(result.lease->frameLease()->identity().sequence == 2);
    return true;
}

bool TestAllLeasedDropsNewFrame() {
    ReadyFrameQueue queue(1);
    CHECK(queue.publish(MakeFrame(1, 1, 1),
                        Context()) ==
          PublishResult::Published);

    AcquireResult result = queue.tryAcquire(Context());
    CHECK(result.kind == AcquireResultKind::Acquired);

    CHECK(queue.publish(MakeFrame(1, 1, 2),
                        Context()) ==
          PublishResult::DroppedFullLeased);
    CHECK(queue.size() == 1);
    return true;
}

bool TestReleaseLeasePermitsReclamation() {
    ReadyFrameQueue queue(1);
    CHECK(queue.publish(MakeFrame(1, 1, 1),
                        Context()) ==
          PublishResult::Published);

    AcquireResult result = queue.tryAcquire(Context());
    CHECK(result.kind == AcquireResultKind::Acquired);
    result.lease.reset();

    CHECK(queue.publish(MakeFrame(1, 1, 2),
                        Context()) ==
          PublishResult::Published);
    CHECK(queue.size() == 1);

    AcquireResult next = queue.tryAcquire(Context());
    CHECK(next.kind == AcquireResultKind::Acquired);
    CHECK(next.lease->frameLease()->identity().sequence == 2);
    return true;
}

bool TestContentionReturnsImmediately() {
    ReadyFrameQueue queue(1);
    CHECK(queue.publish(MakeFrame(1, 1, 0),
                        Context()) ==
          PublishResult::Published);

    auto lock = ReadyFrameQueueTestAccess::lock(queue);
    auto future = std::async(std::launch::async, [&queue] {
        return queue.tryAcquire(Context()).kind;
    });

    const auto status =
        future.wait_for(std::chrono::milliseconds(250));
    lock.unlock();

    CHECK(status == std::future_status::ready);
    CHECK(future.get() == AcquireResultKind::Contended);
    return true;
}

bool TestRepeatedPublishNeverGrows() {
    ReadyFrameQueue queue(3);
    for (std::uint64_t sequence = 0; sequence < 100; ++sequence) {
        const PublishResult result =
            queue.publish(MakeFrame(1, 1, sequence), Context());
        CHECK(result == PublishResult::Published);
        CHECK(queue.size() <= 3);
    }
    CHECK(queue.size() == 3);
    return true;
}

bool TestPurgeGeneration() {
    ReadyFrameQueue queue(3);
    CHECK(queue.publish(MakeFrame(1, 1, 0),
                        Context(1, 1)) ==
          PublishResult::Published);
    CHECK(queue.publish(MakeFrame(2, 1, 1),
                        Context(2, 1)) ==
          PublishResult::Published);

    CHECK(queue.purgeGeneration(2) == 1);
    CHECK(queue.size() == 1);

    AcquireResult result = queue.tryAcquire(Context(2, 1));
    CHECK(result.kind == AcquireResultKind::Acquired);
    CHECK(result.lease->frameLease()->identity().mediaGeneration == 2);
    return true;
}

bool TestPurgeEpoch() {
    ReadyFrameQueue queue(3);
    CHECK(queue.publish(MakeFrame(2, 1, 0),
                        Context(2, 1)) ==
          PublishResult::Published);
    CHECK(queue.publish(MakeFrame(2, 2, 1),
                        Context(2, 2)) ==
          PublishResult::Published);

    CHECK(queue.purgeEpoch(2, 2) == 1);
    CHECK(queue.size() == 1);

    AcquireResult result = queue.tryAcquire(Context(2, 2));
    CHECK(result.kind == AcquireResultKind::Acquired);
    CHECK(result.lease->frameLease()->identity().timelineEpoch == 2);
    return true;
}

void Run(const std::string& name,
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
    Run("Capacity zero rejected", TestCapacityZeroRejected);
    Run("Publish Ready succeeds", TestPublishReadySucceeds);
    Run("Size never exceeds capacity", TestSizeNeverExceedsCapacity);
    Run("Acquire empty immediate", TestAcquireEmptyImmediate);
    Run("Acquire matching context", TestAcquireMatchingContext);
    Run("Old generation purged", TestOldGenerationPurged);
    Run("Old epoch purged", TestOldEpochPurged);
    Run("Minimum sequence purges stale", TestMinimumSequencePurgesStale);
    Run("Invalidated not published", TestInvalidatedNotPublished);
    Run("Failed not published", TestFailedNotPublished);
    Run("Lease survives entry purge", TestLeaseSurvivesEntryPurge);
    Run("Full queue evicts oldest unleased", TestFullQueueEvictsOldestUnleased);
    Run("All leased drops new frame", TestAllLeasedDropsNewFrame);
    Run("Release lease permits reclamation", TestReleaseLeasePermitsReclamation);
    Run("Contention returns immediately", TestContentionReturnsImmediately);
    Run("Repeated publish never grows", TestRepeatedPublishNeverGrows);
    Run("Purge generation", TestPurgeGeneration);
    Run("Purge epoch", TestPurgeEpoch);

    std::cout << "Stage C1 queue tests run: " << gTestsRun
              << ", failures: " << gFailures << std::endl;
    return gFailures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
