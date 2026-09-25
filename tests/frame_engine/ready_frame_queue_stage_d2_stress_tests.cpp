#include "ReadyFrameQueue.h"

#include <CoreVideo/CoreVideo.h>

#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <functional>
#include <iostream>
#include <optional>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

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

class SharedPixelBuffer final {
public:
    SharedPixelBuffer() {
        if (CVPixelBufferCreate(
                kCFAllocatorDefault,
                8,
                6,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                nullptr,
                &buffer_) != kCVReturnSuccess ||
            buffer_ == nullptr) {
            throw std::runtime_error("Unable to create stress pixel buffer.");
        }
    }

    ~SharedPixelBuffer() {
        if (buffer_ != nullptr) {
            CVPixelBufferRelease(buffer_);
        }
    }

    CVPixelBufferRef get() const noexcept {
        return buffer_;
    }

private:
    CVPixelBufferRef buffer_ = nullptr;
};

PreparedFrame MakeFrame(CVPixelBufferRef pixelBuffer,
                        std::uint64_t generation,
                        std::uint64_t epoch,
                        std::uint64_t sequence) {
    FrameIdentity identity{sequence, generation, epoch, 0};
    FrameTiming timing;
    timing.sourcePTS = CMTimeMake(
        static_cast<std::int64_t>(sequence),
        30);
    timing.presentationTimestamp = kCMTimeInvalid;
    timing.duration = CMTimeMake(1, 30);
    return PreparedFrame(
        pixelBuffer,
        identity,
        timing,
        OrientationState::Normalized,
        FrameValidity::Ready);
}

QueueContext Context(std::uint64_t generation,
                     std::uint64_t epoch,
                     std::optional<std::uint64_t> minimumSequence =
                         std::nullopt) {
    return {generation, epoch, minimumSequence};
}

void UpdateMax(std::atomic<std::size_t>& maxValue,
               std::size_t candidate) {
    std::size_t observed = maxValue.load(std::memory_order_relaxed);
    while (observed < candidate &&
           !maxValue.compare_exchange_weak(
               observed,
               candidate,
               std::memory_order_relaxed)) {
    }
}

bool TestThousandsOfCycles(CVPixelBufferRef pixelBuffer) {
    const std::size_t capacities[] = {1, 2, 3, 8};

    for (const std::size_t capacity : capacities) {
        ReadyFrameQueue queue(capacity);
        const QueueContext context = Context(1, 1);

        for (std::uint64_t sequence = 0;
             sequence < 2500;
             ++sequence) {
            CHECK(queue.publish(
                      MakeFrame(pixelBuffer, 1, 1, sequence),
                      context) == PublishResult::Published);
            CHECK(queue.size() <= capacity);

            {
                AcquireResult acquired = queue.tryAcquire(context);
                CHECK(acquired.kind == AcquireResultKind::Acquired);
                CHECK(acquired.lease.has_value());
                CHECK(acquired.lease->valid());
                CHECK(acquired.lease->frameLease()->pixelBuffer() != nullptr);
                CHECK(acquired.lease->frameLease()->identity().sequence ==
                      sequence);
            }

            CHECK(queue.size() <= capacity);
        }
    }

    return true;
}

bool TestRepeatedAllLeasedDropAndRelease(
    CVPixelBufferRef pixelBuffer) {
    ReadyFrameQueue queue(3);
    const QueueContext context = Context(2, 4);

    for (std::uint64_t sequence = 0; sequence < 3; ++sequence) {
        CHECK(queue.publish(
                  MakeFrame(pixelBuffer, 2, 4, sequence),
                  context) == PublishResult::Published);
    }

    std::vector<ReadyFrameLease> leases;
    for (int index = 0; index < 3; ++index) {
        AcquireResult acquired = queue.tryAcquire(context);
        CHECK(acquired.kind == AcquireResultKind::Acquired);
        CHECK(acquired.lease.has_value());
        leases.push_back(std::move(*acquired.lease));
    }

    for (std::uint64_t sequence = 3; sequence < 1003; ++sequence) {
        CHECK(queue.publish(
                  MakeFrame(pixelBuffer, 2, 4, sequence),
                  context) == PublishResult::DroppedFullLeased);
        CHECK(queue.size() == queue.capacity());
    }

    for (const auto& lease : leases) {
        CHECK(lease.valid());
        CHECK(lease.frameLease() != nullptr);
        CHECK(lease.frameLease()->pixelBuffer() != nullptr);
    }

    leases.clear();

    CHECK(queue.publish(
              MakeFrame(pixelBuffer, 2, 4, 2000),
              context) == PublishResult::Published);
    CHECK(queue.size() <= queue.capacity());
    return true;
}

