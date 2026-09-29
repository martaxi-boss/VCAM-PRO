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

bool BindBlack(
    CameraConsumerAdapter& adapter,
    std::size_t width = 64,
    std::size_t height = 48,
    OSType format =
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
    CVPixelBufferRef black =
        MakeBuffer(
            width,
            height,
            format);
    if (black == nullptr) {
        return false;
    }

    const bool result =
        adapter.bindBlackFallback(
            black);
    CVPixelBufferRelease(black);
    return result;
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
    std::uint64_t epoch,
    std::size_t width = 64,
    std::size_t height = 48,
    OSType format =
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
    CVPixelBufferRef buffer =
        MakeBuffer(
            width,
            height,
            format);
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

bool TestOffWithoutMediaReturnsOriginal() {
    CameraConsumerAdapter adapter;
    CHECK(BindBlack(adapter));

    CVPixelBufferRef original =
        MakeBuffer();
    CHECK(original != nullptr);

    const auto result =
        adapter.decide(original);

    CHECK(result.kind ==
          CameraDecisionKind::Original);
    CHECK(result.source ==
          CameraDecisionSource::Original);
    CHECK(result.pixelBuffer == original);
    CHECK(result.reason ==
          CameraFailOpenReason::Disabled);

    CVPixelBufferRelease(original);
    return true;
}

bool TestOffWithMediaReadyReturnsOriginal() {
    ReadyFrameQueue queue(4);
    CHECK(Publish(queue, 0, 1, 1));

    CameraConsumerAdapter adapter;
    CHECK(BindBlack(adapter));
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
    CHECK(result.source ==
          CameraDecisionSource::Original);
    CHECK(result.reason ==
          CameraFailOpenReason::Disabled);
    CHECK(queue.size() == 1);

    CVPixelBufferRelease(original);
    return true;
}

bool TestOnWithoutMediaUsesBlack() {
    CameraConsumerAdapter adapter;
    adapter.setEnabled(true);
    CHECK(BindBlack(adapter));

    CVPixelBufferRef original =
        MakeBuffer();
    CHECK(original != nullptr);

    const auto result =
        adapter.decide(original);

    CHECK(result.kind ==
          CameraDecisionKind::Virtual);
    CHECK(result.source ==
          CameraDecisionSource::BlackFallback);
    CHECK(result.reason ==
          CameraFailOpenReason::None);
    CHECK(result.mediaFailureReason ==
          CameraFailOpenReason::ProducerUnavailable);
    CHECK(result.pixelBuffer != nullptr);
    CHECK(result.pixelBuffer != original);
    CHECK(adapter.blackVirtualDecisionCount() == 1);
    CHECK(adapter.virtualDecisionCount() == 1);

    CVPixelBufferRelease(original);
    return true;
}

bool TestEligibleFramePrefersPreparedMedia() {
    ReadyFrameQueue queue(4);
    CHECK(Publish(queue, 0, 2, 3));

    CameraConsumerAdapter adapter;
    adapter.setEnabled(true);
    CHECK(BindBlack(adapter));
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
    CHECK(result.source ==
          CameraDecisionSource::PreparedMedia);
    CHECK(result.reason ==
          CameraFailOpenReason::None);
    CHECK(result.pixelBuffer != nullptr);
    CHECK(result.pixelBuffer != original);
    CHECK(adapter.mediaVirtualDecisionCount() == 1);
    CHECK(adapter.blackVirtualDecisionCount() == 0);
    CHECK(adapter.pinnedLeaseCount() == 1);

    CVPixelBufferRelease(original);
    return true;
}

bool TestEmptyQueueUsesBlack() {
    ReadyFrameQueue queue(4);

    CameraConsumerAdapter adapter;
    adapter.setEnabled(true);
    CHECK(BindBlack(adapter));
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

    CHECK(result.source ==
          CameraDecisionSource::BlackFallback);
    CHECK(result.mediaFailureReason ==
          CameraFailOpenReason::EmptyOrNoEligibleFrame);

    CVPixelBufferRelease(original);
    return true;
}

bool TestStaleGenerationUsesBlack() {
    ReadyFrameQueue queue(4);
    CHECK(Publish(queue, 0, 4, 1));

    CameraConsumerAdapter adapter;
    adapter.setEnabled(true);
    CHECK(BindBlack(adapter));
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

    CHECK(result.source ==
          CameraDecisionSource::BlackFallback);
    CHECK(result.mediaFailureReason ==
          CameraFailOpenReason::EmptyOrNoEligibleFrame);

    CVPixelBufferRelease(original);
    return true;
}

bool TestStaleEpochUsesBlack() {
    ReadyFrameQueue queue(4);
    CHECK(Publish(queue, 0, 4, 2));

    CameraConsumerAdapter adapter;
    adapter.setEnabled(true);
    CHECK(BindBlack(adapter));
    adapter.bindQueue(
        &queue,
        4,
        3,
        true);

    CVPixelBufferRef original =
        MakeBuffer();
    CHECK(original != nullptr);

    const auto result =
        adapter.decide(original);

    CHECK(result.source ==
          CameraDecisionSource::BlackFallback);
    CHECK(result.mediaFailureReason ==
          CameraFailOpenReason::EmptyOrNoEligibleFrame);

    CVPixelBufferRelease(original);
    return true;
}

bool TestProducerFailureUsesBlack() {
    ReadyFrameQueue queue(4);
    CHECK(Publish(queue, 0, 1, 1));

    CameraConsumerAdapter adapter;
    adapter.setEnabled(true);
    CHECK(BindBlack(adapter));
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

    CHECK(result.source ==
          CameraDecisionSource::BlackFallback);
    CHECK(result.mediaFailureReason ==
          CameraFailOpenReason::ProducerUnavailable);

    CVPixelBufferRelease(original);
    return true;
}

bool TestMediaGeometryMismatchUsesBlack() {
    ReadyFrameQueue queue(4);
    CHECK(Publish(queue, 0, 1, 1));

    CameraConsumerAdapter adapter;
    adapter.setEnabled(true);
    CHECK(BindBlack(
        adapter,
        128,
        72));
    adapter.bindQueue(
        &queue,
        1,
        1,
        true);

    CVPixelBufferRef original =
        MakeBuffer(
            128,
            72);
    CHECK(original != nullptr);

    const auto result =
        adapter.decide(original);

    CHECK(result.kind ==
          CameraDecisionKind::Virtual);
    CHECK(result.source ==
          CameraDecisionSource::BlackFallback);
    CHECK(result.mediaFailureReason ==
          CameraFailOpenReason::GeometryMismatch);

    CVPixelBufferRelease(original);
    return true;
}

bool TestClearMediaReturnsBlack() {
    ReadyFrameQueue queue(4);
    CHECK(Publish(queue, 0, 1, 1));

    CameraConsumerAdapter adapter;
    adapter.setEnabled(true);
    CHECK(BindBlack(adapter));
    adapter.bindQueue(
        &queue,
        1,
        1,
        true);

    CVPixelBufferRef original =
        MakeBuffer();
    CHECK(original != nullptr);

    CHECK(adapter.decide(original).source ==
          CameraDecisionSource::PreparedMedia);

    adapter.unbindQueue();

    const auto afterClear =
        adapter.decide(original);

    CHECK(afterClear.source ==
          CameraDecisionSource::BlackFallback);
    CHECK(afterClear.mediaFailureReason ==
          CameraFailOpenReason::ProducerUnavailable);

    CVPixelBufferRelease(original);
    return true;
}

bool TestDisableAfterVirtualReturnsOriginal() {
    CameraConsumerAdapter adapter;
    CHECK(BindBlack(adapter));
    adapter.setEnabled(true);

    CVPixelBufferRef original =
        MakeBuffer();
    CHECK(original != nullptr);

    CHECK(adapter.decide(original).source ==
          CameraDecisionSource::BlackFallback);

    adapter.setEnabled(false);

    const auto disabled =
        adapter.decide(original);

    CHECK(disabled.kind ==
          CameraDecisionKind::Original);
    CHECK(disabled.source ==
          CameraDecisionSource::Original);
    CHECK(disabled.pixelBuffer == original);
    CHECK(disabled.reason ==
          CameraFailOpenReason::Disabled);

    CVPixelBufferRelease(original);
    return true;
}

bool TestOffThenOnRestoresVirtualOwnership() {
    CameraConsumerAdapter adapter;
    CHECK(BindBlack(adapter));

    CVPixelBufferRef original =
        MakeBuffer();
    CHECK(original != nullptr);

    CHECK(adapter.decide(original).source ==
          CameraDecisionSource::Original);

    adapter.setEnabled(true);

    CHECK(adapter.decide(original).source ==
          CameraDecisionSource::BlackFallback);

    CVPixelBufferRelease(original);
    return true;
}

bool TestRepeatedToggleSafe() {
    ReadyFrameQueue queue(8);
    CameraConsumerAdapter adapter;
    CHECK(BindBlack(adapter));
    adapter.bindQueue(
        &queue,
        7,
        9,
        true);

    CVPixelBufferRef original =
        MakeBuffer();
    CHECK(original != nullptr);

    for (std::uint64_t i = 0;
         i < 20;
         ++i) {
        adapter.setEnabled(
            (i % 2) == 0);
        CHECK(Publish(
            queue,
            i,
            7,
            9));

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
    CHECK(adapter.blackFallbackCacheCount() <=
          CameraConsumerAdapter::
              kBlackFallbackCapacity);

    CVPixelBufferRelease(original);
    return true;
}

bool TestSupportedNoBlackUsesOwnershipGuard() {
    CameraConsumerAdapter adapter;
    adapter.setEnabled(true);

    CVPixelBufferRef original =
        MakeBuffer();
    CHECK(original != nullptr);

    const auto result =
        adapter.decide(original);

    CHECK(result.kind ==
          CameraDecisionKind::Virtual);
    CHECK(result.source ==
          CameraDecisionSource::
              InPlaceBlackOwnershipGuard);
    CHECK(result.pixelBuffer == original);
    CHECK(result.reason ==
          CameraFailOpenReason::None);
    CHECK(result.mediaFailureReason ==
          CameraFailOpenReason::ProducerUnavailable);
    CHECK(adapter.inPlaceBlackGuardDecisionCount() == 1);
    CHECK(adapter.emergencyOriginalDecisionCount() == 0);
    CHECK(adapter.enabledSupportedOriginalDecisionCount() == 0);

    CVPixelBufferRelease(original);
    return true;
}

bool TestUnsupportedFormatIsExplicit() {
    CameraConsumerAdapter adapter;
    adapter.setEnabled(true);

    CVPixelBufferRef original =
        MakeBuffer(
            64,
            48,
            kCVPixelFormatType_32BGRA);
    CHECK(original != nullptr);

    const auto result =
        adapter.decide(original);

    CHECK(result.kind ==
          CameraDecisionKind::Original);
    CHECK(result.source ==
          CameraDecisionSource::Original);
    CHECK(result.reason ==
          CameraFailOpenReason::UnsupportedPixelFormat);
    CHECK(adapter.unsupportedFormatDecisionCount() == 1);
    CHECK(adapter.enabledSupportedOriginalDecisionCount() == 0);

    CVPixelBufferRelease(original);
    return true;
}

bool TestStaticPhotoLeasePersistsAcrossCallbacks() {
    ReadyFrameQueue queue(4);
    CHECK(Publish(queue, 0, 1, 1));

    CameraConsumerAdapter adapter;
    adapter.setEnabled(true);
    adapter.bindQueue(
        &queue,
        1,
        1,
        true,
        true);

    CVPixelBufferRef original =
        MakeBuffer();
    CHECK(original != nullptr);

    const auto first =
        adapter.decide(original);
    CHECK(first.source ==
          CameraDecisionSource::PreparedMedia);
    CHECK(first.pixelBuffer != nullptr);

    adapter.updateContext(
        1,
        1,
        false,
        true);

    for (int callback = 0;
         callback < 16;
         ++callback) {
        const auto repeated =
            adapter.decide(original);
        CHECK(repeated.source ==
              CameraDecisionSource::PreparedMedia);
        CHECK(repeated.pixelBuffer ==
              first.pixelBuffer);
    }

    CHECK(adapter.enabledSupportedOriginalDecisionCount() == 0);

    adapter.unbindQueue();
    CVPixelBufferRelease(original);
    return true;
}

bool TestStaticPhotoVariantsBoundedAndEvictSafely() {
    ReadyFrameQueue queue(8);

    CameraConsumerAdapter adapter;
    adapter.setEnabled(true);
    adapter.bindQueue(
        &queue,
        11,
        5,
        true,
        true,
        7);

    constexpr std::size_t capacity =
        CameraConsumerAdapter::
            kPhotoVariantCapacity;

    auto geometryFor =
        [](std::size_t index) {
            struct Geometry {
                std::size_t width;
                std::size_t height;
                OSType format;
            };

            const std::size_t width =
                64 + index * 8;
            const std::size_t height =
                48 + index * 6;
            const OSType format =
                (index % 2) == 0
                    ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                    : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
            return Geometry{
                width,
                height,
                format,
            };
        };

    for (std::size_t index = 0;
         index < capacity + 1;
         ++index) {
        const auto geometry =
            geometryFor(index);

        CHECK(Publish(
            queue,
            index,
            11,
            5,
            geometry.width,
            geometry.height,
            geometry.format));

        CVPixelBufferRef original =
            MakeBuffer(
                geometry.width,
                geometry.height,
                geometry.format);
        CHECK(original != nullptr);

        const auto decision =
            adapter.decide(original);
        CHECK(decision.source ==
              CameraDecisionSource::PreparedMedia);

        CVPixelBufferRelease(original);

        CHECK(adapter.photoVariantCount() <=
              capacity);
    }

    CHECK(adapter.photoVariantCount() ==
          capacity);

    const auto newest =
        geometryFor(capacity);
    CHECK(adapter.hasReusablePhotoVariant(
        newest.width,
        newest.height,
        newest.format,
        11,
        5,
        7));

    const auto oldest =
        geometryFor(0);
    CHECK(!adapter.hasReusablePhotoVariant(
        oldest.width,
        oldest.height,
        oldest.format,
        11,
        5,
        7));

    const auto recentGeometry =
        geometryFor(capacity - 1);
    CVPixelBufferRef recent =
        MakeBuffer(
            recentGeometry.width,
            recentGeometry.height,
            recentGeometry.format);
    CHECK(recent != nullptr);
    CHECK(adapter.decide(recent).source ==
          CameraDecisionSource::PreparedMedia);
    CVPixelBufferRelease(recent);

    ReadyFrameQueue replacementQueue(2);
    adapter.bindQueue(
        &replacementQueue,
        11,
        5,
        false,
        true,
        7);

    recent =
        MakeBuffer(
            recentGeometry.width,
            recentGeometry.height,
            recentGeometry.format);
    CHECK(recent != nullptr);
    CHECK(adapter.decide(recent).source ==
          CameraDecisionSource::PreparedMedia);
    CVPixelBufferRelease(recent);

    adapter.updateContext(
        11,
        5,
        false,
        true,
        8);
    CHECK(adapter.photoVariantCount() == 0);

    return true;
}

bool TestPinnedLeaseSurvivesQueueDestruction() {
    CameraConsumerAdapter adapter;
    adapter.setEnabled(true);
    CHECK(BindBlack(adapter));

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
        CHECK(result.source ==
              CameraDecisionSource::PreparedMedia);

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
    CHECK(BindBlack(adapter));

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

        CHECK(adapter.decide(original).source ==
              CameraDecisionSource::PreparedMedia);

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

bool TestBlackFallbackCacheBounded() {
    CameraConsumerAdapter adapter;

    for (std::size_t index = 0;
         index < CameraConsumerAdapter::
                     kBlackFallbackCapacity;
         ++index) {
        CVPixelBufferRef buffer =
            MakeBuffer(
                64 + index * 2,
                48 + index * 2);
        CHECK(buffer != nullptr);
        CHECK(adapter.bindBlackFallback(
            buffer));
        CVPixelBufferRelease(buffer);
    }

    CHECK(adapter.blackFallbackCacheCount() ==
          CameraConsumerAdapter::
              kBlackFallbackCapacity);

    CVPixelBufferRef overflow =
        MakeBuffer(
            80,
            64);
    CHECK(overflow != nullptr);
    CHECK(!adapter.bindBlackFallback(
        overflow));
    CVPixelBufferRelease(overflow);

    CHECK(adapter.blackFallbackCacheCount() ==
          CameraConsumerAdapter::
              kBlackFallbackCapacity);

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
    Run("VCAM OFF no media returns original",
        TestOffWithoutMediaReturnsOriginal);
    Run("VCAM OFF media ready returns original",
        TestOffWithMediaReadyReturnsOriginal);
    Run("VCAM ON no media uses black",
        TestOnWithoutMediaUsesBlack);
    Run("eligible media replaces black",
        TestEligibleFramePrefersPreparedMedia);
    Run("empty queue uses black",
        TestEmptyQueueUsesBlack);
    Run("stale generation uses black",
        TestStaleGenerationUsesBlack);
    Run("stale epoch uses black",
        TestStaleEpochUsesBlack);
    Run("producer unavailable uses black",
        TestProducerFailureUsesBlack);
    Run("media geometry mismatch uses black",
        TestMediaGeometryMismatchUsesBlack);
    Run("clear media returns black",
        TestClearMediaReturnsBlack);
    Run("VCAM disable restores original",
        TestDisableAfterVirtualReturnsOriginal);
    Run("VCAM OFF to ON restores ownership",
        TestOffThenOnRestoresVirtualOwnership);
    Run("repeated toggles remain safe",
        TestRepeatedToggleSafe);
    Run("supported no-black uses in-place ownership guard",
        TestSupportedNoBlackUsesOwnershipGuard);
    Run("unsupported format is explicit",
        TestUnsupportedFormatIsExplicit);
    Run("static photo lease persists across callbacks",
        TestStaticPhotoLeasePersistsAcrossCallbacks);
    Run("static photo variants bounded and evict safely",
        TestStaticPhotoVariantsBoundedAndEvictSafely);
    Run("pinned lease survives queue destruction",
        TestPinnedLeaseSurvivesQueueDestruction);
    Run("pinned storage remains bounded",
        TestPinnedStorageBounded);
    Run("black fallback cache remains bounded",
        TestBlackFallbackCacheBounded);
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
