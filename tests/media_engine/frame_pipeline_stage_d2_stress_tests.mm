#include "FramePipelinePump.h"

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

#include <cstdlib>
#include <cstring>
#include <functional>
#include <iostream>
#include <optional>
#include <string>
#include <unistd.h>

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

std::string ToStdString(NSString* value) {
    const char* utf8 = [value UTF8String];
    return utf8 == nullptr ? std::string{} : std::string(utf8);
}

std::string UniqueFixturePath(const char* suffix) {
    NSString* directory = NSTemporaryDirectory();
    NSString* name = [NSString
        stringWithFormat:@"vcam-stage-d2-%@-%d-%s.mov",
                         [[NSUUID UUID] UUIDString],
                         getpid(),
                         suffix];
    return ToStdString([directory stringByAppendingPathComponent:name]);
}

bool WaitForWriterInput(AVAssetWriterInput* input) {
    for (int attempt = 0; attempt < 10000; ++attempt) {
        if (input.readyForMoreMediaData) {
            return true;
        }
        [NSThread sleepForTimeInterval:0.001];
    }
    return false;
}

bool CreateLocalVideoFixture(const std::string& path,
                             int frameCount,
                             int width,
                             int height) {
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

        const int bitRate =
            width >= 1280 ? 4000000 : 150000;
        NSDictionary* compression = @{
            AVVideoAverageBitRateKey : @(bitRate)
        };
        NSDictionary* settings = @{
            AVVideoCodecKey : AVVideoCodecTypeH264,
            AVVideoWidthKey : @(width),
            AVVideoHeightKey : @(height),
            AVVideoCompressionPropertiesKey : compression,
        };

        AVAssetWriterInput* input =
            [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                               outputSettings:settings];
        input.expectsMediaDataInRealTime = NO;

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

        for (int index = 0; index < frameCount; ++index) {
            if (!WaitForWriterInput(input)) {
                return false;
            }

            CVPixelBufferRef pixelBuffer = nullptr;
            if (CVPixelBufferCreate(
                    kCFAllocatorDefault,
                    width,
                    height,
                    kCVPixelFormatType_32BGRA,
                    (__bridge CFDictionaryRef)attributes,
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
            std::memset(
                bytes,
                static_cast<unsigned char>(32 + (index % 7) * 24),
                bytesPerRow * rows);
            CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

            const BOOL appended =
                [adaptor appendPixelBuffer:pixelBuffer
                      withPresentationTime:CMTimeMake(index, 30)];
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
            dispatch_time(
                DISPATCH_TIME_NOW,
                static_cast<int64_t>(30 * NSEC_PER_SEC));
        if (dispatch_semaphore_wait(semaphore, timeout) != 0) {
            return false;
        }

        return writer.status == AVAssetWriterStatusCompleted;
    }
}

bool CreatePassthroughNoColorVideoFixture(
    const std::string& path,
    int frameCount = 2,
    int width = 64,
    int height = 48) {
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

        NSDictionary* attributes = @{
            (NSString*)kCVPixelBufferPixelFormatTypeKey :
                @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (NSString*)kCVPixelBufferWidthKey : @(width),
            (NSString*)kCVPixelBufferHeightKey : @(height),
            (NSString*)kCVPixelBufferIOSurfacePropertiesKey : @{},
        };

        CVPixelBufferRef hintBuffer = nullptr;
        if (CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                (__bridge CFDictionaryRef)attributes,
                &hintBuffer) != kCVReturnSuccess ||
            hintBuffer == nullptr) {
            return false;
        }

        CMVideoFormatDescriptionRef format = nullptr;
        const OSStatus formatStatus =
            CMVideoFormatDescriptionCreateForImageBuffer(
                kCFAllocatorDefault,
                hintBuffer,
                &format);
        CVPixelBufferRelease(hintBuffer);
        if (formatStatus != noErr || format == nullptr) {
            return false;
        }

        AVAssetWriterInput* input =
            [[AVAssetWriterInput alloc]
                initWithMediaType:AVMediaTypeVideo
                outputSettings:nil
                sourceFormatHint:format];
        if (input == nil || ![writer canAddInput:input]) {
            CFRelease(format);
            return false;
        }

        input.expectsMediaDataInRealTime = NO;
        input.mediaTimeScale = 30;
        [writer addInput:input];

        if (![writer startWriting]) {
            CFRelease(format);
            return false;
        }
        [writer startSessionAtSourceTime:kCMTimeZero];

        for (int index = 0; index < frameCount; ++index) {
            if (!WaitForWriterInput(input)) {
                CFRelease(format);
                return false;
            }

            CVPixelBufferRef pixelBuffer = nullptr;
            if (CVPixelBufferCreate(
                    kCFAllocatorDefault,
                    width,
                    height,
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    (__bridge CFDictionaryRef)attributes,
                    &pixelBuffer) != kCVReturnSuccess ||
                pixelBuffer == nullptr) {
                CFRelease(format);
                return false;
            }

            CVPixelBufferLockBaseAddress(pixelBuffer, 0);
            if (CVPixelBufferGetPlaneCount(pixelBuffer) < 2) {
                CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
                CVPixelBufferRelease(pixelBuffer);
                CFRelease(format);
                return false;
            }

            auto* yPlane = static_cast<unsigned char*>(
                CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0));
            auto* uvPlane = static_cast<unsigned char*>(
                CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1));
            const std::size_t yBytesPerRow =
                CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
            const std::size_t yRows =
                CVPixelBufferGetHeightOfPlane(pixelBuffer, 0);
            const std::size_t uvBytesPerRow =
                CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
            const std::size_t uvRows =
                CVPixelBufferGetHeightOfPlane(pixelBuffer, 1);

            std::memset(
                yPlane,
                static_cast<unsigned char>(32 + index * 16),
                yBytesPerRow * yRows);
            std::memset(uvPlane, 128, uvBytesPerRow * uvRows);
            CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

            CVBufferRemoveAttachment(
                pixelBuffer,
                kCVImageBufferColorPrimariesKey);
            CVBufferRemoveAttachment(
                pixelBuffer,
                kCVImageBufferTransferFunctionKey);
            CVBufferRemoveAttachment(
                pixelBuffer,
                kCVImageBufferYCbCrMatrixKey);

            CMSampleTimingInfo timing;
            timing.duration = CMTimeMake(1, 30);
            timing.presentationTimeStamp = CMTimeMake(index, 30);
            timing.decodeTimeStamp = kCMTimeInvalid;

            CMSampleBufferRef sample = nullptr;
            const OSStatus sampleStatus =
                CMSampleBufferCreateReadyWithImageBuffer(
                    kCFAllocatorDefault,
                    pixelBuffer,
                    format,
                    &timing,
                    &sample);
            CVPixelBufferRelease(pixelBuffer);

            if (sampleStatus != noErr || sample == nullptr) {
                CFRelease(format);
                return false;
            }

            const BOOL appended = [input appendSampleBuffer:sample];
            CFRelease(sample);

            if (!appended) {
                CFRelease(format);
                return false;
            }
        }

        [input markAsFinished];

        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        [writer finishWritingWithCompletionHandler:^{
            dispatch_semaphore_signal(semaphore);
        }];

        const dispatch_time_t timeout =
            dispatch_time(
                DISPATCH_TIME_NOW,
                static_cast<int64_t>(30 * NSEC_PER_SEC));
        const long waitResult =
            dispatch_semaphore_wait(semaphore, timeout);

        CFRelease(format);
        return waitResult == 0 &&
               writer.status == AVAssetWriterStatusCompleted;
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
    bool loopEnabled = false) {
    LocalVideoReaderConfig config;
    config.loopEnabled = loopEnabled;
    config.outputPixelFormat =
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    return config;
}

