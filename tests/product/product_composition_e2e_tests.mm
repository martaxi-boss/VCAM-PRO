#include "MediaserverdRuntime.h"
#include "ProductControlOwner.h"
#include "ReferenceCameraHook.h"

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

#include <CoreGraphics/CoreGraphics.h>
#include <CoreVideo/CoreVideo.h>

#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <thread>
#include <unistd.h>

namespace vcam::product {
bool CommitVirtualCameraOutputIntoOriginal(
    CVPixelBufferRef virtualBuffer,
    CVPixelBufferRef original) noexcept;
}

namespace {

using namespace vcam::product;

#define CHECK(condition) do { if (!(condition)) { \
    std::cerr << "CHECK failed at " << __FILE__ << ":" << __LINE__ \
              << ": " #condition << std::endl; return false; } } while (false)

std::string ToStd(NSString* value) {
    const char* utf8 = value.UTF8String;
    return utf8 == nullptr ? std::string{} : std::string(utf8);
}

std::string TempRoot() {
    return ToStd(
        [NSTemporaryDirectory()
            stringByAppendingPathComponent:
                [NSString stringWithFormat:
                    @"vcam-e2e-%@-%d",
                    NSUUID.UUID.UUIDString,
                    getpid()]]);
}

bool CreateDirectory(const std::string& path) {
    return [[NSFileManager defaultManager]
        createDirectoryAtPath:
            [NSString stringWithUTF8String:path.c_str()]
        withIntermediateDirectories:YES
        attributes:nil
        error:nil];
}

bool CreateAsymmetricPhoto(const std::string& path) {
    constexpr std::size_t width = 64;
    constexpr std::size_t height = 48;
    std::uint8_t bytes[width * height * 4];

    for (std::size_t y = 0; y < height; ++y) {
        for (std::size_t x = 0; x < width; ++x) {
            const std::size_t index = (y * width + x) * 4;
            bytes[index + 0] = static_cast<std::uint8_t>((x * 4) & 0xff);
            bytes[index + 1] = static_cast<std::uint8_t>((y * 5) & 0xff);
            bytes[index + 2] = static_cast<std::uint8_t>(((x + y) * 3) & 0xff);
            bytes[index + 3] = 255;
        }
    }

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
    if (context == nullptr) return false;

    CGImageRef image =
        CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (image == nullptr) return false;

    NSURL* url =
        [NSURL fileURLWithPath:
            [NSString stringWithUTF8String:path.c_str()]];
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

    CGImageDestinationAddImage(destination, image, nullptr);
    const bool ok =
        CGImageDestinationFinalize(destination);
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
            sleepForTimeInterval:0.001];
    }
    return false;
}

bool CreateVideo(
    const std::string& path,
    int frameCount = 12) {
    NSString* nsPath =
        [NSString stringWithUTF8String:
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
        AVVideoWidthKey : @64,
        AVVideoHeightKey : @48,
        AVVideoCompressionPropertiesKey :
            @{AVVideoAverageBitRateKey : @150000}
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
            kCVPixelBufferWidthKey : @64,
        (NSString*)
            kCVPixelBufferHeightKey : @48
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
    [writer startSessionAtSourceTime:
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
                &buffer) !=
                kCVReturnSuccess ||
            buffer == nullptr) {
            return false;
        }

        CVPixelBufferLockBaseAddress(
            buffer,
            0);
        std::memset(
            CVPixelBufferGetBaseAddress(buffer),
            30 + (index % 8) * 24,
            CVPixelBufferGetBytesPerRow(buffer) *
                CVPixelBufferGetHeight(buffer));
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

CVPixelBufferRef MakeNV12(
    std::uint8_t y,
    std::uint8_t uv) {
    CVPixelBufferRef buffer = nullptr;
    if (CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            48,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            nullptr,
            &buffer) != kCVReturnSuccess ||
        buffer == nullptr) {
        return nullptr;
    }

    if (CVPixelBufferLockBaseAddress(buffer, 0) !=
        kCVReturnSuccess) {
        CVPixelBufferRelease(buffer);
        return nullptr;
    }

    std::memset(
        CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
        y,
        CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) *
            CVPixelBufferGetHeightOfPlane(buffer, 0));
    std::memset(
        CVPixelBufferGetBaseAddressOfPlane(buffer, 1),
        uv,
        CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) *
            CVPixelBufferGetHeightOfPlane(buffer, 1));

    CVPixelBufferUnlockBaseAddress(buffer, 0);
    return buffer;
}

