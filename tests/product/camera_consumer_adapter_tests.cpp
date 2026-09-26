#include "CameraConsumerAdapter.h"
#include "ControlStateCache.h"
#include "PreparedFrame.h"
#include "ReadyFrameQueue.h"

#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

#include <cstdlib>
#include <functional>
#include <iostream>
#include <string>

namespace {

using namespace vcam::frame_engine;
using namespace vcam::product;

int gTests = 0;
int gFailures = 0;

#define CHECK(condition) do { if (!(condition)) {     std::cerr << "CHECK failed at " << __FILE__ << ":" << __LINE__               << ": " #condition << std::endl; return false; } } while (false)

CVPixelBufferRef MakeBuffer(
    std::size_t width = 64,
    std::size_t height = 48,
    OSType format =
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
    CVPixelBufferRef buffer = nullptr;
    if (CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            format,
            nullptr,
            &buffer) != kCVReturnSuccess) {
        return nullptr;
    }
    return buffer;
}

PreparedFrame MakeFrame(
    std::uint64_t sequence,
    std::uint64_t generation,
    std::uint64_t epoch,
    CVPixelBufferRef buffer) {
    FrameIdentity identity{
        sequence,
        generation,
        epoch,
        0
    };
    FrameTiming timing;
    timing.sourcePTS =
        CMTimeMake(
            static_cast<std::int64_t>(sequence),
            30);
    timing.duration =
        CMTimeMake(1, 30);

    return PreparedFrame(
        buffer,
        identity,
        timing,
        OrientationState::Normalized,
        FrameValidity::Ready);
}

QueueContext Context(
    std::uint64_t generation,
    std::uint64_t epoch) {
    QueueContext context;
    context.currentMediaGeneration =
        generation;
    context.currentTimelineEpoch =
        epoch;
    return context;
}

bool Publish(
    ReadyFrameQueue& queue,
    std::uint64_t sequence,
    std::uint64_t generation,
    std::uint64_t epoch) {
    CVPixelBufferRef buffer =
        MakeBuffer();
    if (buffer == nullptr) {
        return false;
    }

    PreparedFrame frame =
        MakeFrame(
            sequence,
            generation,
            epoch,
            buffer);
    CVPixelBufferRelease(buffer);

    return queue.publish(
               std::move(frame),
               Context(generation, epoch)) ==
           PublishResult::Published;
}

bool TestDefaultOffReturnsOriginal() {
    ReadyFrameQueue queue(4);
    CHECK(Publish(queue, 0, 1, 1));

    CameraConsumerAdapter adapter;
    adapter.bindQueue(
        &queue,
        1,
        1,
        true);

    CVPixelBufferRef original =
        MakeBuffer();
    CHECK(original != nullptr);

    const auto result =
        adapter.decide(original);

    CHECK(result.kind ==
          CameraDecisionKind::Original);
    CHECK(result.pixelBuffer == original);
    CHECK(result.reason ==
          CameraFailOpenReason::Disabled);

    CVPixelBufferRelease(original);
    return true;
}

bool TestEnabledWithoutQueueReturnsOriginal() {
    CameraConsumerAdapter adapter;
    adapter.setEnabled(true);

    CVPixelBufferRef original =
        MakeBuffer();
    CHECK(original != nullptr);

    const auto result =
        adapter.decide(original);

    CHECK(result.kind ==
          CameraDecisionKind::Original);
    CHECK(result.reason ==
          CameraFailOpenReason::
              ProducerUnavailable);

    CVPixelBufferRelease(original);
    return true;
}

bool TestEligibleFrameSelectsVirtual() {
    ReadyFrameQueue queue(4);
    CHECK(Publish(queue, 0, 2, 3));

    CameraConsumerAdapter adapter;
    adapter.setEnabled(true);
    adapter.bindQueue(
        &queue,
        2,
        3,
        true);

    CVPixelBufferRef original =
        MakeBuffer();
    CHECK(original != nullptr);

    const auto result =
        adapter.decide(original);

    CHECK(result.kind ==
          CameraDecisionKind::Virtual);
    CHECK(result.pixelBuffer != nullptr);
    CHECK(result.pixelBuffer != original);
    CHECK(adapter.pinnedLeaseCount() == 1);

    CVPixelBufferRelease(original);
    return true;
}