NormalizationTarget Target(
    std::size_t width = 64,
    std::size_t height = 48,
    ColorMetadataPolicy colorMetadata =
        ColorMetadataPolicy::PreserveSource) {
    NormalizationTarget target;
    target.width = width;
    target.height = height;
    target.pixelFormat =
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    target.orientation =
        OrientationRequirement::UprightIdentityTransform;
    target.colorMetadata = colorMetadata;
    return target;
}

QueueContext Context(const FrameEngineState& state) {
    return {
        state.mediaGeneration(),
        state.timelineEpoch(),
        std::nullopt,
    };
}

FramePipelinePumpResult PumpUntilAction(
    FramePipelinePump& pump,
    int maxCalls = 128) {
    for (int attempt = 0; attempt < maxCalls; ++attempt) {
        FramePipelinePumpResult result = pump.pumpOnce();
        if (result.status != FramePipelinePumpStatus::NotReady) {
            return result;
        }
    }
    return {};
}

bool ConsumePublished(
    ReadyFrameQueue& queue,
    const FrameEngineState& state,
    const FramePipelinePumpResult& result,
    std::size_t expectedWidth,
    std::size_t expectedHeight) {
    if (result.status != FramePipelinePumpStatus::Published ||
        !result.frameIdentity.has_value()) {
        return false;
    }

    AcquireResult acquired = queue.tryAcquire(Context(state));
    if (acquired.kind != AcquireResultKind::Acquired ||
        !acquired.lease.has_value() ||
        !acquired.lease->valid() ||
        acquired.lease->frameLease() == nullptr ||
        acquired.lease->frameLease()->pixelBuffer() == nullptr ||
        acquired.lease->frameLease()->width() != expectedWidth ||
        acquired.lease->frameLease()->height() != expectedHeight ||
        acquired.lease->frameLease()->identity().sequence !=
            result.frameIdentity->sequence ||
        acquired.lease->frameLease()->identity().mediaGeneration !=
            state.mediaGeneration() ||
        acquired.lease->frameLease()->identity().timelineEpoch !=
            state.timelineEpoch()) {
        return false;
    }

    return true;
}