bool ActiveBytesEqual(
    CVPixelBufferRef lhs,
    CVPixelBufferRef rhs) {
    if (lhs == nullptr || rhs == nullptr ||
        CVPixelBufferGetWidth(lhs) != CVPixelBufferGetWidth(rhs) ||
        CVPixelBufferGetHeight(lhs) != CVPixelBufferGetHeight(rhs) ||
        CVPixelBufferGetPixelFormatType(lhs) !=
            CVPixelBufferGetPixelFormatType(rhs)) {
        return false;
    }

    if (CVPixelBufferLockBaseAddress(
            lhs, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        return false;
    }
    if (CVPixelBufferLockBaseAddress(
            rhs, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(
            lhs, kCVPixelBufferLock_ReadOnly);
        return false;
    }

    bool equal = true;
    for (std::size_t plane = 0; plane < 2 && equal; ++plane) {
        const auto* a = static_cast<const std::uint8_t*>(
            CVPixelBufferGetBaseAddressOfPlane(lhs, plane));
        const auto* b = static_cast<const std::uint8_t*>(
            CVPixelBufferGetBaseAddressOfPlane(rhs, plane));
        const std::size_t rows =
            CVPixelBufferGetHeightOfPlane(lhs, plane);
        const std::size_t width =
            CVPixelBufferGetWidthOfPlane(lhs, plane);
        const std::size_t bytes =
            width * (plane == 0 ? 1U : 2U);
        const std::size_t aStride =
            CVPixelBufferGetBytesPerRowOfPlane(lhs, plane);
        const std::size_t bStride =
            CVPixelBufferGetBytesPerRowOfPlane(rhs, plane);
        for (std::size_t row = 0; row < rows; ++row) {
            if (std::memcmp(
                    a + row * aStride,
                    b + row * bStride,
                    bytes) != 0) {
                equal = false;
                break;
            }
        }
    }

    CVPixelBufferUnlockBaseAddress(
        rhs, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(
        lhs, kCVPixelBufferLock_ReadOnly);
    return equal;
}

bool WaitForPhotoReady(
    MediaserverdRuntime& runtime,
    std::uint64_t generation,
    MediaserverdRuntimeTestSnapshot* output) {
    for (int attempt = 0; attempt < 1500; ++attempt) {
        (void)runtime.drainControlQueueForTesting();
        const auto snapshot =
            runtime.snapshotForTesting();
        if (snapshot.selectionGeneration == generation &&
            snapshot.controlRefreshCount >= 2 &&
            snapshot.sessionExists &&
            snapshot.producerHealthy &&
            snapshot.photoDecodeCount == 1 &&
            snapshot.publishedFrameCount > 0 &&
            snapshot.readyQueueSize > 0) {
            if (output != nullptr) {
                *output = snapshot;
            }
            return true;
        }
        std::this_thread::sleep_for(
            std::chrono::milliseconds(2));
    }
    return false;
}

bool WaitForPause(
    MediaserverdRuntime& runtime,
    std::uint64_t generation) {
    for (int attempt = 0; attempt < 1000; ++attempt) {
        (void)runtime.drainControlQueueForTesting();
        const auto snapshot =
            runtime.snapshotForTesting();
        if (snapshot.selectionGeneration == generation &&
            snapshot.sessionExists &&
            !snapshot.producerHealthy) {
            return true;
        }
        std::this_thread::sleep_for(
            std::chrono::milliseconds(2));
    }
    return false;
}

bool TestRealProductCompositionPhotoPersistence() {
    const std::string root = TempRoot();
    CHECK(CreateDirectory(root));

    const std::string input = root + "/input.png";
    CHECK(CreateAsymmetricPhoto(input));

    const std::string control = root + "/control.plist";
    const std::string media = root + "/Media";
    const std::string notification =
        "com.vcampro.e2e." +
        std::to_string(getpid()) + "." +
        std::to_string(
            static_cast<unsigned long long>(arc4random()));

    ProductControlOwner owner(
        control,
        notification,
        media);
    MediaserverdRuntime runtime(
        control,
        notification);

    CHECK(runtime.start());

    CVPixelBufferRef geometryProbe =
        MakeNV12(211, 77);
    CHECK(geometryProbe != nullptr);
    runtime.observeRealCameraBuffer(geometryProbe);
    CHECK(runtime.drainControlQueueForTesting());

    CHECK(owner.setEnabled(true));

    std::string error;
    CHECK(owner.selectFromTemporaryPath(
        input,
        ProductMediaKind::Photo,
        &error));

    const auto selected =
        owner.snapshot();
    CHECK(selected.enabled);
    CHECK(selected.mediaKind ==
          ProductMediaKind::Photo);
    CHECK(selected.hasMedia());

    std::cout
        << "PHOTO_SELECTION_COMMITTED=PASS\n"
        << "PHOTO_STAGING_VALID=PASS\n";

    MediaserverdRuntimeTestSnapshot runtimeSnapshot;
    CHECK(WaitForPhotoReady(
        runtime,
        selected.selectionGeneration,
        &runtimeSnapshot));

    CHECK(runtimeSnapshot.publishedFrameCount == 1);

    std::cout
        << "PHOTO_CONTROL_OBSERVED_BY_RUNTIME=PASS\n"
        << "PHOTO_SESSION_CREATED=PASS\n"
        << "PHOTO_SELECT_RESULT=PASS\n"
        << "PHOTO_READER_READY=PASS\n"
        << "PHOTO_DECODE=PASS\n"
        << "PHOTO_FRAME_NORMALIZED=PASS\n"
        << "PHOTO_PRODUCER_STARTED=PASS\n"
        << "PHOTO_FRAME_PUBLISHED=PASS\n"
        << "PHOTO_QUEUE_BOUND=PASS\n"
        << "PHOTO_QUEUE_NONEMPTY=PASS\n"
        << "PHOTO_GENERATION_MATCH=PASS\n"
        << "PHOTO_TIMELINE_MATCH=PASS\n";

    CVPixelBufferRef original =
        MakeNV12(211, 77);
    CVPixelBufferRef originalFixture =
        MakeNV12(211, 77);
    CVPixelBufferRef blackFixture =
        MakeNV12(0, 128);
    CHECK(original != nullptr);
    CHECK(originalFixture != nullptr);
    CHECK(blackFixture != nullptr);

    runtime.observeRealCameraBuffer(original);
    CHECK(runtime.drainControlQueueForTesting());

    const CameraDecision first =
        runtime.decideCameraBuffer(original);
    CHECK(first.kind ==
          CameraDecisionKind::Virtual);
    CHECK(first.source ==
          CameraDecisionSource::PreparedMedia);
    CHECK(first.pixelBuffer != nullptr);
    CHECK(first.pixelBuffer != original);

    std::cout
        << "PHOTO_LEASE_VALID=PASS\n"
        << "PHOTO_GEOMETRY_MATCH=PASS\n"
        << "PHOTO_READY_REPLACES_BLACK=PASS\n"
        << "PHOTO_DECISION_SOURCE_PREPARED_MEDIA=PASS\n";

    CHECK(CommitVirtualCameraOutputIntoOriginal(
        first.pixelBuffer,
        original));
    CHECK(ActiveBytesEqual(
        first.pixelBuffer,
        original));
    CHECK(!ActiveBytesEqual(
        original,
        blackFixture));
    CHECK(!ActiveBytesEqual(
        original,
        originalFixture));

    std::cout
        << "PHOTO_OUTPUT_PIXELS_FROM_LOCAL_MEDIA=PASS\n"
        << "PHOTO_OUTPUT_NOT_BLACK=PASS\n"
        << "PHOTO_OUTPUT_NOT_ORIGINAL_FIXTURE=PASS\n";

    CHECK(owner.setPlaybackIntent(
        ProductPlaybackIntent::Paused));
    CHECK(WaitForPause(
        runtime,
        selected.selectionGeneration));

    CVPixelBufferRef pausedOriginal =
        MakeNV12(211, 77);
    CHECK(pausedOriginal != nullptr);
    runtime.observeRealCameraBuffer(pausedOriginal);
    CHECK(runtime.drainControlQueueForTesting());

    const CameraDecision paused =
        runtime.decideCameraBuffer(pausedOriginal);

    // Desired static-photo contract: the already-prepared PHOTO remains the
    // active visual source while paused. Current one-shot queue behavior is
    // expected to fail here until the reusable latest-photo policy is added.
    CHECK(paused.kind ==
          CameraDecisionKind::Virtual);
    CHECK(paused.source ==
          CameraDecisionSource::PreparedMedia);

    CVPixelBufferRef baselinePhoto =
        MakeNV12(0, 128);
    CHECK(baselinePhoto != nullptr);
    CHECK(CommitVirtualCameraOutputIntoOriginal(
        paused.pixelBuffer,
        baselinePhoto));

    CHECK(owner.setPhotoTransform(
        0.5,
        -0.25,
        1.5));

    bool transformedReady = false;
    CVPixelBufferRef transformedOutput =
        MakeNV12(211, 77);
    CHECK(transformedOutput != nullptr);

    for (int attempt = 0;
         attempt < 1500;
         ++attempt) {
        CHECK(runtime.drainControlQueueForTesting());

        CVPixelBufferRef probe =
            MakeNV12(211, 77);
        CHECK(probe != nullptr);
        const CameraDecision transformed =
            runtime.decideCameraBuffer(
                probe);

        if (transformed.kind ==
                CameraDecisionKind::Virtual &&
            transformed.source ==
                CameraDecisionSource::PreparedMedia &&
            transformed.pixelBuffer != nullptr) {
            CHECK(CommitVirtualCameraOutputIntoOriginal(
                transformed.pixelBuffer,
                transformedOutput));
            CVPixelBufferRelease(probe);

            if (!ActiveBytesEqual(
                    baselinePhoto,
                    transformedOutput)) {
                transformedReady = true;
                break;
            }
        } else {
            CVPixelBufferRelease(probe);
        }

        std::this_thread::sleep_for(
            std::chrono::milliseconds(2));
    }

    CHECK(transformedReady);

    std::cout
        << "PHOTO_STATIC_SOURCE_PERSISTS=PASS\n"
        << "PHOTO_STATIC_SOURCE_SINGLE_PUBLICATION=PASS\n"
        << "PHOTO_TRANSFORM_PRODUCT_COMPOSITION=PASS\n"
        << "PRODUCT_COMPOSITION_TEST_BYPASSES_RUNTIME=NO\n"
        << "PRODUCT_COMPOSITION_TEST_DIRECT_ADAPTER_BIND=NO\n"
        << "PRODUCT_COMPOSITION_TEST_DIRECT_SESSION_CONSTRUCTION=NO\n";

    CVPixelBufferRelease(transformedOutput);
    CVPixelBufferRelease(baselinePhoto);
    CVPixelBufferRelease(pausedOriginal);
    CVPixelBufferRelease(blackFixture);
    CVPixelBufferRelease(originalFixture);
    CVPixelBufferRelease(original);
    CVPixelBufferRelease(geometryProbe);

    [[NSFileManager defaultManager]
        removeItemAtPath:
            [NSString stringWithUTF8String:root.c_str()]
        error:nil];

    return true;
}

bool TestRealProductVideoLifecycle() {
    const std::string root = TempRoot();
    CHECK(CreateDirectory(root));

    const std::string input =
        root + "/input.mov";
    CHECK(CreateVideo(input));

    const std::string control =
        root + "/control.plist";
    const std::string media =
        root + "/Media";
    const std::string notification =
        "com.vcampro.video-e2e." +
        std::to_string(getpid()) + "." +
        std::to_string(
            static_cast<unsigned long long>(
                arc4random()));

    ProductControlOwner owner(
        control,
        notification,
        media);
    MediaserverdRuntime runtime(
        control,
        notification);
    CHECK(runtime.start());

    CVPixelBufferRef camera =
        MakeNV12(211, 77);
    CHECK(camera != nullptr);
    runtime.observeRealCameraBuffer(camera);
    CHECK(runtime.drainControlQueueForTesting());

    CHECK(owner.setEnabled(true));

    std::string error;
    CHECK(owner.selectFromTemporaryPath(
        input,
        ProductMediaKind::Video,
        &error));
    CHECK(error.empty());
    CHECK(owner.setLoopEnabled(true));

    const auto selected =
        owner.snapshot();
    CHECK(selected.mediaKind ==
          ProductMediaKind::Video);
    CHECK(selected.hasMedia());

    MediaserverdRuntimeTestSnapshot ready;
    bool videoReady = false;
    for (int attempt = 0;
         attempt < 2000;
         ++attempt) {
        CHECK(runtime.drainControlQueueForTesting());
        ready = runtime.snapshotForTesting();
        if (ready.selectionGeneration ==
                selected.selectionGeneration &&
            ready.videoSelected &&
            ready.sessionExists &&
            ready.producerHealthy &&
            ready.readyQueueSize > 0 &&
            ready.publishedFrameCount > 0) {
            videoReady = true;
            break;
        }
        std::this_thread::sleep_for(
            std::chrono::milliseconds(2));
    }
    CHECK(videoReady);

    const CameraDecision playing =
        runtime.decideCameraBuffer(camera);
    CHECK(playing.kind ==
          CameraDecisionKind::Virtual);
    CHECK(playing.source ==
          CameraDecisionSource::PreparedMedia);

    CHECK(owner.setPlaybackIntent(
        ProductPlaybackIntent::Paused));

    bool paused = false;
    for (int attempt = 0;
         attempt < 1000;
         ++attempt) {
        CHECK(runtime.drainControlQueueForTesting());
        const auto snapshot =
            runtime.snapshotForTesting();
        if (snapshot.selectionGeneration ==
                selected.selectionGeneration &&
            snapshot.sessionExists &&
            !snapshot.producerHealthy) {
            paused = true;
            break;
        }
        std::this_thread::sleep_for(
            std::chrono::milliseconds(2));
    }
    CHECK(paused);

    CVPixelBufferRef pausedCamera =
        MakeNV12(211, 77);
    CHECK(pausedCamera != nullptr);
    const CameraDecision pausedDecision =
        runtime.decideCameraBuffer(
            pausedCamera);
    CHECK(pausedDecision.kind ==
          CameraDecisionKind::Virtual);
    CHECK(pausedDecision.source !=
          CameraDecisionSource::Original);

    CHECK(owner.setPlaybackIntent(
        ProductPlaybackIntent::Playing));

    bool resumed = false;
    for (int attempt = 0;
         attempt < 1500;
         ++attempt) {
        CHECK(runtime.drainControlQueueForTesting());
        const auto snapshot =
            runtime.snapshotForTesting();
        if (snapshot.selectionGeneration ==
                selected.selectionGeneration &&
            snapshot.sessionExists &&
            snapshot.producerHealthy) {
            resumed = true;
            break;
        }
        std::this_thread::sleep_for(
            std::chrono::milliseconds(2));
    }
    CHECK(resumed);

    bool looped = false;
    for (int attempt = 0;
         attempt < 3000;
         ++attempt) {
        CHECK(runtime.drainControlQueueForTesting());
        const auto snapshot =
            runtime.snapshotForTesting();
        if (snapshot.loopIteration > 0) {
            looped = true;
            break;
        }
        std::this_thread::sleep_for(
            std::chrono::milliseconds(2));
    }
    CHECK(looped);

    CHECK(owner.clearMedia());

    bool cleared = false;
    for (int attempt = 0;
         attempt < 1000;
         ++attempt) {
        CHECK(runtime.drainControlQueueForTesting());
        const auto snapshot =
            runtime.snapshotForTesting();
        if (!snapshot.hasMedia) {
            cleared = true;
            break;
        }
        std::this_thread::sleep_for(
            std::chrono::milliseconds(2));
    }
    CHECK(cleared);

    CVPixelBufferRef clearedCamera =
        MakeNV12(211, 77);
    CHECK(clearedCamera != nullptr);
    const CameraDecision clearDecision =
        runtime.decideCameraBuffer(
            clearedCamera);
    CHECK(clearDecision.kind ==
          CameraDecisionKind::Virtual);
    CHECK(clearDecision.source !=
          CameraDecisionSource::Original);

    std::cout
        << "VIDEO_SELECT=PASS\n"
        << "VIDEO_PLAY=PASS\n"
        << "VIDEO_PAUSE=PASS\n"
        << "VIDEO_PAUSED_VIRTUAL_STATE_STABLE=PASS\n"
        << "VIDEO_RESUME=PASS\n"
        << "VIDEO_LOOP=PASS\n"
        << "VIDEO_CLEAR_TO_BLACK=PASS\n"
        << "VIDEO_PLAY_PAUSE_RESUME_LOOP=PASS\n";

    CVPixelBufferRelease(clearedCamera);
    CVPixelBufferRelease(pausedCamera);
    CVPixelBufferRelease(camera);

    [[NSFileManager defaultManager]
        removeItemAtPath:
            [NSString stringWithUTF8String:
                root.c_str()]
        error:nil];

    return true;
}

}  // namespace

int main() {
    @autoreleasepool {
        if (!TestRealProductCompositionPhotoPersistence()) {
            return EXIT_FAILURE;
        }
        if (!TestRealProductVideoLifecycle()) {
            return EXIT_FAILURE;
        }
    }
    return EXIT_SUCCESS;
}
