#include "CameraConsumerAdapter.h"
#include "ControlStateCache.h"
#include "InternalGalleryMediaSession.h"
#include "ProductControlOwner.h"
#include "SelectionCompletionGate.h"
#include "SharedControlStore.h"

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

#include <CoreGraphics/CoreGraphics.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <iostream>
#include <mutex>
#include <string>
#include <thread>
#include <unistd.h>

namespace {

using namespace vcam::control;
using namespace vcam::frame_engine;
using namespace vcam::media_engine;
using namespace vcam::product;

int gTests = 0;
int gFailures = 0;

#define CHECK(condition) do { if (!(condition)) {     std::cerr << "CHECK failed at " << __FILE__ << ":" << __LINE__               << ": " #condition << std::endl; return false; } } while (false)

std::string ToStd(NSString* value) {
    const char* utf8 = value.UTF8String;
    return utf8 == nullptr
        ? std::string{}
        : std::string(utf8);
}

std::string TempRoot() {
    NSString* path =
        [NSTemporaryDirectory()
            stringByAppendingPathComponent:
                [NSString
                    stringWithFormat:
                        @"vcam-product-%@-%d",
                        NSUUID.UUID.UUIDString,
                        getpid()]];
    return ToStd(path);
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
        170,
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
        [NSURL fileURLWithPath:
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

    const bool result =
        CGImageDestinationFinalize(
            destination);

    CFRelease(destination);
    CGImageRelease(image);

    return result;
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
            sleepForTimeInterval:0.001];
    }
    return false;
}