bool TestOpenStartEOSReopenSoak(
    const std::string& firstPath,
    const std::string& secondPath) {
    FrameEngineState state;
    LocalVideoReader reader(state);
    FrameNormalizer normalizer;
    ReadyFrameQueue queue(4);

    for (int cycle = 0; cycle < 20; ++cycle) {
        CHECK(reader.open(firstPath, ReaderConfig(false)));
        const std::uint64_t generation = state.mediaGeneration();
        CHECK(reader.start());

        FramePipelinePump pump(
            state,
            reader,
            normalizer,
            queue,
            Target());

        int published = 0;
        bool sawEOS = false;
        for (int call = 0; call < 512; ++call) {
            const FramePipelinePumpResult result = pump.pumpOnce();
            if (result.status == FramePipelinePumpStatus::NotReady) {
                continue;
            }
            if (result.status == FramePipelinePumpStatus::Published) {
                CHECK(ConsumePublished(queue, state, result, 64, 48));
                CHECK(queue.size() <= queue.capacity());
                ++published;
                continue;
            }
            if (result.status == FramePipelinePumpStatus::EndOfStream) {
                sawEOS = true;
                break;
            }
            CHECK(false);
        }

        CHECK(sawEOS);
        CHECK(published == 6);
        CHECK(state.mediaGeneration() == generation);
        reader.stop();

        CHECK(reader.open(secondPath, ReaderConfig(false)));
        CHECK(state.mediaGeneration() == generation + 1);
        CHECK(reader.start());

        FramePipelinePump replacementPump(
            state,
            reader,
            normalizer,
            queue,
            Target());

        const FramePipelinePumpResult first =
            PumpUntilAction(replacementPump);
        CHECK(first.status == FramePipelinePumpStatus::Published);
        CHECK(ConsumePublished(queue, state, first, 64, 48));
        reader.stop();
    }

    return true;
}