bool TestEmptyQueueFailsOpen() {
    ReadyFrameQueue queue(4);
    CameraConsumerAdapter adapter;
    adapter.setEnabled(true);
    adapter.bindQueue(
        &queue,
        1,
        1,
        true);

    CVPixelBufferRef original =
        MakeBuffer();
    CHECK(original != nullptr);

    const auto result =
        adapter.decide(original);

    CHECK(result.kind ==
          CameraDecisionKind::Original);
    CHECK(result.reason ==
          CameraFailOpenReason::
              EmptyOrNoEligibleFrame);

    CVPixelBufferRelease(original);
    return true;
}

bool TestStaleGenerationFailsOpen() {
    ReadyFrameQueue queue(4);
    CHECK(Publish(queue, 0, 4, 1));

    CameraConsumerAdapter adapter;
    adapter.setEnabled(true);
    adapter.bindQueue(
        &queue,
        5,
        1,
        true);

    CVPixelBufferRef original =
        MakeBuffer();
    CHECK(original != nullptr);

    const auto result =
        adapter.decide(original);

    CHECK(result.kind ==
          CameraDecisionKind::Original);

    CVPixelBufferRelease(original);
    return true;
}

bool TestStaleEpochFailsOpen() {
    ReadyFrameQueue queue(4);
    CHECK(Publish(queue, 0, 4, 2));

    CameraConsumerAdapter adapter;
    adapter.setEnabled(true);
    adapter.bindQueue(
        &queue,
        4,
        3,
        true);

    CVPixelBufferRef original =
        MakeBuffer();
    CHECK(original != nullptr);

    CHECK(adapter.decide(original).kind ==
          CameraDecisionKind::Original);

    CVPixelBufferRelease(original);
    return true;
}

bool TestProducerFailureFailsOpen() {
    ReadyFrameQueue queue(4);
    CHECK(Publish(queue, 0, 1, 1));

    CameraConsumerAdapter adapter;
    adapter.setEnabled(true);
    adapter.bindQueue(
        &queue,
        1,
        1,
        false);

    CVPixelBufferRef original =
        MakeBuffer();
    CHECK(original != nullptr);

    const auto result =
        adapter.decide(original);

    CHECK(result.kind ==
          CameraDecisionKind::Original);
    CHECK(result.reason ==
          CameraFailOpenReason::
              ProducerUnavailable);

    CVPixelBufferRelease(original);
    return true;
}

bool TestDisableDuringActiveReturnsOriginal() {
    ReadyFrameQueue queue(4);
    CHECK(Publish(queue, 0, 1, 1));

    CameraConsumerAdapter adapter;
    adapter.setEnabled(true);
    adapter.bindQueue(
        &queue,
        1,
        1,
        true);

    CVPixelBufferRef original =
        MakeBuffer();
    CHECK(original != nullptr);

    CHECK(adapter.decide(original).kind ==
          CameraDecisionKind::Virtual);

    CHECK(Publish(queue, 1, 1, 1));
    adapter.setEnabled(false);

    CHECK(adapter.decide(original).kind ==
          CameraDecisionKind::Original);

    CVPixelBufferRelease(original);
    return true;
}

bool TestRepeatedToggleSafe() {
    ReadyFrameQueue queue(8);
    CameraConsumerAdapter adapter;
    adapter.bindQueue(
        &queue,
        7,
        9,
        true);

    CVPixelBufferRef original =
        MakeBuffer();
    CHECK(original != nullptr);

    for (std::uint64_t i = 0; i < 20; ++i) {
        adapter.setEnabled((i % 2) == 0);
        CHECK(Publish(queue, i, 7, 9));

        const auto result =
            adapter.decide(original);

        if ((i % 2) == 0) {
            CHECK(result.kind ==
                  CameraDecisionKind::Virtual);
        } else {
            CHECK(result.kind ==
                  CameraDecisionKind::Original);
        }
    }

    CHECK(adapter.pinnedLeaseCount() <=
          CameraConsumerAdapter::
              kPinnedLeaseCapacity);

    CVPixelBufferRelease(original);
    return true;
}

bool TestGeometryMismatchFailsOpen() {
    ReadyFrameQueue queue(4);
    CHECK(Publish(queue, 0, 1, 1));

    CameraConsumerAdapter adapter;
    adapter.setEnabled(true);
    adapter.bindQueue(
        &queue,
        1,
        1,
        true);

    CVPixelBufferRef original =
        MakeBuffer(128, 72);
    CHECK(original != nullptr);

    const auto result =
        adapter.decide(original);

    CHECK(result.kind ==
          CameraDecisionKind::Original);
    CHECK(result.reason ==
          CameraFailOpenReason::
              GeometryMismatch);

    CVPixelBufferRelease(original);
    return true;
}

