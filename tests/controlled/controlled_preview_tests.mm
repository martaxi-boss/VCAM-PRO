#include "ControlledFrameConsumer.h"
#include "FrameEngineState.h"
#include "InternalGalleryMediaSession.h"
#include "PreparedFrame.h"
#include "ReadyFrameQueue.h"

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

#include <CoreGraphics/CoreGraphics.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

#include <atomic>
#include <cstdint>
#include <cstring>
#include <functional>
#include <iostream>
#include <memory>
#include <optional>
#include <string>
#include <thread>

namespace {

using namespace vcam::controlled;
using namespace vcam::frame_engine;
using namespace vcam::media_engine;

int gTests = 0;
int gFailures = 0;

#define CHECK(condition) \
    do { \
        if (!(condition)) { \
            std::cerr \
                << "CHECK failed at " \
                << __FILE__ << ":" \
                << __LINE__ << ": " \
                << #condition \
                << std::endl; \
            return false; \
        } \
    } while (false)

std::string ToStd(
    NSString* value) {
    const char* utf8 =
        value.UTF8String;
    return utf8 == nullptr
        ? std::string{}
        : std::string(utf8);
}

std::string TempRoot() {
    return ToStd(
        [NSTemporaryDirectory()
            stringByAppendingPathComponent:
                [NSString
                    stringWithFormat:
                        @"vcam-controlled-%@",
                        NSUUID.UUID.UUIDString]]);
}

std::string TempFile(
    const std::string& root,
    NSString* extension) {
    NSString* nsRoot =
        [NSString
            stringWithUTF8String:
                root.c_str()];
    NSString* name =
        [NSString
            stringWithFormat:
                @"fixture-%@.%@",
                NSUUID.UUID.UUIDString,
                extension];

    return ToStd(
        [nsRoot
            stringByAppendingPathComponent:
                name]);
}

bool CreateDirectory(
    const std::string& path) {
    NSString* nsPath =
        [NSString
            stringWithUTF8String:
                path.c_str()];
    return [[NSFileManager
        defaultManager]
        createDirectoryAtPath:nsPath
  withIntermediateDirectories:YES
                   attributes:nil
                        error:nil];
}

bool CreatePhoto(
    const std::string& path) {
    constexpr std::size_t width = 64;
    constexpr std::size_t height = 48;

    std::uint8_t bytes[
        width * height * 4];
    std::memset(
        bytes,
        180,
        sizeof(bytes));

    CGColorSpaceRef colorSpace =
        CGColorSpaceCreateDeviceRGB();
    CGContextRef context =
        CGBitmapContextCreate(
            bytes,
            width,
            height,
            8,
            width * 4,
            colorSpace,
            kCGImageAlphaPremultipliedLast |
                kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);

    if (context == nullptr) {
        return false;
    }

    CGImageRef image =
        CGBitmapContextCreateImage(
            context);
    CGContextRelease(context);

    if (image == nullptr) {
        return false;
    }

    NSURL* url =
        [NSURL
            fileURLWithPath:
                [NSString
                    stringWithUTF8String:
                        path.c_str()]];

    CGImageDestinationRef destination =
        CGImageDestinationCreateWithURL(
            (__bridge CFURLRef)url,
            CFSTR("public.png"),
            1,
            nullptr);

    if (destination == nullptr) {
        CGImageRelease(image);
        return false;
    }

    CGImageDestinationAddImage(
        destination,
        image,
        nullptr);

    const bool ok =
        CGImageDestinationFinalize(
            destination);

    CFRelease(destination);
    CGImageRelease(image);
    return ok;
}

bool WaitForWriterInput(
    AVAssetWriterInput* input) {
    for (int attempt = 0;
         attempt < 5000;
         ++attempt) {
        if (input.readyForMoreMediaData) {
            return true;
        }

        [NSThread
            sleepForTimeInterval:
                0.001];
    }

    return false;
}

bool CreateVideo(
    const std::string& path,
    int frameCount = 6) {
    NSString* nsPath =
        [NSString
            stringWithUTF8String:
                path.c_str()];

    [[NSFileManager defaultManager]
        removeItemAtPath:nsPath
                   error:nil];

    NSURL* url =
        [NSURL fileURLWithPath:
            nsPath];

    AVAssetWriter* writer =
        [[AVAssetWriter alloc]
            initWithURL:url
               fileType:
                   AVFileTypeQuickTimeMovie
                  error:nil];

    if (writer == nil) {
        return false;
    }

    NSDictionary* settings = @{
        AVVideoCodecKey :
            AVVideoCodecTypeH264,
        AVVideoWidthKey :
            @64,
        AVVideoHeightKey :
            @48,
        AVVideoCompressionPropertiesKey :
            @{
                AVVideoAverageBitRateKey :
                    @150000
            }
    };

    AVAssetWriterInput* input =
        [AVAssetWriterInput
            assetWriterInputWithMediaType:
                AVMediaTypeVideo
                          outputSettings:
                              settings];

    NSDictionary* attributes = @{
        (NSString*)
            kCVPixelBufferPixelFormatTypeKey :
                @(kCVPixelFormatType_32BGRA),
        (NSString*)
            kCVPixelBufferWidthKey :
                @64,
        (NSString*)
            kCVPixelBufferHeightKey :
                @48
    };

    AVAssetWriterInputPixelBufferAdaptor*
        adaptor =
        [AVAssetWriterInputPixelBufferAdaptor
            assetWriterInputPixelBufferAdaptorWithAssetWriterInput:
                input
            sourcePixelBufferAttributes:
                attributes];

    if (![writer canAddInput:input]) {
        return false;
    }

    [writer addInput:input];

    if (![writer startWriting]) {
        return false;
    }

    [writer
        startSessionAtSourceTime:
            kCMTimeZero];

    for (int index = 0;
         index < frameCount;
         ++index) {
        if (!WaitForWriterInput(input)) {
            return false;
        }

        CVPixelBufferRef buffer = nullptr;

        if (CVPixelBufferPoolCreatePixelBuffer(
                kCFAllocatorDefault,
                adaptor.pixelBufferPool,
                &buffer) != kCVReturnSuccess ||
            buffer == nullptr) {
            return false;
        }

        CVPixelBufferLockBaseAddress(
            buffer,
            0);

        std::memset(
            CVPixelBufferGetBaseAddress(
                buffer),
            40 + index * 10,
            CVPixelBufferGetBytesPerRow(
                buffer) *
                CVPixelBufferGetHeight(
                    buffer));

        CVPixelBufferUnlockBaseAddress(
            buffer,
            0);

        const BOOL appended =
            [adaptor
                appendPixelBuffer:buffer
             withPresentationTime:
                 CMTimeMake(index, 30)];

        CVPixelBufferRelease(buffer);

        if (!appended) {
            return false;
        }
    }

    [input markAsFinished];

    dispatch_semaphore_t semaphore =
        dispatch_semaphore_create(0);

    [writer
        finishWritingWithCompletionHandler:^{
            dispatch_semaphore_signal(
                semaphore);
        }];

    if (dispatch_semaphore_wait(
            semaphore,
            dispatch_time(
                DISPATCH_TIME_NOW,
                static_cast<int64_t>(
                    10 * NSEC_PER_SEC))) != 0) {
        return false;
    }

    return writer.status ==
        AVAssetWriterStatusCompleted;
}

InternalGalleryMediaConfig
TestConfig() {
    InternalGalleryMediaConfig config;
    config.target.width = 64;
    config.target.height = 48;
    config.target.pixelFormat =
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    config.target.orientation =
        OrientationRequirement::
            UprightIdentityTransform;
    config.target.colorMetadata =
        ColorMetadataPolicy::
            PreserveSource;
    config.queueCapacity = 4;
    config.maxLatenessNs =
        20'000'000ULL;
    config.photo.cadenceNumerator =
        30;
    config.photo.cadenceDenominator =
        1;
    config.photo.outputPixelFormat =
        config.target.pixelFormat;
    config.videoPixelFormat =
        config.target.pixelFormat;
    return config;
}

std::optional<ControlledPresentedFrame>
WaitForFrame(
    ControlledFrameConsumer& consumer,
    int attempts = 600) {
    for (int attempt = 0;
         attempt < attempts;
         ++attempt) {
        auto result =
            consumer.tryAcquire();

        if (result.kind ==
                ControlledAcquireKind::
                    Presented &&
            result.frame.has_value()) {
            return std::optional<
                ControlledPresentedFrame>(
                    std::move(
                        *result.frame));
        }

        [NSThread
            sleepForTimeInterval:
                0.005];
    }

    return std::nullopt;
}

CVPixelBufferRef CreatePixelBuffer() {
    CVPixelBufferRef buffer = nullptr;

    NSDictionary* attributes = @{
        (NSString*)
            kCVPixelBufferIOSurfacePropertiesKey :
                @{}
    };

    const CVReturn status =
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            48,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            (__bridge CFDictionaryRef)
                attributes,
            &buffer);

