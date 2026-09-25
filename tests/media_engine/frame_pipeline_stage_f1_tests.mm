#include "FrameEngineState.h"
#include "FrameNormalizer.h"
#include "FramePipelinePump.h"
#include "FrameTimelineScheduler.h"
#include "FrameTransformer.h"
#include "LocalVideoReader.h"
#include "ReadyFrameQueue.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <functional>
#include <iostream>
#include <new>
#include <optional>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace vcam::media_engine {

class FramePipelinePumpStageF1TestAccess final {
public:
    static void installTimedSource(
        FramePipelinePump& pump,
        std::function<ReadResult()> read,
        std::function<std::optional<SourceVideoInfo>()> sourceInfo) {
        pump.timedReadCallback_ = std::move(read);
        pump.timedSourceInfoCallback_ = std::move(sourceInfo);
    }

    static bool claimTimedProducer(FramePipelinePump& pump) {
        return !pump.timedProducerActive_.test_and_set(
            std::memory_order_acquire);
    }

    static void releaseTimedProducer(FramePipelinePump& pump) {
        pump.timedProducerActive_.clear(std::memory_order_release);
    }

    static void installThrowingTransformer(FramePipelinePump& pump) {
        pump.transformCallback_ =
            [](
                const frame_engine::PreparedFrame&,
                const SourceGeometry&,
                const NormalizationTarget&,
                std::uint64_t,
                std::uint64_t) -> FrameTransformResult {
                throw std::bad_alloc();
            };
    }

    static FramePipelinePumpResult prepare(
        FramePipelinePump& pump,
        frame_engine::PreparedFrame frame,
        const SourceVideoInfo& info,
        std::uint64_t generation,
        std::uint64_t epoch) {
        return pump.prepareFrame(
                       std::move(frame),
                       info,
                       generation,
                       epoch)
            .result;
    }
};

}  // namespace vcam::media_engine

namespace {

using namespace vcam::frame_engine;
using namespace vcam::media_engine;

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

PreparedFrame MakeFrame(
    std::uint64_t sequence,
    std::uint64_t generation,
    std::uint64_t epoch,
    std::uint64_t loop,
    CMTime sourcePTS,
    CMTime duration,
    std::size_t width = 8,
    std::size_t height = 8,
    OSType format =
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
    CVPixelBufferRef pixelBuffer = nullptr;
    if (CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            format,
            nullptr,
            &pixelBuffer) != kCVReturnSuccess ||
        pixelBuffer == nullptr) {
        throw std::runtime_error(
            "Unable to create Stage F1 pipeline fixture.");
    }

    if (CVPixelBufferGetPlaneCount(pixelBuffer) != 2 ||
        CVPixelBufferLockBaseAddress(pixelBuffer, 0) !=
            kCVReturnSuccess) {
        CVPixelBufferRelease(pixelBuffer);
        throw std::runtime_error(
            "Unable to lock Stage F1 pipeline fixture.");
    }

    auto* yBase = static_cast<std::uint8_t*>(
        CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0));
    auto* cbCrBase = static_cast<std::uint8_t*>(
        CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1));

    const std::size_t yRowBytes =
        CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
    const std::size_t cbCrRowBytes =
        CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);

    for (std::size_t row = 0; row < height; ++row) {
        std::fill_n(
            yBase + row * yRowBytes,
            width,
            static_cast<std::uint8_t>(64 + sequence * 8));
    }

    for (std::size_t row = 0; row < height / 2; ++row) {
        auto* line = cbCrBase + row * cbCrRowBytes;
        for (std::size_t x = 0; x < width; x += 2) {
            line[x] = 128;
            line[x + 1] = 128;
        }
    }

    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

    FrameIdentity identity{sequence, generation, epoch, loop};
    FrameTiming timing;
    timing.sourcePTS = sourcePTS;
    timing.presentationTimestamp = kCMTimeInvalid;
    timing.duration = duration;
    timing.producedAtHostTime = std::nullopt;

    PreparedFrame frame(
        pixelBuffer,
        identity,
        timing,
        OrientationState::SourceNotNormalized,
        FrameValidity::Ready);

    CVPixelBufferRelease(pixelBuffer);
    return frame;
}

