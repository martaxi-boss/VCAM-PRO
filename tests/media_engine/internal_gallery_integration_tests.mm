#include "FrameEngineState.h"
#include "FrameNormalizer.h"
#include "FramePipelinePump.h"
#include "FrameTransformer.h"
#include "LocalPhotoReader.h"
#include "LocalVideoReader.h"
#include "ReadyFrameQueue.h"
#include "SelectionCompletionGate.h"

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

#include <CoreGraphics/CoreGraphics.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

#include <cstdlib>
#include <cstring>
#include <functional>
#include <iostream>
#include <string>

namespace {
using namespace vcam::control;
using namespace vcam::frame_engine;
using namespace vcam::media_engine;

int gTestsRun = 0;
int gFailures = 0;

#define CHECK(condition) do { if (!(condition)) {     std::cerr << "CHECK failed at " << __FILE__ << ":" << __LINE__               << ": " #condition << std::endl; return false; } } while (false)

std::string ToStd(NSString* value) {
    const char* utf8 = value.UTF8String;
    return utf8 == nullptr ? std::string{} : std::string(utf8);
}

std::string TempPath(NSString* extension) {
    NSString* name =
        [NSString stringWithFormat:@"vcam-gallery-%@.%@",
            NSUUID.UUID.UUIDString, extension];
    return ToStd([NSTemporaryDirectory() stringByAppendingPathComponent:name]);
}

bool CreatePhoto(const std::string& path) {
    constexpr std::size_t width = 64;
    constexpr std::size_t height = 48;
    std::uint8_t bytes[width * height * 4];
    std::memset(bytes, 180, sizeof(bytes));

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(
        bytes, width, height, 8, width * 4, colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (context == nullptr) return false;

    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (image == nullptr) return false;

    NSURL* url = [NSURL fileURLWithPath:
        [NSString stringWithUTF8String:path.c_str()]];
    CGImageDestinationRef destination =
        CGImageDestinationCreateWithURL(
            (__bridge CFURLRef)url, CFSTR("public.png"), 1, nullptr);
    if (destination == nullptr) {
        CGImageRelease(image);
        return false;
    }

    CGImageDestinationAddImage(destination, image, nullptr);
    const bool ok = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(image);
    return ok;
}

bool WaitForWriterInput(AVAssetWriterInput* input) {
    for (int attempt = 0; attempt < 5000; ++attempt) {
        if (input.readyForMoreMediaData) return true;
        [NSThread sleepForTimeInterval:0.001];
    }
    return false;
}

bool CreateVideo(const std::string& path, int frameCount = 3) {
    NSString* nsPath = [NSString stringWithUTF8String:path.c_str()];
    [[NSFileManager defaultManager] removeItemAtPath:nsPath error:nil];
    NSURL* url = [NSURL fileURLWithPath:nsPath];

    AVAssetWriter* writer =
        [[AVAssetWriter alloc] initWithURL:url
                                  fileType:AVFileTypeQuickTimeMovie
                                     error:nil];
    if (writer == nil) return false;

    NSDictionary* settings = @{
        AVVideoCodecKey : AVVideoCodecTypeH264,
        AVVideoWidthKey : @64,
        AVVideoHeightKey : @48,
        AVVideoCompressionPropertiesKey :
            @{ AVVideoAverageBitRateKey : @150000 }
    };
    AVAssetWriterInput* input =
        [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                           outputSettings:settings];
    NSDictionary* attributes = @{
        (NSString*)kCVPixelBufferPixelFormatTypeKey :
            @(kCVPixelFormatType_32BGRA),
        (NSString*)kCVPixelBufferWidthKey : @64,
        (NSString*)kCVPixelBufferHeightKey : @48
    };
    AVAssetWriterInputPixelBufferAdaptor* adaptor =
        [AVAssetWriterInputPixelBufferAdaptor
            assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
            sourcePixelBufferAttributes:attributes];

    if (![writer canAddInput:input]) return false;
    [writer addInput:input];
    if (![writer startWriting]) return false;
    [writer startSessionAtSourceTime:kCMTimeZero];

    for (int index = 0; index < frameCount; ++index) {
        if (!WaitForWriterInput(input)) return false;

        CVPixelBufferRef buffer = nullptr;
        if (CVPixelBufferPoolCreatePixelBuffer(
                kCFAllocatorDefault, adaptor.pixelBufferPool, &buffer)
                != kCVReturnSuccess || buffer == nullptr) {
            return false;
        }

        CVPixelBufferLockBaseAddress(buffer, 0);
        std::memset(
            CVPixelBufferGetBaseAddress(buffer),
            40 + index * 20,
            CVPixelBufferGetBytesPerRow(buffer) *
                CVPixelBufferGetHeight(buffer));
        CVPixelBufferUnlockBaseAddress(buffer, 0);

        const BOOL ok =
            [adaptor appendPixelBuffer:buffer
                  withPresentationTime:CMTimeMake(index, 30)];
        CVPixelBufferRelease(buffer);
        if (!ok) return false;
    }

    [input markAsFinished];
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{
        dispatch_semaphore_signal(semaphore);
    }];
    if (dispatch_semaphore_wait(
            semaphore,
            dispatch_time(DISPATCH_TIME_NOW,
                static_cast<int64_t>(10 * NSEC_PER_SEC))) != 0) {
        return false;
    }
    return writer.status == AVAssetWriterStatusCompleted;
}

LocalPhotoReaderConfig PhotoConfig() {
    LocalPhotoReaderConfig config;
    config.cadenceNumerator = 30;
    config.cadenceDenominator = 1;
    config.outputPixelFormat =
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    return config;
}

LocalVideoReaderConfig VideoConfig(bool loop) {
    LocalVideoReaderConfig config;
    config.loopEnabled = loop;
    config.outputPixelFormat =
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    return config;
}

NormalizationTarget Target() {
    NormalizationTarget target;
    target.width = 64;
    target.height = 48;
    target.pixelFormat =
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    target.orientation =
        OrientationRequirement::UprightIdentityTransform;
    target.colorMetadata =
        ColorMetadataPolicy::PreserveSource;
    return target;
}

ReadResult ReadUntilTerminal(LocalVideoReader& reader) {
    for (int i = 0; i < 32; ++i) {
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

bool Test1() {
    FrameEngineState state;
    CHECK(!state.hasMedia());
    CHECK(state.playbackState() == PlaybackState::Empty);
    return true;
}
bool Test2(const std::string& video) {
    FrameEngineState state;
    LocalVideoReader reader(state);
    CHECK(reader.open(video, VideoConfig(false)));
    CHECK(state.mediaGeneration() == 1);
    return true;
}
bool Test3(const std::string& video) {
    FrameEngineState state;
    LocalVideoReader reader(state);
    CHECK(reader.open(video, VideoConfig(false)));
    CHECK(reader.sourceInfo().has_value());
    return true;
}
bool Test4(const std::string& video) {
    FrameEngineState state;
    LocalVideoReader reader(state);
    FrameNormalizer normalizer;
    FrameTransformer transformer;
    ReadyFrameQueue queue(3);
    CHECK(reader.open(video, VideoConfig(false)));
    CHECK(reader.start());
    FramePipelinePump pump(
        state, reader, normalizer, transformer, queue, Target());
    FramePipelinePumpResult result;
    for (int i = 0; i < 16; ++i) {
        result = pump.pumpOnce();
        if (result.status != FramePipelinePumpStatus::NotReady) break;
    }
    CHECK(result.status == FramePipelinePumpStatus::Published);
    CHECK(queue.size() == 1);
    return true;
}
bool Test5(const std::string& video) {
    FrameEngineState state;
    LocalVideoReader reader(state);
    CHECK(reader.open(video, VideoConfig(true)));
    CHECK(reader.start());
    CHECK(ReadUntilTerminal(reader).kind == ReadResultKind::LoopRestarted);
    return true;
}
bool Test6(const std::string& video) {
    FrameEngineState state;
    LocalVideoReader reader(state);
    CHECK(reader.open(video, VideoConfig(false)));
    CHECK(reader.start());
    CHECK(ReadUntilTerminal(reader).kind == ReadResultKind::EndOfStream);
    return true;
}
bool Test7(const std::string& photo) {
    FrameEngineState state;
    LocalPhotoReader reader(state);
    CHECK(reader.open(photo, PhotoConfig()));
    CHECK(state.mediaGeneration() == 1);
    return true;
}
bool Test8(const std::string& photo) {
    FrameEngineState state;
    LocalPhotoReader reader(state);
    CHECK(reader.open(photo, PhotoConfig()));
    CHECK(reader.start());
    ReadResult result = reader.readNext();
    CHECK(result.kind == ReadResultKind::Frame);
    CHECK(result.frame.has_value());
    CHECK(result.frame->orientation() == OrientationState::Normalized);
    return true;
}
bool Test9(const std::string& photo) {
    FrameEngineState state;
    LocalPhotoReader reader(state);
    CHECK(reader.open(photo, PhotoConfig()));
    CHECK(reader.decodeCount() == 1);
    CHECK(reader.start());
    ReadResult a = reader.readNext();
    ReadResult b = reader.readNext();
    CHECK(a.frame.has_value() && b.frame.has_value());
    CHECK(a.frame->pixelBuffer() == b.frame->pixelBuffer());
    CHECK(reader.decodeCount() == 1);
    return true;
}
bool Test10(const std::string& photo) {
    FrameEngineState state;
    LocalPhotoReader reader(state);
    CHECK(reader.open(photo, PhotoConfig()));
    CHECK(reader.start());
    ReadResult a = reader.readNext();
    ReadResult b = reader.readNext();
    CHECK(a.frame.has_value() && b.frame.has_value());
    CHECK(CMTimeCompare(b.frame->timing().sourcePTS,
                        a.frame->timing().sourcePTS) > 0);
    CHECK(CMTimeCompare(a.frame->timing().duration,
                        CMTimeMake(1, 30)) == 0);
    return true;
}
bool Test11(const std::string& photo) {
    FrameEngineState state;
    LocalPhotoReader reader(state);
    FrameNormalizer normalizer;
    FrameTransformer transformer;
    ReadyFrameQueue queue(3);
    CHECK(reader.open(photo, PhotoConfig()));
    CHECK(reader.start());
    FramePipelinePump pump(
        state, reader, normalizer, transformer, queue, Target());
    CHECK(pump.pumpOnce().status == FramePipelinePumpStatus::Published);
    CHECK(queue.size() == 1);
    return true;
}
bool Test12(const std::string& video, const std::string& photo) {
    FrameEngineState state;
    LocalVideoReader v(state);
    CHECK(v.open(video, VideoConfig(false)));
    CHECK(v.start());
    ReadResult old;
    for (int i = 0; i < 16; ++i) {
        old = v.readNext();
        if (old.kind == ReadResultKind::Frame) break;
    }
    CHECK(old.frame.has_value());
    const auto generation = state.mediaGeneration();
    v.stop();
    LocalPhotoReader p(state);
    CHECK(p.open(photo, PhotoConfig()));
    CHECK(state.mediaGeneration() == generation + 1);
    CHECK(!old.frame->isEligible(state.mediaGeneration(), state.timelineEpoch()));
    return true;
}
bool Test13(const std::string& photo, const std::string& video) {
    FrameEngineState state;
    LocalPhotoReader p(state);
    CHECK(p.open(photo, PhotoConfig()));
    CHECK(p.start());
    ReadResult old = p.readNext();
    CHECK(old.frame.has_value());
    const auto generation = state.mediaGeneration();
    p.stop();
    LocalVideoReader v(state);
    CHECK(v.open(video, VideoConfig(false)));
    CHECK(state.mediaGeneration() == generation + 1);
    CHECK(!old.frame->isEligible(state.mediaGeneration(), state.timelineEpoch()));
    return true;
}
bool Test14(const std::string& video, const std::string& photo) {
    FrameEngineState state;
    LocalVideoReader v(state);
    CHECK(v.open(video, VideoConfig(true)));
    CHECK(v.start());
    v.stop();
    CHECK(state.readerStatus().state == ReaderState::Cancelled);
    LocalPhotoReader p(state);
    CHECK(p.open(photo, PhotoConfig()));
    CHECK(p.start());
    CHECK(state.playbackState() == PlaybackState::Playing);
    return true;
}
bool Test15(const std::string& photo) {
    FrameEngineState state;
    LocalPhotoReader p(state);
    CHECK(p.open(photo, PhotoConfig()));
    CHECK(p.start());
    ReadResult old = p.readNext();
    CHECK(old.frame.has_value());
    p.stop();
    state.clearMedia();
    CHECK(!state.hasMedia());
    CHECK(state.playbackState() == PlaybackState::Empty);
    CHECK(!old.frame->isEligible(state.mediaGeneration(), state.timelineEpoch()));
    return true;
}
bool Test16(const std::string& corrupt) {
    FrameEngineState state;
    LocalPhotoReader p(state);
    CHECK(!p.open(corrupt, PhotoConfig()));
    CHECK(p.lastErrorCode() != ReaderErrorCode::None);
    return true;
}
bool Test17(const std::string& corrupt) {
    FrameEngineState state;
    LocalVideoReader v(state);
    CHECK(!v.open(corrupt, VideoConfig(false)));
    CHECK(v.lastErrorCode() != ReaderErrorCode::None);
    return true;
}
bool Test18(const std::string& corrupt) {
    FrameEngineState state;
    LocalPhotoReader p(state);
    CHECK(!p.open(corrupt, PhotoConfig()));
    CHECK(p.readNext().kind == ReadResultKind::NotReady);
    CHECK(!state.hasMedia());
    return true;
}
bool Test19() {
    SelectionCompletionGate gate;
    const auto first = gate.beginRequest();
    CHECK(gate.accept(first));
    CHECK(!gate.accept(first));
    const auto second = gate.beginRequest();
    CHECK(!gate.accept(first));
    CHECK(gate.accept(second));
    return true;
}
bool Test20(const std::string& video) {
    FrameEngineState state;
    LocalVideoReader v(state);
    CHECK(v.open(video, VideoConfig(false)));
    v.setLoopEnabled(true);
    CHECK(v.loopEnabled());
    CHECK(v.start());
    CHECK(state.pause());
    CHECK(state.resume());
    v.stop();
    state.clearMedia();
    CHECK(state.playbackState() == PlaybackState::Empty);
    return true;
}

void Run(const char* name, const std::function<bool()>& test) {
    ++gTestsRun;
    if (!test()) {
        ++gFailures;
        std::cerr << "[FAIL] " << name << std::endl;
    } else {
        std::cout << "[PASS] " << name << std::endl;
    }
}

}  // namespace

int main() {
    @autoreleasepool {
        const std::string photo = TempPath(@"png");
        const std::string video = TempPath(@"mov");
        const std::string corrupt = TempPath(@"bin");

        if (!CreatePhoto(photo) || !CreateVideo(video)) {
            std::cerr << "Unable to create deterministic gallery fixtures." << std::endl;
            return EXIT_FAILURE;
        }

        [@"not-media" writeToFile:
            [NSString stringWithUTF8String:corrupt.c_str()]
                         atomically:YES
                           encoding:NSUTF8StringEncoding
                              error:nil];

        Run("1 no media selected", Test1);
        Run("2 video selection establishes generation", [&]{ return Test2(video); });
        Run("3 video uses LocalVideoReader", [&]{ return Test3(video); });
        Run("4 video reaches FramePipelinePump", [&]{ return Test4(video); });
        Run("5 video loop on", [&]{ return Test5(video); });
        Run("6 video loop off EOS", [&]{ return Test6(video); });
        Run("7 photo selection establishes generation", [&]{ return Test7(photo); });
        Run("8 still photo emits PreparedFrame", [&]{ return Test8(photo); });
        Run("9 photo storage reuse", [&]{ return Test9(photo); });
        Run("10 photo timing", [&]{ return Test10(photo); });
        Run("11 photo reaches ReadyFrameQueue", [&]{ return Test11(photo); });
        Run("12 video to photo invalidates", [&]{ return Test12(video, photo); });
        Run("13 photo to video invalidates", [&]{ return Test13(photo, video); });
        Run("14 active media change safe", [&]{ return Test14(video, photo); });
        Run("15 clear invalidates old frame", [&]{ return Test15(photo); });
        Run("16 corrupt photo structured failure", [&]{ return Test16(corrupt); });
        Run("17 corrupt video structured failure", [&]{ return Test17(corrupt); });
        Run("18 no black fallback", [&]{ return Test18(corrupt); });
        Run("19 duplicate selection completion gate", Test19);
        Run("20 loop pause change clear no polling primitive", [&]{ return Test20(video); });

        NSFileManager* fm = [NSFileManager defaultManager];
        [fm removeItemAtPath:[NSString stringWithUTF8String:photo.c_str()] error:nil];
        [fm removeItemAtPath:[NSString stringWithUTF8String:video.c_str()] error:nil];
        [fm removeItemAtPath:[NSString stringWithUTF8String:corrupt.c_str()] error:nil];

        std::cout << "Internal gallery tests run: " << gTestsRun
                  << ", failures: " << gFailures << std::endl;
        return gFailures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
    }
}