bool CreateVideo(
    const std::string& path,
    int frameCount = 30) {
    NSString* nsPath =
        [NSString
            stringWithUTF8String:
                path.c_str()];
    [[NSFileManager defaultManager]
        removeItemAtPath:nsPath
                   error:nil];

    NSURL* url =
        [NSURL fileURLWithPath:nsPath];

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

        CVPixelBufferRef buffer =
            nullptr;

        if (CVPixelBufferPoolCreatePixelBuffer(
                kCFAllocatorDefault,
                adaptor.pixelBufferPool,
                &buffer) !=
                kCVReturnSuccess ||
            buffer == nullptr) {
            return false;
        }

        CVPixelBufferLockBaseAddress(
            buffer,
            0);

        std::memset(
            CVPixelBufferGetBaseAddress(
                buffer),
            40 + (index % 8) * 20,
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

    const long wait =
        dispatch_semaphore_wait(
            semaphore,
            dispatch_time(
                DISPATCH_TIME_NOW,
                static_cast<int64_t>(
                    10 * NSEC_PER_SEC)));

    return
        wait == 0 &&
        writer.status ==
            AVAssetWriterStatusCompleted;
}

InternalGalleryMediaConfig
SessionConfig() {
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
        50'000'000ULL;
    config.producer.notReadyRetryNs =
        1'000'000ULL;
    config.photo.cadenceNumerator =
        30;
    config.photo.cadenceDenominator =
        1;
    config.photo.outputPixelFormat =
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    config.videoPixelFormat =
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    return config;
}

bool WaitForQueue(
    ReadyFrameQueue& queue,
    int attempts = 1000) {
    for (int i = 0;
         i < attempts;
         ++i) {
        if (queue.size() > 0) {
            return true;
        }

        std::this_thread::sleep_for(
            std::chrono::milliseconds(2));
    }

    return false;
}

void RemoveTree(
    const std::string& root) {
    [[NSFileManager defaultManager]
        removeItemAtPath:
            [NSString
                stringWithUTF8String:
                    root.c_str()]
                   error:nil];
}

bool TestDarwinRefreshUpdatesCache() {
    const std::string root =
        TempRoot();
    CHECK(CreateDirectory(root));

    const std::string path =
        root + "/control.plist";
    const std::string notification =
        "com.vcampro.test." +
        std::to_string(getpid()) +
        "." +
        std::to_string(
            static_cast<unsigned long long>(
                arc4random()));

    SharedControlStore store(
        path,
        notification);
    ControlStateCache cache;

    std::mutex mutex;
    std::condition_variable cv;
    bool observed = false;

    CHECK(store.startObserving(
        [&](const ProductControlSnapshot&
                snapshot) {
            cache.replace(snapshot);
            {
                std::lock_guard<std::mutex>
                    lock(mutex);
                observed = true;
            }
            cv.notify_one();
        }));

    ProductControlSnapshot snapshot;
    snapshot.enabled = true;
    snapshot.mediaKind =
        ProductMediaKind::Photo;
    snapshot.mediaPath =
        root + "/photo.png";
    snapshot.selectionGeneration = 4;
    snapshot.playbackIntent =
        ProductPlaybackIntent::Playing;

    CHECK(store.save(snapshot));

    {
        std::unique_lock<std::mutex>
            lock(mutex);
        CHECK(cv.wait_for(
            lock,
            std::chrono::seconds(3),
            [&] {
                return observed;
            }));
    }

    CHECK(cache.enabledFast());
    CHECK(cache.refreshCount() >= 1);
    CHECK(cache.snapshot()
              .selectionGeneration == 4);

    store.stopObserving();
    RemoveTree(root);
    return true;
}

bool TestFastPathDoesNotReadDisk() {
    const std::string root =
        TempRoot();
    CHECK(CreateDirectory(root));

    SharedControlStore store(
        root + "/control.plist",
        "com.vcampro.test.no-disk");

    ProductControlSnapshot snapshot;
    snapshot.enabled = true;
    CHECK(store.save(snapshot, false));

    ProductControlSnapshot loaded;
    CHECK(store.load(&loaded));

    const auto readsBefore =
        store.diskReadCount();

    ReadyFrameQueue queue(4);
    CameraConsumerAdapter adapter;
    adapter.setEnabled(true);
    adapter.bindQueue(
        &queue,
        1,
        1,
        true);

    CVPixelBufferRef original =
        nullptr;
    CHECK(CVPixelBufferCreate(
        kCFAllocatorDefault,
        64,
        48,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        nullptr,
        &original) ==
        kCVReturnSuccess);

    for (int i = 0;
         i < 100;
         ++i) {
        (void)adapter.decide(original);
    }

    CHECK(store.diskReadCount() ==
          readsBefore);

    CVPixelBufferRelease(original);
    RemoveTree(root);
    return true;
}

bool TestVideoFeedsF2(
    const std::string& video) {
    InternalGalleryMediaSession session(
        SessionConfig());

    CHECK(session.selectVideo(
        video,
        true));
    CHECK(session.start());
    CHECK(WaitForQueue(
        session.readyQueue()));
    CHECK(session.playbackState() ==
          PlaybackState::Playing);

    return true;
}

bool TestPhotoFeedsSameF2(
    const std::string& photo) {
    InternalGalleryMediaSession session(
        SessionConfig());

    CHECK(session.selectPhoto(photo));
    CHECK(session.start());
    CHECK(WaitForQueue(
        session.readyQueue()));
    CHECK(session.playbackState() ==
          PlaybackState::Playing);

    return true;
}

bool TestActiveReplacementLifecycle(
    const std::string& video,
    const std::string& photo) {
    InternalGalleryMediaSession session(
        SessionConfig());

    CHECK(session.selectVideo(
        video,
        true));
    CHECK(session.start());
    CHECK(WaitForQueue(
        session.readyQueue()));

    CHECK(session.pause());
    CHECK(session.playbackState() ==
          PlaybackState::Paused);

    CHECK(session.resume());
    CHECK(session.playbackState() ==
          PlaybackState::Playing);

    const std::uint64_t before =
        session.state()
            .mediaGeneration();

    CHECK(session.selectPhoto(photo));
    CHECK(session.state()
              .mediaGeneration() ==
          before + 1);

    CHECK(session.start());
    CHECK(WaitForQueue(
        session.readyQueue()));
    CHECK(session.playbackState() ==
          PlaybackState::Playing);

    return true;
}

bool TestActiveClearLifecycle(
    const std::string& video) {
    {
        InternalGalleryMediaSession session(
            SessionConfig());

        CHECK(session.selectVideo(
            video,
            true));
        CHECK(session.start());
        CHECK(WaitForQueue(
            session.readyQueue()));

        session.clearMedia();

        CHECK(!session.state()
                   .hasMedia());
        CHECK(session.playbackState() ==
              PlaybackState::Empty);
        CHECK(session.readyQueue()
                  .size() == 0);
    }

    std::this_thread::sleep_for(
        std::chrono::milliseconds(25));

    return true;
}

bool TestPickerCancellationPreservesSelection(
    const std::string& video) {
    const std::string root =
        TempRoot();
    CHECK(CreateDirectory(root));

    ProductControlOwner owner(
        root + "/control.plist",
        "com.vcampro.test.cancel",
        root + "/Media");

    CHECK(owner.selectFromTemporaryPath(
        video,
        ProductMediaKind::Video,
        nullptr));

    const auto before =
        owner.snapshot();

    SelectionCompletionGate gate;
    const auto token =
        gate.beginRequest();
    CHECK(gate.accept(token));

    const auto after =
        owner.snapshot();

    CHECK(after.mediaPath ==
          before.mediaPath);
    CHECK(after.selectionGeneration ==
          before.selectionGeneration);

    RemoveTree(root);
    return true;
}

bool TestInvalidReplacementPreservesSelection(
    const std::string& video) {
    const std::string root =
        TempRoot();
    CHECK(CreateDirectory(root));

    ProductControlOwner owner(
        root + "/control.plist",
        "com.vcampro.test.invalid",
        root + "/Media");

    CHECK(owner.selectFromTemporaryPath(
        video,
        ProductMediaKind::Video,
        nullptr));

    const auto before =
        owner.snapshot();

    std::string error;
    CHECK(!owner.selectFromTemporaryPath(
        root + "/missing.mov",
        ProductMediaKind::Video,
        &error));
    CHECK(!error.empty());

    const auto after =
        owner.snapshot();

    CHECK(after.mediaPath ==
          before.mediaPath);
    CHECK(after.selectionGeneration ==
          before.selectionGeneration);

    CHECK([[NSFileManager defaultManager]
        fileExistsAtPath:
            [NSString
                stringWithUTF8String:
                    after.mediaPath.c_str()]]);

    RemoveTree(root);
    return true;
}

void Run(
    const char* name,
    const std::function<bool()>& fn) {
    ++gTests;

    if (!fn()) {
        ++gFailures;
        std::cerr
            << "[FAIL] "
            << name
            << std::endl;
    } else {
        std::cout
            << "[PASS] "
            << name
            << std::endl;
    }
}

}  // namespace