bool TestReplacementAndEpochChurn(
    const std::string& firstPath,
    const std::string& secondPath) {
    FrameEngineState state;
    LocalVideoReader reader(state);
    FrameNormalizer normalizer;
    ReadyFrameQueue queue(3);

    for (int cycle = 0; cycle < 40; ++cycle) {
        CHECK(reader.open(firstPath, ReaderConfig(false)));
        CHECK(reader.start());

        FramePipelinePump pump(
            state,
            reader,
            normalizer,
            queue,
            Target());

        CHECK(PumpUntilAction(pump).status ==
              FramePipelinePumpStatus::Published);
        const std::uint64_t oldGeneration =
            state.mediaGeneration();

        CHECK(reader.open(secondPath, ReaderConfig(false)));
        CHECK(state.mediaGeneration() == oldGeneration + 1);

        const AcquireResult oldGenerationAcquire =
            queue.tryAcquire(Context(state));
        CHECK(oldGenerationAcquire.kind ==
              AcquireResultKind::NoEligibleFrame);
        CHECK(!oldGenerationAcquire.lease.has_value());

        CHECK(reader.start());
        CHECK(PumpUntilAction(pump).status ==
              FramePipelinePumpStatus::Published);

        const std::uint64_t oldEpoch = state.timelineEpoch();
        CHECK(state.pause());
        CHECK(state.resume());
        CHECK(state.timelineEpoch() != oldEpoch);

        const AcquireResult oldEpochAcquire =
            queue.tryAcquire(Context(state));
        CHECK(oldEpochAcquire.kind ==
              AcquireResultKind::NoEligibleFrame);
        CHECK(!oldEpochAcquire.lease.has_value());
        CHECK(queue.size() == 0);

        reader.stop();
    }

    return true;
}

bool TestLoopSoak(const std::string& loopPath) {
    FrameEngineState state;
    LocalVideoReader reader(state);
    FrameNormalizer normalizer;
    ReadyFrameQueue queue(4);

    CHECK(reader.open(loopPath, ReaderConfig(true)));
    CHECK(reader.start());

    FramePipelinePump pump(
        state,
        reader,
        normalizer,
        queue,
        Target());

    int loopRestarts = 0;
    int published = 0;

    for (int call = 0; call < 2000 && loopRestarts < 25; ++call) {
        const FramePipelinePumpResult result = pump.pumpOnce();
        if (result.status == FramePipelinePumpStatus::NotReady) {
            continue;
        }
        if (result.status == FramePipelinePumpStatus::Published) {
            CHECK(ConsumePublished(queue, state, result, 64, 48));
            CHECK(queue.size() <= queue.capacity());
            ++published;
            continue;
        }
        if (result.status == FramePipelinePumpStatus::LoopRestarted) {
            ++loopRestarts;
            CHECK(
                state.loopIteration() ==
                static_cast<std::uint64_t>(loopRestarts));
            continue;
        }
        CHECK(false);
    }

    CHECK(loopRestarts == 25);
    CHECK(published >= 50);
    reader.stop();
    return true;
}