    return status == kCVReturnSuccess
        ? buffer
        : nullptr;
}

PreparedFrame MakeFrame(
    CVPixelBufferRef buffer,
    const FrameIdentity& identity) {
    FrameTiming timing;
    timing.sourcePTS =
        CMTimeMake(
            static_cast<int64_t>(
                identity.sequence),
            30);
    timing.presentationTimestamp =
        timing.sourcePTS;
    timing.duration =
        CMTimeMake(1, 30);

    return PreparedFrame(
        buffer,
        identity,
        timing,
        OrientationState::Normalized,
        FrameValidity::Ready);
}

bool TestPhotoReachesConsumer(
    const std::string& photo) {
    InternalGalleryMediaSession session(
        TestConfig());

    CHECK(session.selectPhoto(photo));
    CHECK(session.start());

    ControlledFrameConsumer consumer;
    consumer.bind(
        &session.readyQueue(),
        session.state().mediaGeneration(),
        session.state().timelineEpoch());
    consumer.setEnabled(true);
    consumer.setPresentationActive(true);

    auto frame =
        WaitForFrame(consumer);

    CHECK(frame.has_value());
    CHECK(frame->valid());
    CHECK(
        frame->identity()
            .mediaGeneration ==
        session.state()
            .mediaGeneration());
    return true;
}

