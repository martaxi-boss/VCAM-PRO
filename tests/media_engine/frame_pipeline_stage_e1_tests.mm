#include "FrameEngineState.h"
#include "FrameNormalizer.h"
#include "FramePipelinePump.h"
#include "FrameTransformer.h"
#include "LocalVideoReader.h"
#include "ReadyFrameQueue.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <functional>
#include <iostream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace vcam::media_engine {

class FramePipelinePumpStageE1TestAccess final {
public:
    static FramePipelinePumpResult process(
        FramePipelinePump& pump,
        frame_engine::PreparedFrame frame,
        const SourceVideoInfo& info,
        std::uint64_t generation,
        std::uint64_t epoch) {
        return pump.processFrame(
            std::move(frame),
            info,
            generation,
            epoch);
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
    OSType format,
    std::size_t width,
    std::size_t height,
    std::uint64_t generation,
    std::uint64_t epoch) {
    CVPixelBufferRef pixelBuffer = nullptr;
    const CVReturn status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        format,
        nullptr,
        &pixelBuffer);
    if (status != kCVReturnSuccess || pixelBuffer == nullptr) {
        throw std::runtime_error(
            "Unable to create Stage E1 pipeline fixture.");
    }

    CHECK(CVPixelBufferGetPlaneCount(pixelBuffer) == 2);

    if (CVPixelBufferLockBaseAddress(pixelBuffer, 0) !=
        kCVReturnSuccess) {
        CVPixelBufferRelease(pixelBuffer);
        throw std::runtime_error(
            "Unable to lock Stage E1 pipeline fixture.");
    }

    auto* yBase = static_cast<std::uint8_t*>(
        CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0));
    auto* cbCrBase = static_cast<std::uint8_t*>(
        CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1));
    const std::size_t yRowBytes =
        CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
    const std::size_t cbCrRowBytes =
        CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);

    for (std::size_t y = 0; y < height; ++y) {
        std::fill_n(
            yBase + y * yRowBytes,
            width,
            static_cast<std::uint8_t>(64 + (y % 4) * 8));
    }
    for (std::size_t y = 0; y < height / 2; ++y) {
        auto* row = cbCrBase + y * cbCrRowBytes;
        for (std::size_t x = 0; x < width; x += 2) {
            row[x] = 128;
            row[x + 1] = 128;
        }
    }

    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

    FrameIdentity identity{11, generation, epoch, 0};
    FrameTiming timing;
    timing.sourcePTS = CMTimeMake(11, 30);
    timing.presentationTimestamp = kCMTimeInvalid;
    timing.duration = CMTimeMake(1, 30);

    PreparedFrame frame(
        pixelBuffer,
        identity,
        timing,
        OrientationState::SourceNotNormalized,
        FrameValidity::Ready);
    CVPixelBufferRelease(pixelBuffer);
    return frame;
}

NormalizationTarget Target(
    std::size_t width,
    std::size_t height) {
    NormalizationTarget target;
    target.width = width;
    target.height = height;
    target.pixelFormat =
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    target.orientation =
        OrientationRequirement::UprightIdentityTransform;
    target.colorMetadata = ColorMetadataPolicy::PreserveSource;
    return target;
}

SourceVideoInfo Info(
    std::size_t width,
    std::size_t height) {
    SourceVideoInfo info;
    info.naturalSize = CGSizeMake(
        static_cast<CGFloat>(width),
        static_cast<CGFloat>(height));
    info.preferredTransform = CGAffineTransformIdentity;
    info.outputPixelFormat =
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    return info;
}

QueueContext Context(const FrameEngineState& state) {
    return {
        state.mediaGeneration(),
        state.timelineEpoch(),
        std::nullopt,
    };
}

bool PrimeState(FrameEngineState& state) {
    state.selectOrReplaceMedia();
    return state.start();
}

bool TestTransformEnabledPumpPublishes() {
    FrameEngineState state;
    CHECK(PrimeState(state));

    LocalVideoReader reader(state);
    FrameNormalizer normalizer;
    FrameTransformer transformer;
    ReadyFrameQueue queue(2);

    FramePipelinePump pump(
        state,
        reader,
        normalizer,
        transformer,
        queue,
        Target(4, 4));

    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        8,
        8,
        state.mediaGeneration(),
        state.timelineEpoch());

    const auto result =
        FramePipelinePumpStageE1TestAccess::process(
            pump,
            std::move(frame),
            Info(8, 8),
            state.mediaGeneration(),
            state.timelineEpoch());

    CHECK(result.status == FramePipelinePumpStatus::Published);
    CHECK(result.transformStatus == FrameTransformStatus::Transformed);
    CHECK(result.normalizationStatus ==
          NormalizationStatus::ReadyPassthrough);
    CHECK(result.publishResult == PublishResult::Published);
    CHECK(result.frameIdentity.has_value());
    CHECK(queue.size() == 1);

    auto acquired = queue.tryAcquire(Context(state));
    CHECK(acquired.kind == AcquireResultKind::Acquired);
    CHECK(acquired.lease.has_value());
    CHECK(acquired.lease->valid());
    CHECK(acquired.lease->frameLease()->width() == 4);
    CHECK(acquired.lease->frameLease()->height() == 4);
    return true;
}

bool TestTransformFailurePublishesNothing() {
    FrameEngineState state;
    CHECK(PrimeState(state));

    LocalVideoReader reader(state);
    FrameNormalizer normalizer;
    FrameTransformer transformer;
    ReadyFrameQueue queue(2);

    FramePipelinePump pump(
        state,
        reader,
        normalizer,
        transformer,
        queue,
        Target(5, 4));

    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        8,
        8,
        state.mediaGeneration(),
        state.timelineEpoch());

    const auto result =
        FramePipelinePumpStageE1TestAccess::process(
            pump,
            std::move(frame),
            Info(8, 8),
            state.mediaGeneration(),
            state.timelineEpoch());

    CHECK(result.status == FramePipelinePumpStatus::TransformFailed);
    CHECK(result.transformStatus ==
          FrameTransformStatus::UnsupportedTarget);
    CHECK(queue.size() == 0);
    return true;
}

bool TestPassthroughSkipsTransformerResources() {
    FrameEngineState state;
    CHECK(PrimeState(state));

    LocalVideoReader reader(state);
    FrameNormalizer normalizer;
    FrameTransformer transformer;
    ReadyFrameQueue queue(2);

    FramePipelinePump pump(
        state,
        reader,
        normalizer,
        transformer,
        queue,
        Target(8, 8));

    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        8,
        8,
        state.mediaGeneration(),
        state.timelineEpoch());

    const auto result =
        FramePipelinePumpStageE1TestAccess::process(
            pump,
            std::move(frame),
            Info(8, 8),
            state.mediaGeneration(),
            state.timelineEpoch());

    CHECK(result.status == FramePipelinePumpStatus::Published);
    CHECK(result.normalizationStatus ==
          NormalizationStatus::ReadyPassthrough);
    CHECK(transformer.stats().outputPoolBuilds == 0);
    CHECK(queue.size() == 1);
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
        "transform-enabled pump publishes",
        TestTransformEnabledPumpPublishes);
    Run(
        "transform failure publishes nothing",
        TestTransformFailurePublishesNothing);
    Run(
        "passthrough skips transformer resources",
        TestPassthroughSkipsTransformerResources);

    std::cout << "Stage E1 pipeline tests run: "
              << gTestsRun
              << ", failures: " << gFailures << std::endl;

    return gFailures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