SourceVideoInfo SourceInfo(
    std::size_t width = 8,
    std::size_t height = 8,
    OSType format =
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
    SourceVideoInfo info;
    info.naturalSize = CGSizeMake(
        static_cast<CGFloat>(width),
        static_cast<CGFloat>(height));
    info.preferredTransform = CGAffineTransformIdentity;
    info.duration = CMTimeMake(1, 1);
    info.outputPixelFormat = format;
    return info;
}

NormalizationTarget Target(
    std::size_t width = 8,
    std::size_t height = 8,
    OSType format =
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
    NormalizationTarget target;
    target.width = width;
    target.height = height;
    target.pixelFormat = format;
    target.orientation =
        OrientationRequirement::UprightIdentityTransform;
    target.colorMetadata = ColorMetadataPolicy::PreserveSource;
    return target;
}

QueueContext Context(const FrameEngineState& state) {
    QueueContext context;
    context.currentMediaGeneration = state.mediaGeneration();
    context.currentTimelineEpoch = state.timelineEpoch();
    context.minimumSequence = std::nullopt;
    return context;
}

bool PrimeState(FrameEngineState& state) {
    state.selectOrReplaceMedia();
    return state.start();
}

class FakeTimedSource final {
public:
    explicit FakeTimedSource(SourceVideoInfo info)
        : info_(info) {}

    void add(PreparedFrame frame) {
        frames_.push_back(std::move(frame));
    }

    ReadResult read() {
        ++readCalls;

        if (index_ >= frames_.size()) {
            ReadResult result;
            result.kind = ReadResultKind::EndOfStream;
            return result;
        }

        ReadResult result;
        result.kind = ReadResultKind::Frame;
        result.frame.emplace(frames_[index_]);
        ++index_;
        return result;
    }

    std::optional<SourceVideoInfo> sourceInfo() const {
        return info_;
    }

    std::size_t readCalls = 0;

private:
    SourceVideoInfo info_{};
    std::vector<PreparedFrame> frames_;
    std::size_t index_ = 0;
};

void InstallSource(
    FramePipelinePump& pump,
    FakeTimedSource& source) {
    FramePipelinePumpStageF1TestAccess::installTimedSource(
        pump,
        [&source]() {
            return source.read();
        },
        [&source]() {
            return source.sourceInfo();
        });
}

