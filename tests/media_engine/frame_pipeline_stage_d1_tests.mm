#include "FramePipelinePump.h"

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <iostream>
#include <optional>
#include <string>
#include <utility>
#include <unistd.h>

namespace {

using namespace vcam::frame_engine;
using namespace vcam::media_engine;

}  // namespace

namespace vcam::media_engine {

class FramePipelinePumpTestAccess final {
public:
    static FramePipelinePumpResult processFrame(
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

int gFailures = 0;
int gTestsRun = 0;

#define CHECK(condition)                                                        \
    do {                                                                        \
        if (!(condition)) {                                                     \
            std::cerr << "CHECK failed at " << __FILE__ << ":" << __LINE__    \
                      << ": " #condition << std::endl;                          \
            return false;                                                       \
        }                                                                       \
    } while (false)

std::string ToStdString(NSString* value) {
    const char* utf8 = [value UTF8String];
    return utf8 == nullptr ? std::string{} : std::string(utf8);
}

std::string UniqueFixturePath(const char* suffix) {
    NSString* directory = NSTemporaryDirectory();
    NSString* name = [NSString
        stringWithFormat:@"vcam-stage-d1-%@-%d-%s.mov",
                         [[NSUUID UUID] UUIDString],
                         getpid(),
                         suffix];
    return ToStdString([directory stringByAppendingPathComponent:name]);
}

bool WaitForWriterInput(AVAssetWriterInput* input) {
    for (int attempt = 0; attempt < 5000; ++attempt) {
        if (input.readyForMoreMediaData) {
            return true;
        }
        [NSThread sleepForTimeInterval:0.001];
    }
    return false;
}

bool CreateLocalVideoFixture(
    const std::string& path,
    int frameCount = 3,
    int width = 64,
    int height = 48,
    CGAffineTransform transform = CGAffineTransformIdentity,
    AVVideoCodecType codec = AVVideoCodecTypeH264) {
    @autoreleasepool {
        NSString* nsPath =
            [[NSString alloc] initWithUTF8String:path.c_str()];
        if (nsPath == nil) {
            return false;
        }

        [[NSFileManager defaultManager] removeItemAtPath:nsPath error:nil];
        NSURL* url = [NSURL fileURLWithPath:nsPath];

        NSError* writerError = nil;
        AVAssetWriter* writer =
            [[AVAssetWriter alloc] initWithURL:url
                                      fileType:AVFileTypeQuickTimeMovie
                                         error:&writerError];
        if (writer == nil) {
            return false;
        }

        NSDictionary* settings = nil;
        if ([codec isEqualToString:AVVideoCodecTypeH264]) {
            NSDictionary* compression = @{
                AVVideoAverageBitRateKey : @(150000)
            };
            settings = @{
                AVVideoCodecKey : codec,
                AVVideoWidthKey : @(width),
                AVVideoHeightKey : @(height),
                AVVideoCompressionPropertiesKey : compression,
            };
        } else {
            // Test-only metadata-sparse fixture path. No AVVideoColorPropertiesKey
            // is supplied; this intentionally avoids declaring color metadata.
            settings = @{
                AVVideoCodecKey : codec,
                AVVideoWidthKey : @(width),
                AVVideoHeightKey : @(height),
            };
        }

        AVAssetWriterInput* input =
            [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                               outputSettings:settings];
        input.expectsMediaDataInRealTime = NO;
        input.transform = transform;

        // BGRA/CVPixelBufferPool are TEST-ONLY AVAssetWriter fixture details.
        NSDictionary* attributes = @{
            (NSString*)kCVPixelBufferPixelFormatTypeKey :
                @(kCVPixelFormatType_32BGRA),
            (NSString*)kCVPixelBufferWidthKey : @(width),
            (NSString*)kCVPixelBufferHeightKey : @(height),
        };

        AVAssetWriterInputPixelBufferAdaptor* adaptor =
            [AVAssetWriterInputPixelBufferAdaptor
                assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
                sourcePixelBufferAttributes:attributes];

        if (![writer canAddInput:input]) {
            return false;
        }
        [writer addInput:input];

        if (![writer startWriting]) {
            return false;
        }
        [writer startSessionAtSourceTime:kCMTimeZero];

        CVPixelBufferPoolRef pool = adaptor.pixelBufferPool;
        if (pool == nullptr) {
            return false;
        }

        for (int index = 0; index < frameCount; ++index) {
            if (!WaitForWriterInput(input)) {
                return false;
            }

            CVPixelBufferRef pixelBuffer = nullptr;
            if (CVPixelBufferPoolCreatePixelBuffer(
                    kCFAllocatorDefault,
                    pool,
                    &pixelBuffer) != kCVReturnSuccess ||
                pixelBuffer == nullptr) {
                return false;
            }

            CVPixelBufferLockBaseAddress(pixelBuffer, 0);
            auto* bytes = static_cast<unsigned char*>(
                CVPixelBufferGetBaseAddress(pixelBuffer));
            const std::size_t bytesPerRow =
                CVPixelBufferGetBytesPerRow(pixelBuffer);
            const std::size_t rows =
                CVPixelBufferGetHeight(pixelBuffer);
            std::memset(bytes,
                        static_cast<unsigned char>(32 + index * 32),
                        bytesPerRow * rows);
            CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

            const CMTime pts = CMTimeMake(index, 30);
            const BOOL appended =
                [adaptor appendPixelBuffer:pixelBuffer
                      withPresentationTime:pts];
            CVPixelBufferRelease(pixelBuffer);

            if (!appended) {
                return false;
            }
        }

        [input markAsFinished];

        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        [writer finishWritingWithCompletionHandler:^{
            dispatch_semaphore_signal(semaphore);
        }];

        const dispatch_time_t timeout =
            dispatch_time(DISPATCH_TIME_NOW,
                          static_cast<int64_t>(10 * NSEC_PER_SEC));
        if (dispatch_semaphore_wait(semaphore, timeout) != 0) {
            return false;
        }

        return writer.status == AVAssetWriterStatusCompleted;
    }
}

void RemoveFixture(const std::string& path) {
    @autoreleasepool {
        NSString* nsPath =
            [[NSString alloc] initWithUTF8String:path.c_str()];
        if (nsPath != nil) {
            [[NSFileManager defaultManager]
                removeItemAtPath:nsPath
                           error:nil];
        }
    }
}

LocalVideoReaderConfig ReaderConfig(
    OSType pixelFormat,
    bool loopEnabled = false) {
    LocalVideoReaderConfig config;
    config.loopEnabled = loopEnabled;
    config.outputPixelFormat = pixelFormat;
    return config;
}

NormalizationTarget Target(
    OSType pixelFormat,
    std::size_t width = 64,
    std::size_t height = 48,
    ColorMetadataPolicy colorMetadata =
        ColorMetadataPolicy::PreserveSource) {
    NormalizationTarget target;
    target.width = width;
    target.height = height;
    target.pixelFormat = pixelFormat;
    target.orientation =
        OrientationRequirement::UprightIdentityTransform;
    target.colorMetadata = colorMetadata;
    return target;
}

QueueContext Context(const FrameEngineState& state) {
    QueueContext context;
    context.currentMediaGeneration = state.mediaGeneration();
    context.currentTimelineEpoch = state.timelineEpoch();
    context.minimumSequence = std::nullopt;
    return context;
}

PreparedFrame MakeFrameWithoutColorMetadata(
    std::uint64_t generation,
    std::uint64_t epoch) {
    CVPixelBufferRef pixelBuffer = nullptr;
    const CVReturn created = CVPixelBufferCreate(
        kCFAllocatorDefault,
        64,
        48,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        nullptr,
        &pixelBuffer);
    if (created != kCVReturnSuccess || pixelBuffer == nullptr) {
        throw std::runtime_error(
            "Unable to create metadata-free D1 pixel buffer fixture.");
    }

    FrameIdentity identity{0, generation, epoch, 0};
    FrameTiming timing;
    timing.sourcePTS = kCMTimeZero;
    timing.presentationTimestamp = kCMTimeInvalid;
    timing.duration = CMTimeMake(1, 30);

    PreparedFrame frame(
        pixelBuffer,
        identity,
        timing,
        OrientationState::SourceNotNormalized,
        FrameValidity::Ready,
        nullptr,
        nullptr,
        nullptr,
        nullptr);
    CVPixelBufferRelease(pixelBuffer);
    return frame;
}

FramePipelinePumpResult PumpUntilAction(
    FramePipelinePump& pump,
    int maxCalls = 32) {
    for (int attempt = 0; attempt < maxCalls; ++attempt) {
        FramePipelinePumpResult result = pump.pumpOnce();
        if (result.status != FramePipelinePumpStatus::NotReady) {
            return result;
        }
    }
    return {};
}

bool OpenStart(
    LocalVideoReader& reader,
    const std::string& path,
    OSType format,
    bool loop = false) {
    return reader.open(path, ReaderConfig(format, loop)) &&
           reader.start();
}

bool TestCompatible420vPublishes(const std::string& path) {
    FrameEngineState state;
    LocalVideoReader reader(state);
    FrameNormalizer normalizer;
    ReadyFrameQueue queue(2);
    CHECK(OpenStart(
        reader,
        path,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));

    FramePipelinePump pump(
        state,
        reader,
        normalizer,
        queue,
        Target(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));

    const auto pumped = PumpUntilAction(pump);
    CHECK(pumped.status == FramePipelinePumpStatus::Published);

    AcquireResult acquired = queue.tryAcquire(Context(state));
    CHECK(acquired.kind == AcquireResultKind::Acquired);
    CHECK(acquired.lease.has_value());
    CHECK(acquired.lease->valid());
    CHECK(acquired.lease->frameLease()->pixelFormat() ==
          kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    return true;
}

bool TestCompatible420fPublishes(const std::string& path) {
    FrameEngineState state;
    LocalVideoReader reader(state);
    FrameNormalizer normalizer;
    ReadyFrameQueue queue(2);
    CHECK(OpenStart(
        reader,
        path,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange));

    FramePipelinePump pump(
        state,
        reader,
        normalizer,
        queue,
        Target(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange));

    const auto pumped = PumpUntilAction(pump);
    CHECK(pumped.status == FramePipelinePumpStatus::Published);

    AcquireResult acquired = queue.tryAcquire(Context(state));
    CHECK(acquired.kind == AcquireResultKind::Acquired);
    CHECK(acquired.lease->frameLease()->pixelFormat() ==
          kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
    return true;
}

bool TestPublishedSourcePTSCorrelatesWithAcquire(
    const std::string& path) {
    FrameEngineState state;
    LocalVideoReader reader(state);
    FrameNormalizer normalizer;
    ReadyFrameQueue queue(2);
    CHECK(OpenStart(
        reader,
        path,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));

    FramePipelinePump pump(
        state,
        reader,
        normalizer,
        queue,
        Target(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));

    const auto pumped = PumpUntilAction(pump);
    CHECK(pumped.status == FramePipelinePumpStatus::Published);
    CHECK(pumped.frameTiming.has_value());
    CHECK(pumped.frameIdentity.has_value());
    CHECK(CMTIME_IS_VALID(pumped.frameTiming->sourcePTS));
    CHECK(CMTimeCompare(pumped.frameTiming->sourcePTS, kCMTimeZero) == 0);

    AcquireResult acquired = queue.tryAcquire(Context(state));
    CHECK(acquired.kind == AcquireResultKind::Acquired);
    CHECK(acquired.lease->frameLease()->identity().sequence ==
          pumped.frameIdentity->sequence);
    CHECK(acquired.lease->frameLease()->identity().mediaGeneration ==
          pumped.frameIdentity->mediaGeneration);
    CHECK(acquired.lease->frameLease()->identity().timelineEpoch ==
          pumped.frameIdentity->timelineEpoch);
    return true;
}

bool TestIdentitySurvivesPipeline(const std::string& path) {
    FrameEngineState state;
    LocalVideoReader reader(state);
    FrameNormalizer normalizer;
    ReadyFrameQueue queue(2);
    CHECK(OpenStart(
        reader,
        path,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));

    const auto generation = state.mediaGeneration();
    const auto epoch = state.timelineEpoch();

    FramePipelinePump pump(
        state,
        reader,
        normalizer,
        queue,
        Target(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));

    const auto pumped = PumpUntilAction(pump);
    CHECK(pumped.status == FramePipelinePumpStatus::Published);
    CHECK(pumped.frameIdentity.has_value());
    CHECK(pumped.frameIdentity->mediaGeneration == generation);
    CHECK(pumped.frameIdentity->timelineEpoch == epoch);

    AcquireResult acquired = queue.tryAcquire(Context(state));
    CHECK(acquired.kind == AcquireResultKind::Acquired);
    const FrameIdentity& identity =
        acquired.lease->frameLease()->identity();
    CHECK(identity.mediaGeneration == generation);
    CHECK(identity.timelineEpoch == epoch);
    CHECK(identity.sequence == pumped.frameIdentity->sequence);
    return true;
}

bool TestPixelBufferValidThroughQueueLease(const std::string& path) {
    FrameEngineState state;
    LocalVideoReader reader(state);
    FrameNormalizer normalizer;
    ReadyFrameQueue queue(1);
    CHECK(OpenStart(
        reader,
        path,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));

    FramePipelinePump pump(
        state,
        reader,
        normalizer,
        queue,
        Target(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));

    CHECK(PumpUntilAction(pump).status ==
          FramePipelinePumpStatus::Published);
    AcquireResult acquired = queue.tryAcquire(Context(state));
    CHECK(acquired.kind == AcquireResultKind::Acquired);
    CHECK(acquired.lease->valid());
    CHECK(acquired.lease->frameLease()->pixelBuffer() != nullptr);
    CHECK(CVPixelBufferGetWidth(
              acquired.lease->frameLease()->pixelBuffer()) == 64);
    CHECK(CVPixelBufferGetHeight(
              acquired.lease->frameLease()->pixelBuffer()) == 48);
    return true;
}

bool TestWidthMismatchTransformRequired(const std::string& path) {
    FrameEngineState state;
    LocalVideoReader reader(state);
    FrameNormalizer normalizer;
    ReadyFrameQueue queue(2);
    CHECK(OpenStart(
        reader,
        path,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));

    FramePipelinePump pump(
        state,
        reader,
        normalizer,
        queue,
        Target(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 65, 48));

    const auto result = PumpUntilAction(pump);
    CHECK(result.status == FramePipelinePumpStatus::TransformRequired);
    CHECK(result.transformRequirement == TransformRequirement::Size);
    CHECK(queue.size() == 0);
    return true;
}

bool TestHeightMismatchTransformRequired(const std::string& path) {
    FrameEngineState state;
    LocalVideoReader reader(state);
    FrameNormalizer normalizer;
    ReadyFrameQueue queue(2);
    CHECK(OpenStart(
        reader,
        path,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));

    FramePipelinePump pump(
        state,
        reader,
        normalizer,
        queue,
        Target(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 64, 49));

    const auto result = PumpUntilAction(pump);
    CHECK(result.status == FramePipelinePumpStatus::TransformRequired);
    CHECK(result.transformRequirement == TransformRequirement::Size);
    CHECK(queue.size() == 0);
    return true;
}

bool TestPixelFormatMismatchTransformRequired(
    const std::string& path) {
    FrameEngineState state;
    LocalVideoReader reader(state);
    FrameNormalizer normalizer;
    ReadyFrameQueue queue(2);
    CHECK(OpenStart(
        reader,
        path,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));

    FramePipelinePump pump(
        state,
        reader,
        normalizer,
        queue,
        Target(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange));

    const auto result = PumpUntilAction(pump);
    CHECK(result.status == FramePipelinePumpStatus::TransformRequired);
    CHECK(result.transformRequirement == TransformRequirement::PixelFormat);
    CHECK(queue.size() == 0);
    return true;
}

bool TestNonIdentityTransformRequired(const std::string& rotatedPath) {
    FrameEngineState state;
    LocalVideoReader reader(state);
    FrameNormalizer normalizer;
    ReadyFrameQueue queue(2);
    CHECK(OpenStart(
        reader,
        rotatedPath,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));

    const auto info = reader.sourceInfo();
    CHECK(info.has_value());
    CHECK(!CGAffineTransformIsIdentity(info->preferredTransform));

    FramePipelinePump pump(
        state,
        reader,
        normalizer,
        queue,
        Target(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));

    const auto result = PumpUntilAction(pump);
    CHECK(result.status == FramePipelinePumpStatus::TransformRequired);
    CHECK(result.transformRequirement == TransformRequirement::Orientation);
    CHECK(queue.size() == 0);
    return true;
}

bool TestRequirePresentMissingMetadataNoPublish(
    const std::string&) {
    FrameEngineState state;
    state.selectOrReplaceMedia();
    CHECK(state.markReaderReady());
    CHECK(state.start());
    CHECK(state.beginReading());

    LocalVideoReader reader(state);
    FrameNormalizer normalizer;
    ReadyFrameQueue queue(2);

    FramePipelinePump pump(
        state,
        reader,
        normalizer,
        queue,
        Target(
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            64,
            48,
            ColorMetadataPolicy::RequirePresent));

    SourceVideoInfo info;
    info.naturalSize = CGSizeMake(64, 48);
    info.preferredTransform = CGAffineTransformIdentity;
    info.outputPixelFormat =
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;

    auto result = FramePipelinePumpTestAccess::processFrame(
        pump,
        MakeFrameWithoutColorMetadata(
            state.mediaGeneration(),
            state.timelineEpoch()),
        info,
        state.mediaGeneration(),
        state.timelineEpoch());

    CHECK(result.status ==
          FramePipelinePumpStatus::NormalizationRejected);
    CHECK(result.normalizationStatus ==
          NormalizationStatus::MissingRequiredColorMetadata);
    CHECK(result.transformRequirement == TransformRequirement::None);
    CHECK(queue.size() == 0);
    return true;
}

bool TestEOSWithoutLoopNoPublish(const std::string& oneFramePath) {
    FrameEngineState state;
    LocalVideoReader reader(state);
    FrameNormalizer normalizer;
    ReadyFrameQueue queue(4);
    CHECK(OpenStart(
        reader,
        oneFramePath,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        false));

    FramePipelinePump pump(
        state,
        reader,
        normalizer,
        queue,
        Target(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));

    CHECK(PumpUntilAction(pump).status ==
          FramePipelinePumpStatus::Published);
    const std::size_t beforeTerminal = queue.size();

    FramePipelinePumpResult terminal;
    for (int attempt = 0; attempt < 32; ++attempt) {
        terminal = pump.pumpOnce();
        if (terminal.status == FramePipelinePumpStatus::EndOfStream) {
            break;
        }
        CHECK(terminal.status == FramePipelinePumpStatus::NotReady);
    }

    CHECK(terminal.status == FramePipelinePumpStatus::EndOfStream);
    CHECK(queue.size() == beforeTerminal);
    return true;
}

bool TestLoopRestartPropagated(const std::string& oneFramePath) {
    FrameEngineState state;
    LocalVideoReader reader(state);
    FrameNormalizer normalizer;
    ReadyFrameQueue queue(4);
    CHECK(OpenStart(
        reader,
        oneFramePath,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        true));

    FramePipelinePump pump(
        state,
        reader,
        normalizer,
        queue,
        Target(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));

    CHECK(PumpUntilAction(pump).status ==
          FramePipelinePumpStatus::Published);

    FramePipelinePumpResult terminal;
    for (int attempt = 0; attempt < 32; ++attempt) {
        terminal = pump.pumpOnce();
        if (terminal.status == FramePipelinePumpStatus::LoopRestarted) {
            break;
        }
        CHECK(terminal.status == FramePipelinePumpStatus::NotReady);
    }

    CHECK(terminal.status == FramePipelinePumpStatus::LoopRestarted);
    CHECK(state.loopIteration() == 1);
    return true;
}

bool TestCancelledPropagated(const std::string& path) {
    FrameEngineState state;
    LocalVideoReader reader(state);
    FrameNormalizer normalizer;
    ReadyFrameQueue queue(2);
    CHECK(OpenStart(
        reader,
        path,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));

    FramePipelinePump pump(
        state,
        reader,
        normalizer,
        queue,
        Target(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));

    reader.stop();
    const auto result = pump.pumpOnce();
    CHECK(result.status == FramePipelinePumpStatus::Cancelled);
    CHECK(result.readResult == ReadResultKind::Cancelled);
    CHECK(queue.size() == 0);
    return true;
}

bool TestReaderFailurePropagated(const std::string& oneFramePath) {
    FrameEngineState state;
    LocalVideoReader reader(state);
    FrameNormalizer normalizer;
    ReadyFrameQueue queue(4);
    CHECK(OpenStart(
        reader,
        oneFramePath,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));

    FramePipelinePump pump(
        state,
        reader,
        normalizer,
        queue,
        Target(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));

    CHECK(PumpUntilAction(pump).status ==
          FramePipelinePumpStatus::Published);

    state.markReaderFailed(ReaderErrorCode::ReadFailed);
    state.markPlaybackFailed();
    const std::size_t beforeFailure = queue.size();

    FramePipelinePumpResult failure;
    for (int attempt = 0; attempt < 32; ++attempt) {
        failure = pump.pumpOnce();
        if (failure.status == FramePipelinePumpStatus::ReaderFailed) {
            break;
        }
        CHECK(failure.status == FramePipelinePumpStatus::NotReady);
    }

    CHECK(failure.status == FramePipelinePumpStatus::ReaderFailed);
    CHECK(failure.readResult == ReadResultKind::Failed);
    CHECK(failure.status != FramePipelinePumpStatus::EndOfStream);
    CHECK(queue.size() == beforeFailure);
    return true;
}

bool TestQueueCapacityRemainsBounded(const std::string& path) {
    FrameEngineState state;
    LocalVideoReader reader(state);
    FrameNormalizer normalizer;
    ReadyFrameQueue queue(1);
    CHECK(OpenStart(
        reader,
        path,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));

    FramePipelinePump pump(
        state,
        reader,
        normalizer,
        queue,
        Target(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));

    int published = 0;
    for (int attempt = 0; attempt < 32 && published < 3; ++attempt) {
        const auto result = pump.pumpOnce();
        if (result.status == FramePipelinePumpStatus::Published) {
            ++published;
            CHECK(queue.size() <= queue.capacity());
        } else {
            CHECK(result.status == FramePipelinePumpStatus::NotReady);
        }
    }

    CHECK(published == 3);
    CHECK(queue.size() == 1);
    CHECK(queue.capacity() == 1);
    return true;
}

bool TestFullyLeasedQueueDropsWithoutBlocking(const std::string& path) {
    FrameEngineState state;
    LocalVideoReader reader(state);
    FrameNormalizer normalizer;
    ReadyFrameQueue queue(1);
    CHECK(OpenStart(
        reader,
        path,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));

    FramePipelinePump pump(
        state,
        reader,
        normalizer,
        queue,
        Target(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));

    CHECK(PumpUntilAction(pump).status ==
          FramePipelinePumpStatus::Published);

    AcquireResult held = queue.tryAcquire(Context(state));
    CHECK(held.kind == AcquireResultKind::Acquired);
    CHECK(held.lease.has_value());

    const auto result = PumpUntilAction(pump);
    CHECK(result.status == FramePipelinePumpStatus::QueueDropped);
    CHECK(result.publishResult == PublishResult::DroppedFullLeased);
    CHECK(queue.size() == 1);
    CHECK(held.lease->valid());
    return true;
}

bool TestMediaReplacementInvalidatesQueuedGeneration(
    const std::string& firstPath,
    const std::string& secondPath) {
    FrameEngineState state;
    LocalVideoReader reader(state);
    FrameNormalizer normalizer;
    ReadyFrameQueue queue(2);
    CHECK(OpenStart(
        reader,
        firstPath,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));

    FramePipelinePump pump(
        state,
        reader,
        normalizer,
        queue,
        Target(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));

    CHECK(PumpUntilAction(pump).status ==
          FramePipelinePumpStatus::Published);
    const auto oldGeneration = state.mediaGeneration();

    CHECK(reader.open(
        secondPath,
        ReaderConfig(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)));
    CHECK(state.mediaGeneration() == oldGeneration + 1);

    AcquireResult acquired = queue.tryAcquire(Context(state));
    CHECK(acquired.kind == AcquireResultKind::NoEligibleFrame);
    CHECK(!acquired.lease.has_value());
    CHECK(queue.size() == 0);
    return true;
}

bool TestTimelineEpochChangeInvalidatesQueuedFrame(
    const std::string& path) {
    FrameEngineState state;
    LocalVideoReader reader(state);
    FrameNormalizer normalizer;
    ReadyFrameQueue queue(2);
    CHECK(OpenStart(
        reader,
        path,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));

    FramePipelinePump pump(
        state,
        reader,
        normalizer,
        queue,
        Target(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));

    CHECK(PumpUntilAction(pump).status ==
          FramePipelinePumpStatus::Published);
    const auto oldEpoch = state.timelineEpoch();

    CHECK(state.pause());
    CHECK(state.resume());
    CHECK(state.timelineEpoch() != oldEpoch);

    AcquireResult acquired = queue.tryAcquire(Context(state));
    CHECK(acquired.kind == AcquireResultKind::NoEligibleFrame);
    CHECK(!acquired.lease.has_value());
    CHECK(queue.size() == 0);
    return true;
}

bool TestConsumerFastPathIsQueueOnly(const std::string& path) {
    FrameEngineState state;
    LocalVideoReader reader(state);
    FrameNormalizer normalizer;
    ReadyFrameQueue queue(2);
    CHECK(OpenStart(
        reader,
        path,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));

    FramePipelinePump pump(
        state,
        reader,
        normalizer,
        queue,
        Target(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));

    CHECK(PumpUntilAction(pump).status ==
          FramePipelinePumpStatus::Published);

    const QueueContext consumerContext = Context(state);

    // Consumer fast path begins here. No LocalVideoReader, FrameNormalizer,
    // or FramePipelinePump call occurs during acquisition.
    AcquireResult acquired = queue.tryAcquire(consumerContext);

    CHECK(acquired.kind == AcquireResultKind::Acquired);
    CHECK(acquired.lease.has_value());
    CHECK(acquired.lease->valid());
    CHECK(acquired.lease->frameLease()->pixelBuffer() != nullptr);
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
    @autoreleasepool {
        const std::string fixture = UniqueFixturePath("main");
        const std::string oneFrame = UniqueFixturePath("one");
        const std::string replacement = UniqueFixturePath("replacement");
        const std::string rotated = UniqueFixturePath("rotated");
        const std::string metadataSparse =
            UniqueFixturePath("metadata-sparse");

        const CGAffineTransform rotatedTransform =
            CGAffineTransformMake(0, 1, -1, 0, 48, 0);

        if (!CreateLocalVideoFixture(fixture, 3) ||
            !CreateLocalVideoFixture(oneFrame, 1) ||
            !CreateLocalVideoFixture(replacement, 2) ||
            !CreateLocalVideoFixture(
                rotated,
                2,
                64,
                48,
                rotatedTransform) ||
            !CreateLocalVideoFixture(
                metadataSparse,
                2,
                64,
                48,
                CGAffineTransformIdentity,
                AVVideoCodecTypeJPEG)) {
            std::cerr << "Unable to create deterministic Stage D1 fixtures."
                      << std::endl;
            RemoveFixture(fixture);
            RemoveFixture(oneFrame);
            RemoveFixture(replacement);
            RemoveFixture(rotated);
            RemoveFixture(metadataSparse);
            return EXIT_FAILURE;
        }

        Run("Compatible 420v publishes and acquires",
            [&] { return TestCompatible420vPublishes(fixture); });
        Run("Compatible 420f publishes and acquires",
            [&] { return TestCompatible420fPublishes(fixture); });
        Run("Published sourcePTS correlates with acquire",
            [&] {
                return TestPublishedSourcePTSCorrelatesWithAcquire(
                    fixture);
            });
        Run("Identity survives complete pipeline",
            [&] { return TestIdentitySurvivesPipeline(fixture); });
        Run("Pixel buffer valid through queue lease",
            [&] { return TestPixelBufferValidThroughQueueLease(fixture); });
        Run("Width mismatch requires transform",
            [&] { return TestWidthMismatchTransformRequired(fixture); });
        Run("Height mismatch requires transform",
            [&] { return TestHeightMismatchTransformRequired(fixture); });
        Run("Pixel format mismatch requires transform",
            [&] {
                return TestPixelFormatMismatchTransformRequired(
                    fixture);
            });
        Run("Non-identity preferred transform requires transform",
            [&] { return TestNonIdentityTransformRequired(rotated); });
        Run("RequirePresent missing metadata does not publish",
            [&] {
                return TestRequirePresentMissingMetadataNoPublish(
                    metadataSparse);
            });
        Run("EOS without loop propagates without publish",
            [&] { return TestEOSWithoutLoopNoPublish(oneFrame); });
        Run("Loop restart explicitly propagated",
            [&] { return TestLoopRestartPropagated(oneFrame); });
        Run("Cancelled reader explicitly propagated",
            [&] { return TestCancelledPropagated(fixture); });
        Run("Reader failure explicitly propagated",
            [&] { return TestReaderFailurePropagated(oneFrame); });
        Run("Queue capacity remains bounded",
            [&] { return TestQueueCapacityRemainsBounded(fixture); });
        Run("Fully leased queue drops without blocking",
            [&] {
                return TestFullyLeasedQueueDropsWithoutBlocking(
                    fixture);
            });
        Run("Media replacement invalidates queued generation",
            [&] {
                return TestMediaReplacementInvalidatesQueuedGeneration(
                    fixture,
                    replacement);
            });
        Run("Timeline epoch change invalidates queued frame",
            [&] {
                return TestTimelineEpochChangeInvalidatesQueuedFrame(
                    fixture);
            });
        Run("Consumer fast path is queue only",
            [&] { return TestConsumerFastPathIsQueueOnly(fixture); });

        RemoveFixture(fixture);
        RemoveFixture(oneFrame);
        RemoveFixture(replacement);
        RemoveFixture(rotated);
        RemoveFixture(metadataSparse);

        std::cout << "Stage D1 tests run: " << gTestsRun
                  << ", failures: " << gFailures << std::endl;

        return gFailures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
    }
}