int main() {
    @autoreleasepool {
        const std::string root =
            TempRoot();
        if (!CreateDirectory(root)) {
            std::cerr
                << "Unable to create product test root."
                << std::endl;
            return EXIT_FAILURE;
        }

        const std::string video =
            TempFile(root, @"mov");
        const std::string photo =
            TempFile(root, @"png");

        if (!CreateVideo(video) ||
            !CreatePhoto(photo)) {
            std::cerr
                << "Unable to build product fixtures."
                << std::endl;
            RemoveTree(root);
            return EXIT_FAILURE;
        }

        Run(
            "Darwin refresh updates cache",
            TestDarwinRefreshUpdatesCache);
        Run(
            "camera fast path does not read disk",
            TestFastPathDoesNotReadDisk);
        Run(
            "valid video feeds existing F2",
            [&] {
                return TestVideoFeedsF2(
                    video);
            });
        Run(
            "photo feeds same F2",
            [&] {
                return TestPhotoFeedsSameF2(
                    photo);
            });
        Run(
            "active replacement lifecycle safe",
            [&] {
                return TestActiveReplacementLifecycle(
                    video,
                    photo);
            });
        Run(
            "active clear lifecycle safe",
            [&] {
                return TestActiveClearLifecycle(
                    video);
            });
        Run(
            "picker cancellation preserves selection",
            [&] {
                return TestPickerCancellationPreservesSelection(
                    video);
            });
        Run(
            "invalid replacement preserves selection",
            [&] {
                return TestInvalidReplacementPreservesSelection(
                    video);
            });

        RemoveTree(root);

        std::cout
            << "Product integration tests run: "
            << gTests
            << ", failures: "
            << gFailures
            << std::endl;

        return gFailures == 0
            ? EXIT_SUCCESS
            : EXIT_FAILURE;
    }
}