bool TestVideoReachesConsumer(
    const std::string& video) {
    InternalGalleryMediaSession session(
        TestConfig());

    CHECK(
        session.selectVideo(
            video,
            false));
    CHECK(session.start());

    ControlledFrameConsumer consumer;
    consumer.bind(
        &session.readyQueue(),
        session.state().mediaGeneration(),
        session.state().timelineEpoch());
    consumer.setEnabled(true);
    consumer.setPresentationActive(true);

    auto frame =
        WaitForFrame(consumer);

    CHECK(frame.has_value());
    CHECK(frame->valid());
    return true;
}

bool TestVideoLoopContinues(
    const std::string& video) {
    InternalGalleryMediaSession session(
        TestConfig());

    CHECK(
        session.selectVideo(
            video,
            true));
    CHECK(session.start());

    ControlledFrameConsumer consumer;
    consumer.bind(
        &session.readyQueue(),
        session.state().mediaGeneration(),
        session.state().timelineEpoch());
    consumer.setEnabled(true);
    consumer.setPresentationActive(true);

    bool sawLoop = false;

    for (int attempt = 0;
         attempt < 1000 &&
         !sawLoop;
         ++attempt) {
        auto frame =
            WaitForFrame(
                consumer,
                1);

        if (frame.has_value()) {
            sawLoop =
                frame->identity()
                    .loopIteration > 0;
            frame.reset();
        }

        [NSThread
            sleepForTimeInterval:
                0.003];
    }

    CHECK(sawLoop);
    return true;
}

