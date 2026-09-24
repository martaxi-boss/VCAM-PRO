#include "LocalVideoReader.h"

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

#include <cstdio>
#include <cstdlib>
#include <functional>
#include <iostream>
#include <optional>
#include <string>
#include <utility>

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
        stringWithFormat:@"vcam-stage-b-%@-%d-%s.mov",
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

bool CreateLocalVideoFixture(const std::string& path,
                             int frameCount = 3,
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

        NSDictionary* compression = @{
            AVVideoAverageBitRateKey : @(150000)
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

        // BGRA is TEST-ONLY for deterministic AVAssetWriter fixture creation.
        // It is not a VCAM PRO production output-format decision.
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

LocalVideoReaderConfig Config(OSType pixelFormat,
                              bool loopEnabled = false) {
    LocalVideoReaderConfig config;
    config.loopEnabled = loopEnabled;
    config.outputPixelFormat = pixelFormat;
    return config;
}

ReadResult ReadUntilFrameOrTerminal(LocalVideoReader& reader,
                                    int maxCalls = 16) {
    for (int attempt = 0; attempt < maxCalls; ++attempt) {
        ReadResult result = reader.readNext();
        if (result.kind != ReadResultKind::NotReady) {
            return result;
        }
    }
    return {};
}

ReadResult ReadUntilEOSOrLoop(LocalVideoReader& reader,
                              int maxCalls = 32) {
    for (int attempt = 0; attempt < maxCalls; ++attempt) {
        ReadResult result = reader.readNext();
        if (result.kind == ReadResultKind::EndOfStream ||
            result.kind == ReadResultKind::LoopRestarted ||
            result.kind == ReadResultKind::Failed ||
            result.kind == ReadResultKind::Cancelled) {
            return result;
        }
    }
    return {};
}

bool TestMissingAndRemotePathsFail(const std::string&) {
    FrameEngineState state;
    LocalVideoReader reader(state);

    CHECK(!reader.open("/definitely/not/a/vcam/file.mov",
                       Config(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)));
    CHECK(reader.lastErrorCode() == ReaderErrorCode::InitializationFailed);
    CHECK(state.mediaGeneration() == 0);

    CHECK(!reader.open("https://example.invalid/video.mov",
                       Config(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)));
    CHECK(reader.lastErrorCode() == ReaderErrorCode::InitializationFailed);
    CHECK(state.mediaGeneration() == 0);
    return true;
}

bool TestOpenStartAndFrame420v(const std::string& path) {
    FrameEngineState state;
    LocalVideoReader reader(state);

    CHECK(reader.open(
        path,
        Config(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)));
    CHECK(reader.isOpen());
    CHECK(state.mediaGeneration() == 1);
    CHECK(state.readerStatus().state == ReaderState::Ready);

    const auto info = reader.sourceInfo();
    CHECK(info.has_value());
    CHECK(info->naturalSize.width == 64);
    CHECK(info->naturalSize.height == 48);
    CHECK(info->outputPixelFormat ==
          kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);

    const auto epochBeforeStart = state.timelineEpoch();
    CHECK(reader.start());
    CHECK(reader.isStarted());
    CHECK(state.timelineEpoch() == epochBeforeStart + 1);
    CHECK(state.readerStatus().state == ReaderState::Reading);

    ReadResult result = ReadUntilFrameOrTerminal(reader);
    CHECK(result.kind == ReadResultKind::Frame);
    CHECK(result.frame.has_value());

    PreparedFrame& frame = *result.frame;
    CHECK(frame.pixelBuffer() != nullptr);
    CHECK(frame.width() == 64);
    CHECK(frame.height() == 48);
    CHECK(frame.pixelFormat() ==
          kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    CHECK(frame.width() == CVPixelBufferGetWidth(frame.pixelBuffer()));
    CHECK(frame.height() == CVPixelBufferGetHeight(frame.pixelBuffer()));
    CHECK(frame.pixelFormat() ==
          CVPixelBufferGetPixelFormatType(frame.pixelBuffer()));
    CHECK(frame.orientation() == OrientationState::SourceNotNormalized);
    CHECK(CMTIME_IS_VALID(frame.timing().sourcePTS));
    CHECK(CMTimeCompare(frame.timing().sourcePTS, kCMTimeZero) == 0);
    CHECK(CMTIME_IS_INVALID(frame.timing().presentationTimestamp));
    CHECK(frame.isInternallyConsistent());
    CHECK(frame.isEligible(state.mediaGeneration(), state.timelineEpoch()));

    // readNext() has already released its internal CMSampleBuffer here.
    CHECK(CVPixelBufferGetWidth(frame.pixelBuffer()) == 64);
    CHECK(frame.acquireLease(state.mediaGeneration(),
                             state.timelineEpoch()).has_value());
    return true;
}

bool Test420fOutput(const std::string& path) {
    FrameEngineState state;
    LocalVideoReader reader(state);

    CHECK(reader.open(
        path,
        Config(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)));
    CHECK(reader.start());

    ReadResult result = ReadUntilFrameOrTerminal(reader);
    CHECK(result.kind == ReadResultKind::Frame);
    CHECK(result.frame.has_value());
    CHECK(result.frame->pixelFormat() ==
          kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
    CHECK(result.frame->pixelFormat() ==
          CVPixelBufferGetPixelFormatType(result.frame->pixelBuffer()));
    return true;
}

bool TestEOSWithoutLoop(const std::string& path) {
    FrameEngineState state;
    LocalVideoReader reader(state);

    CHECK(reader.open(
        path,
        Config(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, false)));
    CHECK(reader.start());

    const ReadResult terminal = ReadUntilEOSOrLoop(reader);
    CHECK(terminal.kind == ReadResultKind::EndOfStream);
    CHECK(state.readerStatus().state == ReaderState::Completed);
    CHECK(state.readerIsCompletedEOS());
    CHECK(state.playbackState() == PlaybackState::Ended);
    CHECK(state.loopIteration() == 0);
    return true;
}

bool TestLoopRestartAndIteration(const std::string& path) {
    FrameEngineState state;
    LocalVideoReader reader(state);

    CHECK(reader.open(
        path,
        Config(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, true)));
    CHECK(reader.start());

    const auto epochBeforeLoop = state.timelineEpoch();
    const ReadResult terminal = ReadUntilEOSOrLoop(reader);

    CHECK(terminal.kind == ReadResultKind::LoopRestarted);
    CHECK(state.loopIteration() == 1);
    CHECK(state.timelineEpoch() == epochBeforeLoop);
    CHECK(state.readerStatus().state == ReaderState::Reading);

    ReadResult firstAfterLoop = ReadUntilFrameOrTerminal(reader);
    CHECK(firstAfterLoop.kind == ReadResultKind::Frame);
    CHECK(firstAfterLoop.frame.has_value());
    CHECK(firstAfterLoop.frame->identity().loopIteration == 1);
    CHECK(firstAfterLoop.frame->identity().timelineEpoch ==
          epochBeforeLoop);
    return true;
}

bool TestCancelIsNotEOS(const std::string& path) {
    FrameEngineState state;
    LocalVideoReader reader(state);

    CHECK(reader.open(
        path,
        Config(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)));
    CHECK(reader.start());

    reader.stop();

    CHECK(state.readerStatus().state == ReaderState::Cancelled);
    CHECK(!state.readerIsCompletedEOS());

    const ReadResult result = reader.readNext();
    CHECK(result.kind == ReadResultKind::Cancelled);
    CHECK(result.kind != ReadResultKind::EndOfStream);
    return true;
}

bool TestFailedStateIsNotEOS(const std::string&) {
    FrameEngineState state;
    state.selectOrReplaceMedia();
    CHECK(state.markReaderReady());
    CHECK(state.beginReading());

    state.markReaderFailed(ReaderErrorCode::ReadFailed);

    CHECK(state.readerStatus().state == ReaderState::Failed);
    CHECK(!state.readerIsCompletedEOS());
    CHECK(!state.canLoopRestart());
    return true;
}

bool TestMediaReplacementInvalidatesOldFrame(
    const std::string& firstPath,
    const std::string& secondPath) {
    FrameEngineState state;
    LocalVideoReader reader(state);

    CHECK(reader.open(
        firstPath,
        Config(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)));
    CHECK(reader.start());

    ReadResult first = ReadUntilFrameOrTerminal(reader);
    CHECK(first.kind == ReadResultKind::Frame);
    CHECK(first.frame.has_value());

    PreparedFrame oldFrame = std::move(*first.frame);
    const auto oldGeneration = state.mediaGeneration();

    CHECK(reader.open(
        secondPath,
        Config(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)));

    CHECK(state.mediaGeneration() == oldGeneration + 1);
    CHECK(state.loopIteration() == 0);
    CHECK(!oldFrame.isEligible(state.mediaGeneration(),
                               state.timelineEpoch()));
    CHECK(state.readerStatus().state == ReaderState::Ready);
    return true;
}

bool TestUnsupportedFormatRejected(const std::string& path) {
    FrameEngineState state;
    LocalVideoReader reader(state);

    CHECK(!reader.open(path, Config(kCVPixelFormatType_32BGRA)));
    CHECK(reader.lastErrorCode() == ReaderErrorCode::Unsupported);
    CHECK(state.mediaGeneration() == 0);
    return true;
}

bool TestReadBeforeStartIsNotReady(const std::string& path) {
    FrameEngineState state;
    LocalVideoReader reader(state);

    CHECK(reader.open(
        path,
        Config(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)));

    const ReadResult result = reader.readNext();
    CHECK(result.kind == ReadResultKind::NotReady);
    CHECK(result.kind != ReadResultKind::EndOfStream);
    return true;
}

void Run(const std::string& name,
         const std::function<bool()>& test) {
    ++gTestsRun;
    if (!test()) {
        ++gFailures;
        std::cerr << "[FAIL] " << name << std::endl;
        return;
    }
    std::cout << "[PASS] " << name << std::endl;
}

}  // namespace

int main() {
    @autoreleasepool {
        const std::string fixtureA = UniqueFixturePath("a");
        const std::string fixtureB = UniqueFixturePath("b");

        if (!CreateLocalVideoFixture(fixtureA) ||
            !CreateLocalVideoFixture(fixtureB, 4)) {
            std::cerr << "Unable to create deterministic local video fixture."
                      << std::endl;
            RemoveFixture(fixtureA);
            RemoveFixture(fixtureB);
            return EXIT_FAILURE;
        }

        Run("Missing and remote paths fail",
            [&] { return TestMissingAndRemotePathsFail(fixtureA); });
        Run("Open/start/frame 420v",
            [&] { return TestOpenStartAndFrame420v(fixtureA); });
        Run("420f output",
            [&] { return Test420fOutput(fixtureA); });
        Run("EOS without loop",
            [&] { return TestEOSWithoutLoop(fixtureA); });
        Run("Loop restart and iteration",
            [&] { return TestLoopRestartAndIteration(fixtureA); });
        Run("Cancelled reader is not EOS",
            [&] { return TestCancelIsNotEOS(fixtureA); });
        Run("Failed reader state is not EOS",
            [&] { return TestFailedStateIsNotEOS(fixtureA); });
        Run("Media replacement invalidates old frame",
            [&] {
                return TestMediaReplacementInvalidatesOldFrame(
                    fixtureA,
                    fixtureB);
            });
        Run("Unsupported output format rejected",
            [&] { return TestUnsupportedFormatRejected(fixtureA); });
        Run("Read before start is NotReady",
            [&] { return TestReadBeforeStartIsNotReady(fixtureA); });

        RemoveFixture(fixtureA);
        RemoveFixture(fixtureB);

        std::cout << "Stage B tests run: " << gTestsRun
                  << ", failures: " << gFailures << std::endl;

        return gFailures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
    }
}
