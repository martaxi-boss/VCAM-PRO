#include "ReadyFrameQueue.h"

#include <CoreVideo/CoreVideo.h>

#include <cstdlib>
#include <functional>
#include <iostream>
#include <optional>
#include <stdexcept>
#include <string>

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

PreparedFrame MakeFrame(std::uint64_t generation,
                        std::uint64_t epoch,
                        std::uint64_t sequence) {
    CVPixelBufferRef pixelBuffer = nullptr;
    const CVReturn result = CVPixelBufferCreate(
        kCFAllocatorDefault,
        8,
        6,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        nullptr,
        &pixelBuffer);
    if (result != kCVReturnSuccess || pixelBuffer == nullptr) {
        throw std::runtime_error("Unable to create consumer fixture.");
    }

    FrameIdentity identity{sequence, generation, epoch, 0};
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
        OrientationState::Normalized,
        FrameValidity::Ready);
    CVPixelBufferRelease(pixelBuffer);
    return frame;
}

QueueContext Context(std::uint64_t generation,
                     std::uint64_t epoch,
                     std::optional<std::uint64_t> minimumSequence =
                         std::nullopt) {
    return {generation, epoch, minimumSequence};
}

bool TestPublishAcquireLease() {
    ReadyFrameQueue queue(2);
    CHECK(queue.publish(
              MakeFrame(3, 7, 11),
              Context(3, 7)) == PublishResult::Published);

    AcquireResult acquired = queue.tryAcquire(Context(3, 7));
    CHECK(acquired.kind == AcquireResultKind::Acquired);
    CHECK(acquired.lease.has_value());
    CHECK(acquired.lease->valid());
    CHECK(acquired.lease->frameLease() != nullptr);
    CHECK(acquired.lease->frameLease()->pixelBuffer() != nullptr);
    CHECK(acquired.lease->frameLease()->width() == 8);
    CHECK(acquired.lease->frameLease()->height() == 6);
    CHECK(acquired.lease->frameLease()->identity().sequence == 11);
    return true;
}

bool TestEmpty() {
    ReadyFrameQueue queue(1);
    const AcquireResult acquired = queue.tryAcquire(Context(1, 1));
    CHECK(acquired.kind == AcquireResultKind::Empty);
    CHECK(!acquired.lease.has_value());
    return true;
}

bool TestGenerationMismatchNoEligible() {
    ReadyFrameQueue queue(2);
    CHECK(queue.publish(
              MakeFrame(4, 9, 1),
              Context(4, 9)) == PublishResult::Published);

    const AcquireResult acquired = queue.tryAcquire(Context(5, 9));
    CHECK(acquired.kind == AcquireResultKind::NoEligibleFrame);
    CHECK(!acquired.lease.has_value());
    CHECK(queue.size() == 0);
    return true;
}

bool TestEpochMismatchNoEligible() {
    ReadyFrameQueue queue(2);
    CHECK(queue.publish(
              MakeFrame(4, 9, 2),
              Context(4, 9)) == PublishResult::Published);

    const AcquireResult acquired = queue.tryAcquire(Context(4, 10));
    CHECK(acquired.kind == AcquireResultKind::NoEligibleFrame);
    CHECK(!acquired.lease.has_value());
    CHECK(queue.size() == 0);
    return true;
}

bool TestMinimumSequenceRejectsStale() {
    ReadyFrameQueue queue(3);
    CHECK(queue.publish(
              MakeFrame(8, 2, 3),
              Context(8, 2)) == PublishResult::Published);
    CHECK(queue.publish(
              MakeFrame(8, 2, 4),
              Context(8, 2)) == PublishResult::Published);

    const AcquireResult acquired =
        queue.tryAcquire(Context(8, 2, 5));
    CHECK(acquired.kind == AcquireResultKind::NoEligibleFrame);
    CHECK(!acquired.lease.has_value());
    CHECK(queue.size() == 0);
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
    Run("publish/acquire/lease", TestPublishAcquireLease);
    Run("empty", TestEmpty);
    Run("generation mismatch", TestGenerationMismatchNoEligible);
    Run("epoch mismatch", TestEpochMismatchNoEligible);
    Run("minimum sequence stale rejection",
        TestMinimumSequenceRejectsStale);

    std::cout << "Stage D2 consumer tests run: " << gTestsRun
              << ", failures: " << gFailures << std::endl;
    return gFailures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