bool TestPauseStopsPresentation(
    const std::string& photo) {
    InternalGalleryMediaSession session(
        TestConfig());

    CHECK(session.selectPhoto(photo));
    CHECK(session.start());

    ControlledFrameConsumer consumer;
    consumer.bind(
        &session.readyQueue(),
        session.state().mediaGeneration(),
        session.state().timelineEpoch());
    consumer.setEnabled(true);
    consumer.setPresentationActive(true);

    auto frame =
        WaitForFrame(consumer);
    CHECK(frame.has_value());
    frame.reset();

    CHECK(session.pause());
    consumer.setPresentationActive(false);

    auto paused =
        consumer.tryAcquire();

    CHECK(
        paused.kind ==
        ControlledAcquireKind::
            Inactive);
    return true;
}

bool TestResumeContinues(
    const std::string& photo) {
    InternalGalleryMediaSession session(
        TestConfig());

    CHECK(session.selectPhoto(photo));
    CHECK(session.start());

    ControlledFrameConsumer consumer;
    consumer.bind(
        &session.readyQueue(),
        session.state().mediaGeneration(),
        session.state().timelineEpoch());
    consumer.setEnabled(true);
    consumer.setPresentationActive(true);

    auto first =
        WaitForFrame(consumer);
    CHECK(first.has_value());
    first.reset();

    CHECK(session.pause());
    consumer.setPresentationActive(false);
    CHECK(session.resume());
    consumer.bind(
        &session.readyQueue(),
        session.state().mediaGeneration(),
        session.state().timelineEpoch());
    consumer.setPresentationActive(true);

    auto resumed =
        WaitForFrame(consumer);

    CHECK(resumed.has_value());
    return true;
}

bool TestChangeInvalidatesGeneration(
    const std::string& photo,
    const std::string& video) {
    InternalGalleryMediaSession session(
        TestConfig());

    CHECK(session.selectPhoto(photo));
    CHECK(session.start());

    ControlledFrameConsumer consumer;
    consumer.bind(
        &session.readyQueue(),
        session.state().mediaGeneration(),
        session.state().timelineEpoch());
    consumer.setEnabled(true);
    consumer.setPresentationActive(true);

    auto first =
        WaitForFrame(consumer);
    CHECK(first.has_value());

    const std::uint64_t oldGeneration =
        first->identity()
            .mediaGeneration;
    first.reset();

    CHECK(
        session.selectVideo(
            video,
            false));
    CHECK(session.start());
    consumer.bind(
        &session.readyQueue(),
        session.state().mediaGeneration(),
        session.state().timelineEpoch());
    consumer.setPresentationActive(true);

    auto replacement =
        WaitForFrame(consumer);

    CHECK(replacement.has_value());
    CHECK(
        replacement->identity()
            .mediaGeneration !=
        oldGeneration);
    CHECK(
        replacement->identity()
            .mediaGeneration ==
        session.state()
            .mediaGeneration());
    return true;
}

bool TestClearEmptiesPresentation(
    const std::string& photo) {
    InternalGalleryMediaSession session(
        TestConfig());

    CHECK(session.selectPhoto(photo));
    CHECK(session.start());

    ControlledFrameConsumer consumer;
    consumer.bind(
        &session.readyQueue(),
        session.state().mediaGeneration(),
        session.state().timelineEpoch());
    consumer.setEnabled(true);
    consumer.setPresentationActive(true);

    auto frame =
        WaitForFrame(consumer);
    CHECK(frame.has_value());
    frame.reset();

    session.clearMedia();
    consumer.unbind();

    auto cleared =
        consumer.tryAcquire();

    CHECK(
        cleared.kind ==
        ControlledAcquireKind::
            Unbound);
    CHECK(
        consumer.outstandingFrameCount() ==
        0);
    return true;
}

bool TestEmptyStateSafe() {
    ControlledFrameConsumer consumer;
    consumer.setEnabled(true);

    auto unbound =
        consumer.tryAcquire();

    CHECK(
        unbound.kind ==
        ControlledAcquireKind::
            Unbound);

    InternalGalleryMediaSession session(
        TestConfig());

    consumer.bind(
        &session.readyQueue(),
        session.state().mediaGeneration(),
        session.state().timelineEpoch());

    auto empty =
        consumer.tryAcquire();

    CHECK(
        empty.kind ==
        ControlledAcquireKind::
            Unbound);
    return true;
}