bool TestFailOpenMatrix(
    const std::string& normalPath,
    const std::string& oneFramePath,
    const std::string& noColorPath) {
    {
        FrameEngineState state;
        LocalVideoReader reader(state);
        FrameNormalizer normalizer;
        ReadyFrameQueue queue(2);
        CHECK(reader.open(normalPath, ReaderConfig(false)));
        CHECK(reader.start());

        FramePipelinePump pump(
            state,
            reader,
            normalizer,
            queue,
            Target(65, 48));
        const auto result = PumpUntilAction(pump);
        CHECK(result.status ==
              FramePipelinePumpStatus::TransformRequired);
        CHECK(queue.size() == 0);
    }

    {
        FrameEngineState state;
        LocalVideoReader reader(state);
        FrameNormalizer normalizer;
        ReadyFrameQueue queue(2);
        CHECK(reader.open(noColorPath, ReaderConfig(false)));
        CHECK(reader.start());

        FramePipelinePump pump(
            state,
            reader,
            normalizer,
            queue,
            Target(
                64,
                48,
                ColorMetadataPolicy::RequirePresent));
        const auto result = PumpUntilAction(pump);
        CHECK(result.status ==
              FramePipelinePumpStatus::NormalizationRejected);
        CHECK(result.normalizationStatus ==
              NormalizationStatus::MissingRequiredColorMetadata);
        CHECK(queue.size() == 0);
    }

    {
        FrameEngineState state;
        LocalVideoReader reader(state);
        FrameNormalizer normalizer;
        ReadyFrameQueue queue(2);
        CHECK(reader.open(oneFramePath, ReaderConfig(false)));
        CHECK(reader.start());

        FramePipelinePump pump(
            state,
            reader,
            normalizer,
            queue,
            Target());

        const auto first = PumpUntilAction(pump);
        CHECK(first.status == FramePipelinePumpStatus::Published);
        CHECK(ConsumePublished(queue, state, first, 64, 48));
        (void)queue.tryAcquire(Context(state));

        const auto terminal = PumpUntilAction(pump);
        CHECK(terminal.status ==
              FramePipelinePumpStatus::EndOfStream);
        CHECK(queue.size() == 0);
    }

    {
        FrameEngineState state;
        LocalVideoReader reader(state);
        FrameNormalizer normalizer;
        ReadyFrameQueue queue(2);
        CHECK(reader.open(normalPath, ReaderConfig(false)));
        CHECK(reader.start());

        FramePipelinePump pump(
            state,
            reader,
            normalizer,
            queue,
            Target());

        reader.stop();
        const auto result = pump.pumpOnce();
        CHECK(result.status == FramePipelinePumpStatus::Cancelled);
        CHECK(queue.size() == 0);
    }

    {
        FrameEngineState state;
        LocalVideoReader reader(state);
        FrameNormalizer normalizer;
        ReadyFrameQueue queue(2);
        CHECK(reader.open(oneFramePath, ReaderConfig(false)));
        CHECK(reader.start());

        FramePipelinePump pump(
            state,
            reader,
            normalizer,
            queue,
            Target());

        const auto first = PumpUntilAction(pump);
        CHECK(first.status == FramePipelinePumpStatus::Published);
        CHECK(ConsumePublished(queue, state, first, 64, 48));
        (void)queue.tryAcquire(Context(state));

        state.markReaderFailed(ReaderErrorCode::ReadFailed);
        state.markPlaybackFailed();

        const auto result = PumpUntilAction(pump);
        CHECK(result.status ==
              FramePipelinePumpStatus::ReaderFailed);
        CHECK(result.status !=
              FramePipelinePumpStatus::EndOfStream);
        CHECK(queue.size() == 0);
    }

    {
        FrameEngineState state;
        LocalVideoReader reader(state);
        FrameNormalizer normalizer;
        ReadyFrameQueue queue(1);
        CHECK(reader.open(normalPath, ReaderConfig(false)));
        CHECK(reader.start());

        FramePipelinePump pump(
            state,
            reader,
            normalizer,
            queue,
            Target());

        CHECK(PumpUntilAction(pump).status ==
              FramePipelinePumpStatus::Published);
        AcquireResult held = queue.tryAcquire(Context(state));
        CHECK(held.kind == AcquireResultKind::Acquired);
        CHECK(held.lease.has_value());

        const auto dropped = PumpUntilAction(pump);
        CHECK(dropped.status ==
              FramePipelinePumpStatus::QueueDropped);
        CHECK(dropped.publishResult ==
              PublishResult::DroppedFullLeased);
        CHECK(held.lease->valid());
        CHECK(queue.size() == 1);
    }

    return true;
}