bool TestGenerationChurn(CVPixelBufferRef pixelBuffer) {
    ReadyFrameQueue queue(8);

    for (std::uint64_t generation = 1;
         generation <= 500;
         ++generation) {
        const QueueContext current = Context(generation, 1);
        CHECK(queue.publish(
                  MakeFrame(pixelBuffer, generation, 1, generation),
                  current) == PublishResult::Published);

        const AcquireResult wrong =
            queue.tryAcquire(Context(generation + 1, 1));
        CHECK(wrong.kind == AcquireResultKind::NoEligibleFrame);
        CHECK(!wrong.lease.has_value());
        CHECK(queue.size() == 0);
    }

    return true;
}

bool TestEpochChurn(CVPixelBufferRef pixelBuffer) {
    ReadyFrameQueue queue(8);

    for (std::uint64_t epoch = 1; epoch <= 500; ++epoch) {
        const QueueContext current = Context(9, epoch);
        CHECK(queue.publish(
                  MakeFrame(pixelBuffer, 9, epoch, epoch),
                  current) == PublishResult::Published);

        const AcquireResult wrong =
            queue.tryAcquire(Context(9, epoch + 1));
        CHECK(wrong.kind == AcquireResultKind::NoEligibleFrame);
        CHECK(!wrong.lease.has_value());
        CHECK(queue.size() == 0);
    }

    return true;
}

bool TestMinimumSequenceChurn(CVPixelBufferRef pixelBuffer) {
    ReadyFrameQueue queue(8);

    for (std::uint64_t round = 1; round <= 200; ++round) {
        const std::uint64_t epoch = round;
        const QueueContext publishContext = Context(12, epoch);

        for (std::uint64_t sequence = 0; sequence < 8; ++sequence) {
            CHECK(queue.publish(
                      MakeFrame(
                          pixelBuffer,
                          12,
                          epoch,
                          sequence),
                      publishContext) == PublishResult::Published);
        }

        {
            AcquireResult acquired =
                queue.tryAcquire(Context(12, epoch, 6));
            CHECK(acquired.kind == AcquireResultKind::Acquired);
            CHECK(acquired.lease.has_value());
            CHECK(acquired.lease->frameLease()->identity().sequence >= 6);
        }

        CHECK(queue.purgeStale(Context(12, epoch, 8)) >= 1);
        CHECK(queue.size() == 0);
    }

    return true;
}

bool TestOutstandingLeaseSurvivesPurge(
    CVPixelBufferRef pixelBuffer) {
    ReadyFrameQueue queue(1);
    const QueueContext context = Context(20, 30);

    CHECK(queue.publish(
              MakeFrame(pixelBuffer, 20, 30, 7),
              context) == PublishResult::Published);

    AcquireResult acquired = queue.tryAcquire(context);
    CHECK(acquired.kind == AcquireResultKind::Acquired);
    CHECK(acquired.lease.has_value());
    CHECK(acquired.lease->valid());

    CHECK(queue.purgeGeneration(21) == 1);
    CHECK(queue.size() == 0);
    CHECK(acquired.lease->valid());
    CHECK(acquired.lease->frameLease()->pixelBuffer() != nullptr);
    CHECK(acquired.lease->frameLease()->identity().mediaGeneration == 20);
    return true;
}

bool TestFailOpenEmptyAndNoEligible(
    CVPixelBufferRef pixelBuffer) {
    ReadyFrameQueue queue(2);

    for (int iteration = 0; iteration < 10000; ++iteration) {
        const AcquireResult empty =
            queue.tryAcquire(Context(1, 1));
        CHECK(empty.kind == AcquireResultKind::Empty);
        CHECK(!empty.lease.has_value());
    }

    CHECK(queue.publish(
              MakeFrame(pixelBuffer, 1, 1, 1),
              Context(1, 1)) == PublishResult::Published);

    const AcquireResult stale =
        queue.tryAcquire(Context(1, 1, 2));
    CHECK(stale.kind == AcquireResultKind::NoEligibleFrame);
    CHECK(!stale.lease.has_value());
    CHECK(queue.size() == 0);
    return true;
}