bool TestPinnedLeaseSurvivesQueueDestruction() {
    CameraConsumerAdapter adapter;
    adapter.setEnabled(true);

    CVPixelBufferRef original =
        MakeBuffer();
    CHECK(original != nullptr);

    CVPixelBufferRef selected = nullptr;
    {
        ReadyFrameQueue queue(4);
        CHECK(Publish(queue, 0, 1, 1));
        adapter.bindQueue(
            &queue,
            1,
            1,
            true);

        const auto result =
            adapter.decide(original);
        CHECK(result.kind ==
              CameraDecisionKind::Virtual);

        selected = result.pixelBuffer;
        CHECK(selected != nullptr);
        CHECK(CVPixelBufferGetWidth(
                  selected) == 64);

        adapter.unbindQueue();
    }

    CHECK(adapter.pinnedLeaseCount() == 1);
    CHECK(CVPixelBufferGetHeight(
              selected) == 48);

    CVPixelBufferRelease(original);
    return true;
}

bool TestPinnedStorageBounded() {
    CameraConsumerAdapter adapter;
    adapter.setEnabled(true);

    CVPixelBufferRef original =
        MakeBuffer();
    CHECK(original != nullptr);

    for (std::uint64_t i = 0;
         i < 12;
         ++i) {
        ReadyFrameQueue queue(2);
        CHECK(Publish(
            queue,
            i,
            i + 1,
            1));

        adapter.bindQueue(
            &queue,
            i + 1,
            1,
            true);

        CHECK(adapter.decide(original).kind ==
              CameraDecisionKind::Virtual);

        adapter.unbindQueue();
        CHECK(adapter.pinnedLeaseCount() <=
              CameraConsumerAdapter::
                  kPinnedLeaseCapacity);
    }

    CHECK(adapter.pinnedLeaseCount() ==
          CameraConsumerAdapter::
              kPinnedLeaseCapacity);

    CVPixelBufferRelease(original);
    return true;
}

bool TestControlCacheRefreshIsMemoryOnlyFastPath() {
    ControlStateCache cache;
    ProductControlSnapshot snapshot;
    snapshot.enabled = true;
    snapshot.mediaKind =
        ProductMediaKind::Photo;
    snapshot.mediaPath =
        "/tmp/test.png";
    snapshot.selectionGeneration = 10;

    cache.replace(snapshot);

    CHECK(cache.enabledFast());
    CHECK(cache.refreshCount() == 1);
    CHECK(cache.snapshot().mediaPath ==
          snapshot.mediaPath);

    snapshot.enabled = false;
    cache.replace(snapshot);

    CHECK(!cache.enabledFast());
    CHECK(cache.refreshCount() == 2);
    return true;
}

void Run(
    const char* name,
    const std::function<bool()>& fn) {
    ++gTests;
    if (!fn()) {
        ++gFailures;
        std::cerr << "[FAIL] "
                  << name << std::endl;
    } else {
        std::cout << "[PASS] "
                  << name << std::endl;
    }
}

}  // namespace

int main() {
    Run("default OFF returns original",
        TestDefaultOffReturnsOriginal);
    Run("ON without queue returns original",
        TestEnabledWithoutQueueReturnsOriginal);
    Run("eligible frame selects virtual",
        TestEligibleFrameSelectsVirtual);
    Run("empty queue returns original",
        TestEmptyQueueFailsOpen);
    Run("stale generation returns original",
        TestStaleGenerationFailsOpen);
    Run("stale epoch returns original",
        TestStaleEpochFailsOpen);
    Run("producer failure returns original",
        TestProducerFailureFailsOpen);
    Run("disable during active production",
        TestDisableDuringActiveReturnsOriginal);
    Run("repeated toggles are safe",
        TestRepeatedToggleSafe);
    Run("geometry mismatch returns original",
        TestGeometryMismatchFailsOpen);
    Run("pinned lease survives queue destruction",
        TestPinnedLeaseSurvivesQueueDestruction);
    Run("pinned storage remains bounded",
        TestPinnedStorageBounded);
    Run("control cache refresh",
        TestControlCacheRefreshIsMemoryOnlyFastPath);

    std::cout << "Camera consumer tests run: "
              << gTests
              << ", failures: "
              << gFailures
              << std::endl;

    return gFailures == 0
        ? EXIT_SUCCESS
        : EXIT_FAILURE;
}