bool Test720p30HostSmoke(const std::string& path) {
    FrameEngineState state;
    LocalVideoReader reader(state);
    FrameNormalizer normalizer;
    ReadyFrameQueue queue(8);

    CHECK(reader.open(path, ReaderConfig(false)));
    CHECK(reader.start());

    FramePipelinePump pump(
        state,
        reader,
        normalizer,
        queue,
        Target(1280, 720));

    int published = 0;
    bool sawEOS = false;
    CMTime previousPTS = kCMTimeInvalid;

    for (int call = 0; call < 1024; ++call) {
        const FramePipelinePumpResult result = pump.pumpOnce();

        if (result.status == FramePipelinePumpStatus::NotReady) {
            continue;
        }

        if (result.status == FramePipelinePumpStatus::Published) {
            CHECK(result.frameTiming.has_value());
            CHECK(CMTIME_IS_VALID(result.frameTiming->sourcePTS));
            if (CMTIME_IS_VALID(previousPTS)) {
                CHECK(CMTimeCompare(
                          result.frameTiming->sourcePTS,
                          previousPTS) >= 0);
            }
            previousPTS = result.frameTiming->sourcePTS;

            CHECK(ConsumePublished(
                queue,
                state,
                result,
                1280,
                720));
            CHECK(queue.size() <= queue.capacity());
            ++published;
            continue;
        }

        if (result.status == FramePipelinePumpStatus::EndOfStream) {
            sawEOS = true;
            break;
        }

        CHECK(false);
    }

    CHECK(sawEOS);
    CHECK(published == 30);
    CHECK(state.readerIsCompletedEOS());
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
        const std::string first = UniqueFixturePath("first");
        const std::string second = UniqueFixturePath("second");
        const std::string one = UniqueFixturePath("one");
        const std::string loop = UniqueFixturePath("loop");
        const std::string noColor = UniqueFixturePath("no-color");
        const std::string smoke720 = UniqueFixturePath("720p30");

        if (!CreateLocalVideoFixture(first, 6, 64, 48) ||
            !CreateLocalVideoFixture(second, 4, 64, 48) ||
            !CreateLocalVideoFixture(one, 1, 64, 48) ||
            !CreateLocalVideoFixture(loop, 2, 64, 48) ||
            !CreatePassthroughNoColorVideoFixture(noColor) ||
            !CreateLocalVideoFixture(smoke720, 30, 1280, 720)) {
            std::cerr << "Unable to create deterministic D2 fixtures."
                      << std::endl;
            RemoveFixture(first);
            RemoveFixture(second);
            RemoveFixture(one);
            RemoveFixture(loop);
            RemoveFixture(noColor);
            RemoveFixture(smoke720);
            return EXIT_FAILURE;
        }

        Run("open/start/EOS/reopen soak",
            [&] {
                return TestOpenStartEOSReopenSoak(
                    first,
                    second);
            });
        Run("replacement and epoch churn",
            [&] {
                return TestReplacementAndEpochChurn(
                    first,
                    second);
            });
        Run("loop soak",
            [&] { return TestLoopSoak(loop); });
        Run("fail-open matrix",
            [&] {
                return TestFailOpenMatrix(
                    first,
                    one,
                    noColor);
            });
        Run("720p30 host smoke",
            [&] { return Test720p30HostSmoke(smoke720); });

        RemoveFixture(first);
        RemoveFixture(second);
        RemoveFixture(one);
        RemoveFixture(loop);
        RemoveFixture(noColor);
        RemoveFixture(smoke720);

        std::cout << "Stage D2 pipeline stress tests run: "
                  << gTestsRun
                  << ", failures: " << gFailures << std::endl;

        return gFailures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
    }
}