bool TestConcurrentProducerConsumer(
    CVPixelBufferRef pixelBuffer) {
    constexpr std::size_t kCapacity = 8;
    constexpr std::uint64_t kOperations = 150000;
    constexpr std::uint64_t kGeneration = 77;
    constexpr std::uint64_t kEpoch = 91;

    ReadyFrameQueue queue(kCapacity);
    const QueueContext context = Context(kGeneration, kEpoch);

    std::atomic<bool> producerDone{false};
    std::atomic<bool> producerFailed{false};
    std::atomic<bool> consumerFailed{false};
    std::atomic<std::size_t> maxSize{0};
    std::atomic<std::uint64_t> acquiredCount{0};
    std::atomic<std::uint64_t> contendedCount{0};

    std::thread producer([&] {
        for (std::uint64_t sequence = 0;
             sequence < kOperations;
             ++sequence) {
            const PublishResult published = queue.publish(
                MakeFrame(
                    pixelBuffer,
                    kGeneration,
                    kEpoch,
                    sequence),
                context);

            if (published != PublishResult::Published &&
                published != PublishResult::DroppedFullLeased) {
                producerFailed.store(true, std::memory_order_release);
                break;
            }

            const std::size_t size = queue.size();
            UpdateMax(maxSize, size);
            if (size > kCapacity) {
                producerFailed.store(true, std::memory_order_release);
                break;
            }
        }
        producerDone.store(true, std::memory_order_release);
    });

    std::thread consumer([&] {
        std::uint64_t emptyAfterDone = 0;
        while (true) {
            AcquireResult acquired = queue.tryAcquire(context);

            if (acquired.kind == AcquireResultKind::Acquired) {
                emptyAfterDone = 0;
                if (!acquired.lease.has_value() ||
                    !acquired.lease->valid() ||
                    acquired.lease->frameLease() == nullptr ||
                    acquired.lease->frameLease()->pixelBuffer() == nullptr ||
                    acquired.lease->frameLease()
                            ->identity().mediaGeneration != kGeneration ||
                    acquired.lease->frameLease()
                            ->identity().timelineEpoch != kEpoch) {
                    consumerFailed.store(true, std::memory_order_release);
                    break;
                }
                acquiredCount.fetch_add(1, std::memory_order_relaxed);
            } else if (acquired.kind == AcquireResultKind::Contended) {
                contendedCount.fetch_add(1, std::memory_order_relaxed);
            } else if (producerDone.load(std::memory_order_acquire)) {
                ++emptyAfterDone;
                if (emptyAfterDone >= 32) {
                    break;
                }
            }
        }
    });

    producer.join();
    consumer.join();

    CHECK(!producerFailed.load(std::memory_order_acquire));
    CHECK(!consumerFailed.load(std::memory_order_acquire));
    CHECK(maxSize.load(std::memory_order_acquire) <= kCapacity);
    CHECK(acquiredCount.load(std::memory_order_acquire) > 0);
    CHECK(contendedCount.load(std::memory_order_acquire) > 0);
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
    SharedPixelBuffer buffer;

    Run("thousands of publish/acquire cycles",
        [&] { return TestThousandsOfCycles(buffer.get()); });
    Run("repeated all-leased drop and release",
        [&] { return TestRepeatedAllLeasedDropAndRelease(buffer.get()); });
    Run("generation churn",
        [&] { return TestGenerationChurn(buffer.get()); });
    Run("epoch churn",
        [&] { return TestEpochChurn(buffer.get()); });
    Run("minimumSequence churn",
        [&] { return TestMinimumSequenceChurn(buffer.get()); });
    Run("outstanding lease survives purge",
        [&] { return TestOutstandingLeaseSurvivesPurge(buffer.get()); });
    Run("fail-open empty/no-eligible",
        [&] { return TestFailOpenEmptyAndNoEligible(buffer.get()); });
    Run("concurrent producer/consumer",
        [&] { return TestConcurrentProducerConsumer(buffer.get()); });

    std::cout << "Stage D2 queue stress tests run: " << gTestsRun
              << ", failures: " << gFailures << std::endl;
    return gFailures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