bool TestPassthroughPacingAndNoReadAhead() {
    FrameEngineState state;
    CHECK(PrimeState(state));

    LocalVideoReader reader(state);
    FrameNormalizer normalizer;
    FrameTransformer transformer;
    FrameTimelineScheduler scheduler(2'000'000ULL);
    ReadyFrameQueue queue(4);

    FramePipelinePump pump(
        state,
        reader,
        normalizer,
        transformer,
        scheduler,
        queue,
        Target());

    FakeTimedSource source(SourceInfo());
    source.add(MakeFrame(
        0,
        state.mediaGeneration(),
        state.timelineEpoch(),
        0,
        CMTimeMake(0, 30),
        CMTimeMake(1, 30)));
    source.add(MakeFrame(
        1,
        state.mediaGeneration(),
        state.timelineEpoch(),
        0,
        CMTimeMake(1, 30),
        CMTimeMake(1, 30)));
    InstallSource(pump, source);

    constexpr std::uint64_t start = 1'000'000'000ULL;

    const auto first = pump.pumpOnceAtHostTime(start);
    CHECK(first.status == FramePipelinePumpStatus::Published);
    CHECK(first.timelineStatus == TimelineScheduleStatus::ReadyNow);
    CHECK(first.dueHostTimeNs == start);
    CHECK(first.frameTiming.has_value());
    CHECK(first.frameTiming->producedAtHostTime == start);
    CHECK(!CMTIME_IS_VALID(
        first.frameTiming->presentationTimestamp));
    CHECK(source.readCalls == 1);

    const auto early = pump.pumpOnceAtHostTime(start);
    CHECK(early.status ==
          FramePipelinePumpStatus::WaitingForPresentation);
    CHECK(early.timelineStatus ==
          TimelineScheduleStatus::WaitUntilDue);
    CHECK(early.dueHostTimeNs.has_value());
    CHECK(*early.dueHostTimeNs == 1'033'333'333ULL);
    CHECK(source.readCalls == 2);

    const auto repeatedWait =
        pump.pumpOnceAtHostTime(start + 1'000ULL);
    CHECK(repeatedWait.status ==
          FramePipelinePumpStatus::WaitingForPresentation);
    CHECK(repeatedWait.dueHostTimeNs == early.dueHostTimeNs);
    CHECK(source.readCalls == 2);

    const auto due =
        pump.pumpOnceAtHostTime(*early.dueHostTimeNs);
    CHECK(due.status == FramePipelinePumpStatus::Published);
    CHECK(due.frameIdentity.has_value());
    CHECK(due.frameIdentity->sequence == 1);
    CHECK(due.frameTiming->producedAtHostTime ==
          *early.dueHostTimeNs);
    CHECK(!CMTIME_IS_VALID(
        due.frameTiming->presentationTimestamp));
    CHECK(source.readCalls == 2);
    return true;
}

bool TestLateFrameDroppedWithoutPublish() {
    FrameEngineState state;
    CHECK(PrimeState(state));

    LocalVideoReader reader(state);
    FrameNormalizer normalizer;
    FrameTransformer transformer;
    FrameTimelineScheduler scheduler(1'000'000ULL);
    ReadyFrameQueue queue(4);

    FramePipelinePump pump(
        state,
        reader,
        normalizer,
        transformer,
        scheduler,
        queue,
        Target());

    FakeTimedSource source(SourceInfo());
    source.add(MakeFrame(
        0,
        state.mediaGeneration(),
        state.timelineEpoch(),
        0,
        kCMTimeZero,
        CMTimeMake(1, 30)));
    source.add(MakeFrame(
        1,
        state.mediaGeneration(),
        state.timelineEpoch(),
        0,
        CMTimeMake(1, 30),
        CMTimeMake(1, 30)));
    InstallSource(pump, source);

    const std::uint64_t start = 10'000ULL;
    CHECK(pump.pumpOnceAtHostTime(start).status ==
          FramePipelinePumpStatus::Published);

    const auto wait = pump.pumpOnceAtHostTime(start);
    CHECK(wait.status ==
          FramePipelinePumpStatus::WaitingForPresentation);
    const std::size_t beforeDrop = queue.size();

    const auto dropped = pump.pumpOnceAtHostTime(
        *wait.dueHostTimeNs + 1'000'001ULL);

    CHECK(dropped.status == FramePipelinePumpStatus::DroppedLate);
    CHECK(dropped.timelineStatus == TimelineScheduleStatus::DropLate);
    CHECK(queue.size() == beforeDrop);
    CHECK(source.readCalls == 2);
    return true;
}

bool TestLowLatencyQueueCleanup() {
    FrameEngineState state;
    CHECK(PrimeState(state));

    LocalVideoReader reader(state);
    FrameNormalizer normalizer;
    FrameTransformer transformer;
    FrameTimelineScheduler scheduler(5'000'000ULL);
    ReadyFrameQueue queue(4);

    FramePipelinePump pump(
        state,
        reader,
        normalizer,
        transformer,
        scheduler,
        queue,
        Target());

    FakeTimedSource source(SourceInfo());
    source.add(MakeFrame(
        0,
        state.mediaGeneration(),
        state.timelineEpoch(),
        0,
        kCMTimeZero,
        CMTimeMake(1, 30)));
    source.add(MakeFrame(
        1,
        state.mediaGeneration(),
        state.timelineEpoch(),
        0,
        CMTimeMake(1, 30),
        CMTimeMake(1, 30)));
    InstallSource(pump, source);

    constexpr std::uint64_t start = 100'000ULL;
    CHECK(pump.pumpOnceAtHostTime(start).status ==
          FramePipelinePumpStatus::Published);
    CHECK(queue.size() == 1);

    const auto wait = pump.pumpOnceAtHostTime(start);
    CHECK(wait.status ==
          FramePipelinePumpStatus::WaitingForPresentation);

    const auto second =
        pump.pumpOnceAtHostTime(*wait.dueHostTimeNs);
    CHECK(second.status == FramePipelinePumpStatus::Published);
    CHECK(second.purgedQueueEntries == 1);
    CHECK(queue.size() == 1);

    auto acquired = queue.tryAcquire(Context(state));
    CHECK(acquired.kind == AcquireResultKind::Acquired);
    CHECK(acquired.lease->frameLease()->identity().sequence == 1);
    return true;
}

bool TestLeasedOldFrameSurvivesCleanup() {
    FrameEngineState state;
    CHECK(PrimeState(state));

    LocalVideoReader reader(state);
    FrameNormalizer normalizer;
    FrameTransformer transformer;
    FrameTimelineScheduler scheduler(5'000'000ULL);
    ReadyFrameQueue queue(4);

    FramePipelinePump pump(
        state,
        reader,
        normalizer,
        transformer,
        scheduler,
        queue,
        Target());

    FakeTimedSource source(SourceInfo());
    source.add(MakeFrame(
        0,
        state.mediaGeneration(),
        state.timelineEpoch(),
        0,
        kCMTimeZero,
        CMTimeMake(1, 30)));
    source.add(MakeFrame(
        1,
        state.mediaGeneration(),
        state.timelineEpoch(),
        0,
        CMTimeMake(1, 30),
        CMTimeMake(1, 30)));
    InstallSource(pump, source);

    constexpr std::uint64_t start = 1'000ULL;
    CHECK(pump.pumpOnceAtHostTime(start).status ==
          FramePipelinePumpStatus::Published);

    auto oldAcquired = queue.tryAcquire(Context(state));
    CHECK(oldAcquired.kind == AcquireResultKind::Acquired);
    CHECK(oldAcquired.lease.has_value());
    CHECK(oldAcquired.lease->valid());
    CVPixelBufferRef oldBuffer =
        oldAcquired.lease->frameLease()->pixelBuffer();
    CHECK(oldBuffer != nullptr);

    const auto wait = pump.pumpOnceAtHostTime(start);
    CHECK(wait.status ==
          FramePipelinePumpStatus::WaitingForPresentation);

    const auto second =
        pump.pumpOnceAtHostTime(*wait.dueHostTimeNs);
    CHECK(second.status == FramePipelinePumpStatus::Published);
    CHECK(second.purgedQueueEntries == 1);
    CHECK(oldAcquired.lease->valid());
    CHECK(oldAcquired.lease->frameLease()->pixelBuffer() ==
          oldBuffer);

    auto newest = queue.tryAcquire(Context(state));
    CHECK(newest.kind == AcquireResultKind::Acquired);
    CHECK(newest.lease->frameLease()->identity().sequence == 1);
    return true;
}

bool TestGenerationResetInvalidatesPending() {
    FrameEngineState state;
    CHECK(PrimeState(state));

    LocalVideoReader reader(state);
    FrameNormalizer normalizer;
    FrameTransformer transformer;
    FrameTimelineScheduler scheduler(5'000'000ULL);
    ReadyFrameQueue queue(4);

    FramePipelinePump pump(
        state,
        reader,
        normalizer,
        transformer,
        scheduler,
        queue,
        Target());

    FakeTimedSource source(SourceInfo());
    source.add(MakeFrame(
        0,
        state.mediaGeneration(),
        state.timelineEpoch(),
        0,
        kCMTimeZero,
        CMTimeMake(1, 30)));
    source.add(MakeFrame(
        1,
        state.mediaGeneration(),
        state.timelineEpoch(),
        0,
        CMTimeMake(1, 30),
        CMTimeMake(1, 30)));
    InstallSource(pump, source);

    constexpr std::uint64_t start = 50'000ULL;
    CHECK(pump.pumpOnceAtHostTime(start).status ==
          FramePipelinePumpStatus::Published);
    CHECK(pump.pumpOnceAtHostTime(start).status ==
          FramePipelinePumpStatus::WaitingForPresentation);
    CHECK(source.readCalls == 2);

    state.selectOrReplaceMedia();

    const auto reset = pump.pumpOnceAtHostTime(start);
    CHECK(reset.status == FramePipelinePumpStatus::GenerationReset);
    CHECK(source.readCalls == 2);
    CHECK(queue.size() == 0);
    return true;
}

bool TestEpochResetInvalidatesPending() {
    FrameEngineState state;
    CHECK(PrimeState(state));

    LocalVideoReader reader(state);
    FrameNormalizer normalizer;
    FrameTransformer transformer;
    FrameTimelineScheduler scheduler(5'000'000ULL);
    ReadyFrameQueue queue(4);

    FramePipelinePump pump(
        state,
        reader,
        normalizer,
        transformer,
        scheduler,
        queue,
        Target());

    FakeTimedSource source(SourceInfo());
    source.add(MakeFrame(
        0,
        state.mediaGeneration(),
        state.timelineEpoch(),
        0,
        kCMTimeZero,
        CMTimeMake(1, 30)));
    source.add(MakeFrame(
        1,
        state.mediaGeneration(),
        state.timelineEpoch(),
        0,
        CMTimeMake(1, 30),
        CMTimeMake(1, 30)));
    InstallSource(pump, source);

    constexpr std::uint64_t start = 60'000ULL;
    CHECK(pump.pumpOnceAtHostTime(start).status ==
          FramePipelinePumpStatus::Published);
    CHECK(pump.pumpOnceAtHostTime(start).status ==
          FramePipelinePumpStatus::WaitingForPresentation);
    CHECK(source.readCalls == 2);

    CHECK(state.pause());
    CHECK(state.resume());

    const auto reset = pump.pumpOnceAtHostTime(start);
    CHECK(reset.status == FramePipelinePumpStatus::EpochReset);
    CHECK(source.readCalls == 2);
    CHECK(queue.size() == 0);
    return true;
}

bool TestTransformedFramePacing() {
    FrameEngineState state;
    CHECK(PrimeState(state));

    LocalVideoReader reader(state);
    FrameNormalizer normalizer;
    FrameTransformer transformer;
    FrameTimelineScheduler scheduler(5'000'000ULL);
    ReadyFrameQueue queue(4);

    FramePipelinePump pump(
        state,
        reader,
        normalizer,
        transformer,
        scheduler,
        queue,
        Target(4, 4));

    FakeTimedSource source(SourceInfo(8, 8));
    source.add(MakeFrame(
        0,
        state.mediaGeneration(),
        state.timelineEpoch(),
        0,
        kCMTimeZero,
        CMTimeMake(1, 30)));
    source.add(MakeFrame(
        1,
        state.mediaGeneration(),
        state.timelineEpoch(),
        0,
        CMTimeMake(1, 30),
        CMTimeMake(1, 30)));
    InstallSource(pump, source);

    constexpr std::uint64_t start = 1000ULL;
    const auto first = pump.pumpOnceAtHostTime(start);
    CHECK(first.status == FramePipelinePumpStatus::Published);
    CHECK(first.transformStatus == FrameTransformStatus::Transformed);

    auto acquired = queue.tryAcquire(Context(state));
    CHECK(acquired.kind == AcquireResultKind::Acquired);
    CHECK(acquired.lease->frameLease()->width() == 4);
    CHECK(acquired.lease->frameLease()->height() == 4);
    acquired.lease.reset();

    const auto second = pump.pumpOnceAtHostTime(start);
    CHECK(second.status ==
          FramePipelinePumpStatus::WaitingForPresentation);
    CHECK(source.readCalls == 2);
    return true;
}

bool TestTransformFailurePublishesNothing() {
    FrameEngineState state;
    CHECK(PrimeState(state));

    LocalVideoReader reader(state);
    FrameNormalizer normalizer;
    FrameTransformer transformer;
    FrameTimelineScheduler scheduler(5'000'000ULL);
    ReadyFrameQueue queue(4);

    FramePipelinePump pump(
        state,
        reader,
        normalizer,
        transformer,
        scheduler,
        queue,
        Target(5, 4));

    FakeTimedSource source(SourceInfo(8, 8));
    source.add(MakeFrame(
        0,
        state.mediaGeneration(),
        state.timelineEpoch(),
        0,
        kCMTimeZero,
        CMTimeMake(1, 30)));
    InstallSource(pump, source);

    const auto result = pump.pumpOnceAtHostTime(1000ULL);
    CHECK(result.status == FramePipelinePumpStatus::TransformFailed);
    CHECK(result.transformStatus ==
          FrameTransformStatus::UnsupportedTarget);
    CHECK(queue.size() == 0);
    return true;
}

bool TestSerialProducerContractRejectsReentry() {
    FrameEngineState state;
    CHECK(PrimeState(state));

    LocalVideoReader reader(state);
    FrameNormalizer normalizer;
    FrameTransformer transformer;
    FrameTimelineScheduler scheduler(0);
    ReadyFrameQueue queue(2);

    FramePipelinePump pump(
        state,
        reader,
        normalizer,
        transformer,
        scheduler,
        queue,
        Target());

    FakeTimedSource source(SourceInfo());
    source.add(MakeFrame(
        0,
        state.mediaGeneration(),
        state.timelineEpoch(),
        0,
        kCMTimeZero,
        CMTimeMake(1, 30)));
    InstallSource(pump, source);

    CHECK(FramePipelinePumpStageF1TestAccess::claimTimedProducer(pump));
    const auto result = pump.pumpOnceAtHostTime(0);
    CHECK(result.status ==
          FramePipelinePumpStatus::ConcurrentProducerCallRejected);
    CHECK(source.readCalls == 0);
    FramePipelinePumpStageF1TestAccess::releaseTimedProducer(pump);
    return true;
}

bool TestAllocationFailureIsStructured() {
    FrameEngineState state;
    CHECK(PrimeState(state));

    LocalVideoReader reader(state);
    FrameNormalizer normalizer;
    FrameTransformer transformer;
    FrameTimelineScheduler scheduler(0);
    ReadyFrameQueue queue(2);

    FramePipelinePump pump(
        state,
        reader,
        normalizer,
        transformer,
        scheduler,
        queue,
        Target(4, 4));

    FramePipelinePumpStageF1TestAccess::installThrowingTransformer(
        pump);

    auto frame = MakeFrame(
        0,
        state.mediaGeneration(),
        state.timelineEpoch(),
        0,
        kCMTimeZero,
        CMTimeMake(1, 30),
        8,
        8);

    const auto result =
        FramePipelinePumpStageF1TestAccess::prepare(
            pump,
            std::move(frame),
            SourceInfo(8, 8),
            state.mediaGeneration(),
            state.timelineEpoch());

    CHECK(result.status == FramePipelinePumpStatus::AllocationFailed);
    CHECK(queue.size() == 0);
    return true;
}

void Run(
    const std::string& name,
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
    Run(
        "passthrough pacing and no read-ahead",
        TestPassthroughPacingAndNoReadAhead);
    Run(
        "late frame dropped without publish",
        TestLateFrameDroppedWithoutPublish);
    Run(
        "low-latency queue cleanup",
        TestLowLatencyQueueCleanup);
    Run(
        "leased old frame survives cleanup",
        TestLeasedOldFrameSurvivesCleanup);
    Run(
        "generation reset invalidates pending",
        TestGenerationResetInvalidatesPending);
    Run(
        "epoch reset invalidates pending",
        TestEpochResetInvalidatesPending);
    Run(
        "transformed frame pacing",
        TestTransformedFramePacing);
    Run(
        "transform failure publishes nothing",
        TestTransformFailurePublishesNothing);
    Run(
        "serial producer reentry rejected",
        TestSerialProducerContractRejectsReentry);
    Run(
        "allocation failure structured",
        TestAllocationFailureIsStructured);

    std::cout << "Stage F1 timed pipeline tests run: "
              << gTestsRun
              << ", failures: " << gFailures << std::endl;

    return gFailures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