bool TestStaleFrameRejected() {
    FrameEngineState state;
    ReadyFrameQueue queue(3);

    state.selectOrReplaceMedia();
    CHECK(state.start());

    CVPixelBufferRef buffer =
        CreatePixelBuffer();
    CHECK(buffer != nullptr);

    const FrameIdentity identity{
        0,
        state.mediaGeneration(),
        state.timelineEpoch(),
        0,
    };

    QueueContext context{
        state.mediaGeneration(),
        state.timelineEpoch(),
        std::nullopt,
    };

    CHECK(
        queue.publish(
            MakeFrame(
                buffer,
                identity),
            context) ==
        PublishResult::Published);

    CVPixelBufferRelease(buffer);

    CHECK(state.seekOrReload());

    ControlledFrameConsumer consumer;
    consumer.bind(
        &queue,
        state.mediaGeneration(),
        state.timelineEpoch());
    consumer.setEnabled(true);
    consumer.setPresentationActive(true);

    auto stale =
        consumer.tryAcquire();

    CHECK(
        stale.kind ==
        ControlledAcquireKind::
            NoEligibleFrame);
    return true;
}

bool TestRepeatedLifecycleClean() {
    FrameEngineState state;
    ReadyFrameQueue queue(3);

    state.selectOrReplaceMedia();
    CHECK(state.start());

    ControlledFrameConsumer consumer;
    consumer.setEnabled(true);

    for (int iteration = 0;
         iteration < 100;
         ++iteration) {
        consumer.bind(
            &queue,
            state.mediaGeneration(),
            state.timelineEpoch());
        consumer.unbind();
    }

    CHECK(
        consumer.outstandingFrameCount() ==
        0);

    auto result =
        consumer.tryAcquire();

    CHECK(
        result.kind ==
        ControlledAcquireKind::
            Unbound);
    return true;
}

bool TestContentionDoesNotBlockProducer() {
    FrameEngineState state;
    ReadyFrameQueue queue(8);

    state.selectOrReplaceMedia();
    CHECK(state.start());

    const std::uint64_t generation =
        state.mediaGeneration();
    const std::uint64_t epoch =
        state.timelineEpoch();

    ControlledFrameConsumer consumer;
    consumer.bind(
        &queue,
        state.mediaGeneration(),
        state.timelineEpoch());
    consumer.setEnabled(true);
    consumer.setPresentationActive(true);

    CVPixelBufferRef buffer =
        CreatePixelBuffer();
    CHECK(buffer != nullptr);

    std::atomic<bool> done{false};
    std::atomic<int> published{0};

    std::thread producer(
        [&]() {
            QueueContext context{
                generation,
                epoch,
                std::nullopt,
            };

            for (std::uint64_t sequence = 0;
                 sequence < 500;
                 ++sequence) {
                FrameIdentity identity{
                    sequence,
                    generation,
                    epoch,
                    0,
                };

                const auto result =
                    queue.publish(
                        MakeFrame(
                            buffer,
                            identity),
                        context);

                if (result ==
                    PublishResult::Published) {
                    published.fetch_add(
                        1,
                        std::memory_order_relaxed);
                }

                std::this_thread::yield();
            }

            done.store(
                true,
                std::memory_order_release);
        });

    int acquired = 0;
    int guard = 0;

    while ((!done.load(
                std::memory_order_acquire) ||
            queue.size() != 0) &&
           guard < 100000) {
        ++guard;

        auto result =
            consumer.tryAcquire();

        if (result.kind ==
                ControlledAcquireKind::
                    Presented &&
            result.frame.has_value()) {
            ++acquired;
            result.frame.reset();
        }

        std::this_thread::yield();
    }

    producer.join();
    CVPixelBufferRelease(buffer);

    CHECK(
        published.load(
            std::memory_order_relaxed) >
        0);
    CHECK(acquired > 0);
    CHECK(
        consumer.outstandingFrameCount() ==
        0);
    return true;
}

bool TestPixelLifetimeBounded() {
    auto state =
        std::make_unique<
            FrameEngineState>();
    auto queue =
        std::make_unique<
            ReadyFrameQueue>(3);

    state->selectOrReplaceMedia();
    CHECK(state->start());

    CVPixelBufferRef buffer =
        CreatePixelBuffer();
    CHECK(buffer != nullptr);

    const FrameIdentity identity{
        0,
        state->mediaGeneration(),
        state->timelineEpoch(),
        0,
    };

    QueueContext context{
        state->mediaGeneration(),
        state->timelineEpoch(),
        std::nullopt,
    };

    CHECK(
        queue->publish(
            MakeFrame(
                buffer,
                identity),
            context) ==
        PublishResult::Published);

    CVPixelBufferRelease(buffer);

    ControlledFrameConsumer consumer;
    consumer.bind(
        queue.get(),
        state->mediaGeneration(),
        state->timelineEpoch());
    consumer.setEnabled(true);
    consumer.setPresentationActive(true);

    auto frame =
        consumer.tryAcquire();

    CHECK(
        frame.kind ==
        ControlledAcquireKind::
            Presented);
    CHECK(frame.frame.has_value());
    CHECK(
        consumer.outstandingFrameCount() ==
        1);

    auto second =
        consumer.tryAcquire();

    CHECK(
        second.kind ==
        ControlledAcquireKind::
            LeaseBusy);

    CVPixelBufferRef retained =
        frame.frame->pixelBuffer();

    consumer.unbind();
    queue.reset();
    state.reset();

    CHECK(
        CVPixelBufferGetWidth(
            retained) == 64);
    CHECK(
        CVPixelBufferGetHeight(
            retained) == 48);

    frame.frame.reset();

    CHECK(
        consumer.outstandingFrameCount() ==
        0);
    return true;
}

void Run(
    const char* name,
    const std::function<bool()>& test) {
    ++gTests;

    const bool passed =
        test();

    std::cout
        << (passed ? "PASS " : "FAIL ")
        << name
        << std::endl;

    if (!passed) {
        ++gFailures;
    }
}

}  // namespace

int main() {
    @autoreleasepool {
        const std::string root =
            TempRoot();

        if (!CreateDirectory(root)) {
            std::cerr
                << "Unable to create fixture root."
                << std::endl;
            return 1;
        }

        const std::string photo =
            TempFile(root, @"png");
        const std::string video =
            TempFile(root, @"mov");

        if (!CreatePhoto(photo) ||
            !CreateVideo(video, 4)) {
            std::cerr
                << "Unable to create fixtures."
                << std::endl;
            return 1;
        }

        Run(
            "photo reaches controlled consumer",
            [&]() {
                return TestPhotoReachesConsumer(
                    photo);
            });

        Run(
            "video reaches controlled consumer",
            [&]() {
                return TestVideoReachesConsumer(
                    video);
            });

        Run(
            "video loop continues",
            [&]() {
                return TestVideoLoopContinues(
                    video);
            });

        Run(
            "pause stops presentation progression",
            [&]() {
                return TestPauseStopsPresentation(
                    photo);
            });

        Run(
            "resume continues progression",
            [&]() {
                return TestResumeContinues(
                    photo);
            });

        Run(
            "change invalidates prior generation",
            [&]() {
                return TestChangeInvalidatesGeneration(
                    photo,
                    video);
            });

        Run(
            "clear empties presentation state",
            [&]() {
                return TestClearEmptiesPresentation(
                    photo);
            });

        Run(
            "empty no-frame state is safe",
            TestEmptyStateSafe);

        Run(
            "stale frame is rejected",
            TestStaleFrameRejected);

        Run(
            "repeated consumer lifecycle is clean",
            TestRepeatedLifecycleClean);

        Run(
            "consumer does not block producer",
            TestContentionDoesNotBlockProducer);

        Run(
            "pixel-buffer lifetime is bounded",
            TestPixelLifetimeBounded);

        [[NSFileManager defaultManager]
            removeItemAtPath:
                [NSString
                    stringWithUTF8String:
                        root.c_str()]
                     error:nil];

        std::cout
            << "Controlled preview tests run: "
            << gTests
            << ", failures: "
            << gFailures
            << std::endl;

        return gFailures == 0
            ? 0
            : 1;
    }
}
