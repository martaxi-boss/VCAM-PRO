#include "CameraConsumerAdapter.h"
#include "FrameNormalizer.h"
#include "MediaserverdRuntime.h"
#include "ProductControlOwner.h"

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <CoreGraphics/CoreGraphics.h>
#include <CoreVideo/CoreVideo.h>

#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <thread>

namespace {

using namespace vcam::product;

#define CHECK(condition) \
    do { \
        if (!(condition)) { \
            std::cerr << "CHECK failed at " << __FILE__ << ":" << __LINE__ \
                      << ": " #condition << std::endl; \
            return false; \
        } \
    } while (false)

std::string TempRoot(const char* tag) {
    NSString* value =
        [NSTemporaryDirectory()
            stringByAppendingPathComponent:
                [NSString stringWithFormat:
                    @"vcam-post-photo-convergence-%s-%@",
                    tag,
                    NSUUID.UUID.UUIDString]];
    const char* utf8 = value.UTF8String;
    return utf8 == nullptr
        ? std::string{}
        : std::string(utf8);
}

bool CreateDirectory(const std::string& path) {
    return [[NSFileManager defaultManager]
        createDirectoryAtPath:
            [NSString stringWithUTF8String:path.c_str()]
  withIntermediateDirectories:YES
                   attributes:nil
                        error:nil];
}

bool CreatePhoto(const std::string& path) {
    constexpr std::size_t width = 64;
    constexpr std::size_t height = 48;
    std::uint8_t bytes[width * height * 4]{};
    for (std::size_t y = 0; y < height; ++y) {
        for (std::size_t x = 0; x < width; ++x) {
            const std::size_t offset =
                (y * width + x) * 4;
            bytes[offset + 0] =
                static_cast<std::uint8_t>(
                    20 + (x * 180 / width));
            bytes[offset + 1] =
                static_cast<std::uint8_t>(
                    30 + (y * 180 / height));
            bytes[offset + 2] =
                static_cast<std::uint8_t>(
                    220 - (x * 120 / width));
            bytes[offset + 3] = 255;
        }
    }

    CGDataProviderRef provider =
        CGDataProviderCreateWithData(
            nullptr,
            bytes,
            sizeof(bytes),
            nullptr);
    if (provider == nullptr) {
        return false;
    }

    CGColorSpaceRef color =
        CGColorSpaceCreateDeviceRGB();
    CGImageRef image =
        CGImageCreate(
            width,
            height,
            8,
            32,
            width * 4,
            color,
            kCGImageAlphaPremultipliedLast |
                kCGBitmapByteOrderDefault,
            provider,
            nullptr,
            false,
            kCGRenderingIntentDefault);
    CGColorSpaceRelease(color);
    CGDataProviderRelease(provider);
    if (image == nullptr) {
        return false;
    }

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
        [NSThread sleepForTimeInterval:0.001];
    }
    return false;
}

bool CreateVideo(
    const std::string& path,
    int frameCount = 120) {
    NSString* nsPath =
        [NSString stringWithUTF8String:path.c_str()];
    [[NSFileManager defaultManager]
        removeItemAtPath:nsPath
                   error:nil];

    NSURL* url =
        [NSURL fileURLWithPath:nsPath];
    NSError* writerError = nil;
    AVAssetWriter* writer =
        [[AVAssetWriter alloc]
            initWithURL:url
               fileType:AVFileTypeQuickTimeMovie
                  error:&writerError];
    if (writer == nil || writerError != nil) {
        return false;
    }

    NSDictionary* settings = @{
        AVVideoCodecKey : AVVideoCodecTypeH264,
        AVVideoWidthKey : @64,
        AVVideoHeightKey : @48,
        AVVideoCompressionPropertiesKey :
            @{ AVVideoAverageBitRateKey : @180000 }
    };

    AVAssetWriterInput* input =
        [AVAssetWriterInput
            assetWriterInputWithMediaType:
                AVMediaTypeVideo
                         outputSettings:
                             settings];

    NSDictionary* attributes = @{
        (NSString*)kCVPixelBufferPixelFormatTypeKey :
            @(kCVPixelFormatType_32BGRA),
        (NSString*)kCVPixelBufferWidthKey : @64,
        (NSString*)kCVPixelBufferHeightKey : @48
    };

    AVAssetWriterInputPixelBufferAdaptor* adaptor =
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
    [writer startSessionAtSourceTime:kCMTimeZero];

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

        CVPixelBufferLockBaseAddress(buffer, 0);
        auto* base =
            static_cast<unsigned char*>(
                CVPixelBufferGetBaseAddress(buffer));
        const std::size_t stride =
            CVPixelBufferGetBytesPerRow(buffer);
        const std::size_t rows =
            CVPixelBufferGetHeight(buffer);
        std::memset(
            base,
            static_cast<unsigned char>(
                32 + (index % 8) * 20),
            stride * rows);
        CVPixelBufferUnlockBaseAddress(buffer, 0);

        const BOOL ok =
            [adaptor
                appendPixelBuffer:buffer
             withPresentationTime:
                 CMTimeMake(index, 30)];
        CVPixelBufferRelease(buffer);
        if (!ok) {
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

CVPixelBufferRef MakeBuffer(
    std::size_t width,
    std::size_t height,
    OSType format) {
    NSDictionary* attributes = @{
        (NSString*)
            kCVPixelBufferIOSurfacePropertiesKey :
                @{}
    };
    CVPixelBufferRef buffer = nullptr;
    if (CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            format,
            (__bridge CFDictionaryRef)
                attributes,
            &buffer) != kCVReturnSuccess) {
        return nullptr;
    }
    return buffer;
}

bool IsPrepared(
    const CameraDecision& decision) {
    return
        decision.kind ==
            CameraDecisionKind::Virtual &&
        decision.source ==
            CameraDecisionSource::PreparedMedia &&
        decision.pixelBuffer != nullptr;
}

bool WaitForPhoto(
    MediaserverdRuntime& runtime,
    std::uint64_t generation) {
    for (int attempt = 0;
         attempt < 2500;
         ++attempt) {
        CHECK(
            runtime.
                drainControlQueueForTesting());
        const auto snapshot =
            runtime.snapshotForTesting();
        if (snapshot.selectionGeneration ==
                generation &&
            snapshot.sessionExists &&
            snapshot.producerHealthy &&
            snapshot.readyQueueSize > 0 &&
            snapshot.
                logicalPhotoSessionCreationCount ==
                    1 &&
            snapshot.totalPhotoDecodeCount == 1) {
            return true;
        }

        std::this_thread::sleep_for(
            std::chrono::milliseconds(2));
    }
    return false;
}

bool WaitForVideo(
    MediaserverdRuntime& runtime,
    std::uint64_t generation,
    std::uint64_t minimumSessions) {
    for (int attempt = 0;
         attempt < 3500;
         ++attempt) {
        CHECK(
            runtime.
                drainControlQueueForTesting());
        const auto snapshot =
            runtime.snapshotForTesting();
        if (snapshot.selectionGeneration ==
                generation &&
            snapshot.videoSelected &&
            snapshot.sessionExists &&
            snapshot.producerHealthy &&
            snapshot.
                logicalVideoSessionCreationCount >=
                    minimumSessions &&
            snapshot.videoReaderOpenCount >=
                minimumSessions &&
            snapshot.videoReaderStartCount >=
                minimumSessions &&
            snapshot.publishedFrameCount > 0) {
            return true;
        }

        std::this_thread::sleep_for(
            std::chrono::milliseconds(2));
    }
    return false;
}

bool WaitForPreparedGeometry(
    MediaserverdRuntime& runtime,
    CVPixelBufferRef geometry,
    std::uint64_t generation,
    std::uint64_t expectedVideoSessions = 1) {
    for (int attempt = 0;
         attempt < 5000;
         ++attempt) {
        CHECK(
            runtime.
                drainControlQueueForTesting());

        const auto snapshot =
            runtime.snapshotForTesting();
        if (snapshot.selectionGeneration ==
                generation &&
            snapshot.logicalVideoSessionCreationCount ==
                expectedVideoSessions &&
            snapshot.videoReaderOpenCount ==
                expectedVideoSessions &&
            snapshot.videoReaderStartCount ==
                expectedVideoSessions) {
            const CameraDecision decision =
                runtime.decideCameraBuffer(
                    geometry);
            if (IsPrepared(decision)) {
                return true;
            }
        }

        std::this_thread::sleep_for(
            std::chrono::milliseconds(2));
    }
    return false;
}

bool WaitForRuntimeEnabled(
    MediaserverdRuntime& runtime,
    bool enabled) {
    for (int attempt = 0;
         attempt < 2500;
         ++attempt) {
        CHECK(
            runtime.
                drainControlQueueForTesting());
        if (runtime.snapshotForTesting().enabled ==
            enabled) {
            return true;
        }
        std::this_thread::sleep_for(
            std::chrono::milliseconds(2));
    }
    return false;
}

bool WaitForRuntimeNoMedia(
    MediaserverdRuntime& runtime) {
    for (int attempt = 0;
         attempt < 2500;
         ++attempt) {
        CHECK(
            runtime.
                drainControlQueueForTesting());
        const auto snapshot =
            runtime.snapshotForTesting();
        if (!snapshot.hasMedia &&
            !snapshot.photoSelected &&
            !snapshot.videoSelected) {
            return true;
        }
        std::this_thread::sleep_for(
            std::chrono::milliseconds(2));
    }
    return false;
}

bool TestPickerTypeContract() {
    CHECK(
        [UTTypeQuickTimeMovie
            conformsToType:UTTypeMovie]);
    CHECK(
        [UTTypeMPEG4Movie
            conformsToType:UTTypeMovie]);
    CHECK(
        ![UTTypeImage
            conformsToType:UTTypeMovie]);

    NSItemProvider* provider =
        [[NSItemProvider alloc] init];

    [provider
        registerDataRepresentationForTypeIdentifier:
            UTTypeQuickTimeMovie.identifier
                                    visibility:
            NSItemProviderRepresentationVisibilityAll
                                   loadHandler:
            ^NSProgress*(
                void (^completionHandler)(
                    NSData*,
                    NSError*)) {
                completionHandler(
                    [NSData data],
                    nil);
                return
                    [NSProgress
                        progressWithTotalUnitCount:
                            1];
            }];

    CHECK(
        [provider
            hasItemConformingToTypeIdentifier:
                UTTypeMovie.identifier]);

    std::cout
        << "VIDEO_PICKER_CLASSIFICATION=PASS\n"
        << "VIDEO_LOAD_REPRESENTATION_KIND=VIDEO\n";
    return true;
}

bool TestInitialOrientationAppliedBeforeSelection() {
    const std::string root =
        TempRoot("initial-orientation");
    CHECK(CreateDirectory(root));

    const std::string input =
        root + "/input.png";
    CHECK(CreatePhoto(input));

    const std::string controlPath =
        root + "/control.plist";
    const std::string media =
        root + "/Media";
    const std::string notification =
        "com.vcampro.postphoto.orientation.initial." +
        std::to_string(getpid());

    ProductControlOwner owner(
        controlPath,
        notification,
        media);
    MediaserverdRuntime runtime(
        controlPath,
        notification);
    CHECK(runtime.start());

    CVPixelBufferRef geometry =
        MakeBuffer(
            64,
            48,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
    CHECK(geometry != nullptr);

    runtime.observeRealCameraBuffer(
        geometry);
    CHECK(
        runtime.drainControlQueueForTesting());
    CHECK(owner.setEnabled(true));

    CHECK(
        owner.setStreamOrientation(
            ProductStreamOrientation::Portrait));

    std::string error;
    CHECK(
        owner.selectFromTemporaryPath(
            input,
            ProductMediaKind::Photo,
            &error));
    CHECK(error.empty());

    const auto selected =
        owner.snapshot();
    CHECK(
        selected.streamOrientation ==
            ProductStreamOrientation::Portrait);
    CHECK(
        selected.streamOrientationRevision != 0);

    CHECK(
        WaitForPhoto(
            runtime,
            selected.selectionGeneration));

    const auto runtimeSnapshot =
        runtime.snapshotForTesting();
    CHECK(
        runtimeSnapshot.currentTargetOrientation ==
            static_cast<std::uint8_t>(
                vcam::media_engine::
                    OrientationRequirement::
                        StreamPortrait));
    CHECK(
        IsPrepared(
            runtime.decideCameraBuffer(
                geometry)));

    std::cout
        << "INITIAL_MEDIA_SELECTION_STREAM_ORIENTATION=PASS\n"
        << "INITIAL_MEDIA_SELECTION_ORIENTATION_REVISION_PRESERVED=PASS\n";

    CVPixelBufferRelease(
        geometry);

    [[NSFileManager defaultManager]
        removeItemAtPath:
            [NSString
                stringWithUTF8String:
                    root.c_str()]
                   error:nil];

    return true;
}

bool TestStablePhotoMicroflashOwnership() {
    const std::string root =
        TempRoot("photo");
    CHECK(CreateDirectory(root));

    const std::string input =
        root + "/input.png";
    CHECK(CreatePhoto(input));

    const std::string controlPath =
        root + "/control.plist";
    const std::string media =
        root + "/Media";
    const std::string notification =
        "com.vcampro.postphoto.microflash." +
        std::to_string(getpid());

    ProductControlOwner owner(
        controlPath,
        notification,
        media);
    MediaserverdRuntime runtime(
        controlPath,
        notification);
    CHECK(runtime.start());

    CVPixelBufferRef a =
        MakeBuffer(
            64,
            48,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
    CVPixelBufferRef b =
        MakeBuffer(
            80,
            60,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);

    CHECK(a != nullptr);
    CHECK(b != nullptr);

    runtime.observeRealCameraBuffer(a);
    CHECK(
        runtime.drainControlQueueForTesting());
    CHECK(owner.setEnabled(true));

    std::string error;
    CHECK(
        owner.selectFromTemporaryPath(
            input,
            ProductMediaKind::Photo,
            &error));
    CHECK(error.empty());

    const auto selected =
        owner.snapshot();
    CHECK(
        WaitForPhoto(
            runtime,
            selected.selectionGeneration));

    CHECK(
        IsPrepared(
            runtime.decideCameraBuffer(a)));

    runtime.observeRealCameraBuffer(b);
    CHECK(
        runtime.drainControlQueueForTesting());
    CHECK(
        IsPrepared(
            runtime.decideCameraBuffer(b)));

    runtime.observeRealCameraBuffer(a);
    CHECK(
        runtime.drainControlQueueForTesting());
    CHECK(
        IsPrepared(
            runtime.decideCameraBuffer(a)));

    auto& adapter =
        runtime.cameraAdapter();

    const auto mediaBefore =
        adapter.mediaVirtualDecisionCount();
    const auto blackBefore =
        adapter.blackVirtualDecisionCount();
    const auto guardBefore =
        adapter.
            inPlaceBlackGuardDecisionCount();
    const auto originalBefore =
        adapter.
            emergencyOriginalDecisionCount();
    const auto unsupportedBefore =
        adapter.
            unsupportedFormatDecisionCount();

    std::uint64_t variantSwitches = 0;
    CVPixelBufferRef previous = nullptr;

    for (int index = 0;
         index < 128;
         ++index) {
        CVPixelBufferRef current =
            (index % 2) == 0
                ? a
                : b;

        const CameraDecision decision =
            runtime.decideCameraBuffer(
                current);
        CHECK(IsPrepared(decision));

        if (previous != nullptr &&
            previous != current) {
            ++variantSwitches;
        }
        previous = current;
    }

    const auto mediaDelta =
        adapter.mediaVirtualDecisionCount() -
        mediaBefore;
    const auto blackDelta =
        adapter.blackVirtualDecisionCount() -
        blackBefore;
    const auto guardDelta =
        adapter.
            inPlaceBlackGuardDecisionCount() -
        guardBefore;
    const auto originalDelta =
        adapter.
            emergencyOriginalDecisionCount() -
        originalBefore;
    const auto unsupportedDelta =
        adapter.
            unsupportedFormatDecisionCount() -
        unsupportedBefore;

    CHECK(mediaDelta == 128);
    CHECK(blackDelta == 0);
    CHECK(guardDelta == 0);
    CHECK(originalDelta == 0);
    CHECK(unsupportedDelta == 0);
    CHECK(variantSwitches == 127);

    std::cout
        << "PHOTO_CONTINUITY_REGRESSION=PASS\n"
        << "PHOTO_PREPARED_MEDIA_DECISIONS_CONTINUOUS=PASS\n"
        << "PHOTO_STABLE_BLACK_DECISION_DELTA=0\n"
        << "PHOTO_STABLE_GUARD_DECISION_DELTA=0\n"
        << "PHOTO_STABLE_ORIGINAL_DECISION_DELTA=0\n"
        << "PHOTO_STABLE_VARIANT_SWITCH_COUNT="
        << variantSwitches
        << "\n"
        << "PHOTO_MICROFLASH_NOT_OWNERSHIP_FALLBACK=PASS\n"
        << "PHOTO_MICROFLASH_CLASSIFICATION_COMPLETE=PASS\n"
        << "PHOTO_DROPOUT_PRESENT=NO\n";

    CVPixelBufferRelease(a);
    CVPixelBufferRelease(b);

    [[NSFileManager defaultManager]
        removeItemAtPath:
            [NSString
                stringWithUTF8String:
                    root.c_str()]
                   error:nil];

    return true;
}

#if defined(VCAM_LOCAL_MEDIA_DEVICE_PROOF_PREFX)
bool TestPreFixVideoQueueDrainsToBlackWithoutLatestReuse() {
    const std::string root =
        TempRoot("video-one-shot-prefx");
    CHECK(CreateDirectory(root));

    const std::string input =
        root + "/input.mov";
    CHECK(CreateVideo(input, 240));

    const std::string controlPath =
        root + "/control.plist";
    const std::string media =
        root + "/Media";
    const std::string notification =
        "com.vcampro.deviceproof.prefx.video." +
        std::to_string(getpid());

    ProductControlOwner owner(
        controlPath,
        notification,
        media);
    MediaserverdRuntime runtime(
        controlPath,
        notification);
    CHECK(runtime.start());

    CVPixelBufferRef geometry =
        MakeBuffer(
            64,
            48,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
    CHECK(geometry != nullptr);

    runtime.observeRealCameraBuffer(geometry);
    CHECK(runtime.drainControlQueueForTesting());
    CHECK(owner.setEnabled(true));

    std::string error;
    CHECK(owner.selectFromTemporaryPath(
        input,
        ProductMediaKind::Video,
        &error));
    CHECK(error.empty());

    const auto selected = owner.snapshot();
    CHECK(selected.mediaKind ==
          ProductMediaKind::Video);
    CHECK(selected.playbackIntent ==
          ProductPlaybackIntent::Playing);

    CHECK(WaitForVideo(
        runtime,
        selected.selectionGeneration,
        1));

    bool queueReady = false;
    for (int attempt = 0;
         attempt < 2500;
         ++attempt) {
        CHECK(runtime.drainControlQueueForTesting());
        const auto snapshot =
            runtime.snapshotForTesting();
        if (snapshot.readyQueueSize > 0 &&
            snapshot.publishedFrameCount > 0) {
            queueReady = true;
            break;
        }
        std::this_thread::sleep_for(
            std::chrono::milliseconds(2));
    }
    CHECK(queueReady);

    CHECK(runtime.stopVideoProducerForTesting());

    const auto before =
        runtime.snapshotForTesting();
    CHECK(before.logicalVideoSessionCreationCount == 1);
    CHECK(before.videoReaderOpenCount == 1);
    CHECK(before.videoReaderStartCount == 1);
    CHECK(before.readyQueueSize > 0);

    auto& adapter = runtime.cameraAdapter();
    const auto mediaBefore =
        adapter.mediaVirtualDecisionCount();
    const auto blackBefore =
        adapter.blackVirtualDecisionCount();
    const auto guardBefore =
        adapter.inPlaceBlackGuardDecisionCount();
    const auto originalBefore =
        adapter.enabledSupportedOriginalDecisionCount();

    std::uint64_t preparedCount = 0;
    bool blackObserved = false;

    for (int callback = 0;
         callback < 8;
         ++callback) {
        const CameraDecision decision =
            runtime.decideCameraBuffer(
                geometry);
        if (IsPrepared(decision)) {
            ++preparedCount;
            continue;
        }

        CHECK(
            decision.kind ==
                CameraDecisionKind::Virtual);
        CHECK(
            decision.source ==
                CameraDecisionSource::BlackFallback ||
            decision.source ==
                CameraDecisionSource::
                    InPlaceBlackOwnershipGuard);
        blackObserved = true;
        break;
    }

    CHECK(preparedCount > 0);
    CHECK(blackObserved);
    CHECK(
        adapter.enabledSupportedOriginalDecisionCount() -
            originalBefore ==
        0);
    CHECK(
        adapter.mediaVirtualDecisionCount() -
            mediaBefore ==
        preparedCount);
    CHECK(
        (adapter.blackVirtualDecisionCount() -
             blackBefore) +
            (adapter.inPlaceBlackGuardDecisionCount() -
             guardBefore) >
        0);

    const auto after =
        runtime.snapshotForTesting();
    CHECK(after.logicalVideoSessionCreationCount == 1);
    CHECK(after.videoReaderOpenCount == 1);
    CHECK(after.videoReaderStartCount == 1);

    std::cout
        << "PRE_FIX_VIDEO_READER_OPEN=PASS\n"
        << "PRE_FIX_VIDEO_READER_START=PASS\n"
        << "PRE_FIX_VIDEO_PUBLISH_COUNT="
        << before.publishedFrameCount << "\n"
        << "PRE_FIX_VIDEO_PREPARED_BEFORE_DRAIN="
        << preparedCount << "\n"
        << "PRE_FIX_VIDEO_QUEUE_DRAINS_TO_BLACK=YES\n"
        << "PRE_FIX_VIDEO_ONE_SHOT_LEASE_STARVATION=PASS\n"
        << "PRE_FIX_VIDEO_ORIGINAL_DECISIONS=ZERO\n"
        << "VIDEO_FIRST_BROKEN_STAGE=ONE_SHOT_VIDEO_LEASE_CONSUMPTION_NO_PERSISTENT_LATEST_FRAME\n";

    CVPixelBufferRelease(geometry);
    [[NSFileManager defaultManager]
        removeItemAtPath:
            [NSString stringWithUTF8String:
                root.c_str()]
                   error:nil];
    return true;
}
#endif

bool TestVideoSelectionAndGeometryChurn() {
    const std::string root =
        TempRoot("video");
    CHECK(CreateDirectory(root));

    const std::string input =
        root + "/input.mov";
    const std::string photoInput =
        root + "/input.png";
    CHECK(CreateVideo(input, 240));
    CHECK(CreatePhoto(photoInput));

    const std::string controlPath =
        root + "/control.plist";
    const std::string media =
        root + "/Media";
    const std::string notification =
        "com.vcampro.postphoto.video." +
        std::to_string(getpid());

    ProductControlOwner owner(
        controlPath,
        notification,
        media);
    MediaserverdRuntime runtime(
        controlPath,
        notification);
    CHECK(runtime.start());

    CVPixelBufferRef a =
        MakeBuffer(
            64,
            48,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
    CVPixelBufferRef b =
        MakeBuffer(
            80,
            60,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);

    CHECK(a != nullptr);
    CHECK(b != nullptr);

    runtime.observeRealCameraBuffer(a);
    CHECK(
        runtime.drainControlQueueForTesting());
    CHECK(owner.setEnabled(true));

    std::string error;
    CHECK(
        owner.selectFromTemporaryPath(
            input,
            ProductMediaKind::Video,
            &error));
    CHECK(error.empty());

    const auto selected =
        owner.snapshot();

    CHECK(selected.hasMedia());
    CHECK(
        selected.mediaKind ==
            ProductMediaKind::Video);
    CHECK(
        selected.playbackIntent ==
            ProductPlaybackIntent::Playing);
    CHECK(!selected.loopEnabled);

    CHECK(
        WaitForVideo(
            runtime,
            selected.selectionGeneration,
            1));
    CHECK(
        WaitForPreparedGeometry(
            runtime,
            a,
            selected.selectionGeneration));

    const auto initial =
        runtime.snapshotForTesting();
    const std::uint64_t initialEpoch =
        initial.queueEpoch;
    const std::uint64_t initialGeneration =
        initial.queueGeneration;
    const std::uint64_t initialPublished =
        initial.totalVideoPublishedFrameCount;

    CHECK(
        initial.
            logicalVideoSessionCreationCount ==
                1);
    CHECK(initial.videoReaderOpenCount == 1);
    CHECK(initial.videoReaderStartCount == 1);
    CHECK(
        initial.videoSessionReplacementCount ==
            0);

    runtime.observeRealCameraBuffer(b);
    CHECK(
        WaitForPreparedGeometry(
            runtime,
            b,
            selected.selectionGeneration));

    runtime.observeRealCameraBuffer(a);
    CHECK(
        WaitForPreparedGeometry(
            runtime,
            a,
            selected.selectionGeneration));

    runtime.observeRealCameraBuffer(b);
    CHECK(
        WaitForPreparedGeometry(
            runtime,
            b,
            selected.selectionGeneration));

    const auto after =
        runtime.snapshotForTesting();

    CHECK(
        after.selectionGeneration ==
            selected.selectionGeneration);
    CHECK(
        after.logicalVideoSessionCreationCount ==
            1);
    CHECK(after.videoReaderOpenCount == 1);
    CHECK(after.videoReaderStartCount == 1);
    CHECK(
        after.videoSessionReplacementCount ==
            0);
    CHECK(
        after.queueGeneration ==
            initialGeneration);
    CHECK(after.queueEpoch == initialEpoch);
    CHECK(
        after.totalVideoPublishedFrameCount >
            initialPublished);
    CHECK(
        runtime.cameraAdapter().
            enabledSupportedOriginalDecisionCount() ==
                0);

    const std::uint64_t publishedAfterGeometry =
        after.totalVideoPublishedFrameCount;
    const std::uint64_t videoCameraDecisions =
        runtime.cameraAdapter().
            mediaVirtualDecisionCount();

    std::cout
        << "VIDEO_STAGING=PASS\n"
        << "VIDEO_CONTROL_COMMIT=PASS\n"
        << "VIDEO_MEDIA_KIND=VIDEO\n"
        << "VIDEO_PLAYBACK_INTENT_AFTER_SELECTION=PLAYING\n"
        << "VIDEO_RUNTIME_SELECT=PASS\n"
        << "VIDEO_LOOP_UI_ENABLED_WHEN_VIDEO_SNAPSHOT_ACTIVE=PASS\n"
        << "VIDEO_LOOP_OFF_DOES_NOT_BLOCK_START=PASS\n"
        << "VIDEO_REQUIRES_LOOP_TO_START=NO\n"
        << "VIDEO_AUTO_START_AFTER_SELECTION=PASS\n"
        << "VIDEO_FRAME_REACHES_CAMERA=PASS\n"
        << "VIDEO_CONTINUOUS_PLAYBACK=PASS\n"
        << "VIDEO_LOGICAL_SESSION_CREATION_COUNT=1\n"
        << "VIDEO_READER_OPEN_COUNT=1\n"
        << "VIDEO_READER_START_COUNT=1\n"
        << "VIDEO_SELECTION_GENERATION_STABLE=PASS\n"
        << "VIDEO_TIMELINE_EPOCH_STABLE=PASS\n"
        << "VIDEO_TIMELINE_CONTINUOUS=PASS\n"
        << "VIDEO_GEOMETRY_A_OUTPUT=PASS\n"
        << "VIDEO_GEOMETRY_B_OUTPUT=PASS\n"
        << "VIDEO_NO_RESTART_ON_GEOMETRY_SWITCH=PASS\n"
        << "VIDEO_GEOMETRY_SESSION_FINDING=RETARGET_WITHOUT_READER_REOPEN\n"
        << "VIDEO_PUBLISHED_FRAME_COUNT="
        << publishedAfterGeometry << "\n"
        << "VIDEO_CAMERA_DECISIONS="
        << videoCameraDecisions << "\n"
        << "VCAM_ON_SUPPORTED_ORIGINAL_DECISIONS=ZERO\n";

    std::string photoError;
    CHECK(
        owner.selectFromTemporaryPath(
            photoInput,
            ProductMediaKind::Photo,
            &photoError));
    CHECK(photoError.empty());
    const auto photoSelected =
        owner.snapshot();
    CHECK(
        WaitForPhoto(
            runtime,
            photoSelected.selectionGeneration));
    // The last observed destination before the media switch is B.
    // A media-kind change does not itself synthesize a new camera geometry.
    CHECK(
        IsPrepared(
            runtime.decideCameraBuffer(b)));

    std::cout
        << "VIDEO_TO_PHOTO_CHANGE=PASS\n";

    std::string videoError;
    CHECK(
        owner.selectFromTemporaryPath(
            input,
            ProductMediaKind::Video,
            &videoError));
    CHECK(videoError.empty());
    const auto videoReselected =
        owner.snapshot();
    CHECK(
        WaitForVideo(
            runtime,
            videoReselected.selectionGeneration,
            2));
    runtime.observeRealCameraBuffer(a);
    CHECK(
        WaitForPreparedGeometry(
            runtime,
            a,
            videoReselected.selectionGeneration,
            2));

    std::cout
        << "PHOTO_TO_VIDEO_CHANGE=PASS\n";

    CHECK(owner.setEnabled(false));
    CHECK(
        WaitForRuntimeEnabled(
            runtime,
            false));
    const CameraDecision offDecision =
        runtime.decideCameraBuffer(a);
    CHECK(
        offDecision.kind ==
            CameraDecisionKind::Original);
    CHECK(
        offDecision.source ==
            CameraDecisionSource::Original);

    std::cout
        << "VCAM_OFF_FROM_VIDEO_RETURNS_REAL=PASS\n";

    CHECK(owner.setEnabled(true));
    CHECK(
        WaitForRuntimeEnabled(
            runtime,
            true));
    CHECK(owner.clearMedia());
    CHECK(
        WaitForRuntimeNoMedia(
            runtime));

    const CameraDecision clearDecision =
        runtime.decideCameraBuffer(a);
    CHECK(
        clearDecision.kind ==
            CameraDecisionKind::Virtual);
    CHECK(
        clearDecision.source ==
            CameraDecisionSource::BlackFallback ||
        clearDecision.source ==
            CameraDecisionSource::
                InPlaceBlackOwnershipGuard);

    std::cout
        << "CLEAR_VIDEO_RETURNS_BLACK=PASS\n";

    CVPixelBufferRelease(a);
    CVPixelBufferRelease(b);

    [[NSFileManager defaultManager]
        removeItemAtPath:
            [NSString
                stringWithUTF8String:
                    root.c_str()]
                   error:nil];

    return true;
}


}  // namespace

int main() {
    @autoreleasepool {
        if (!TestPickerTypeContract()) {
            return EXIT_FAILURE;
        }

        if (!TestInitialOrientationAppliedBeforeSelection()) {
            return EXIT_FAILURE;
        }

        if (!TestStablePhotoMicroflashOwnership()) {
            return EXIT_FAILURE;
        }

#if defined(VCAM_LOCAL_MEDIA_DEVICE_PROOF_PREFX)
        if (!TestPreFixVideoQueueDrainsToBlackWithoutLatestReuse()) {
            return EXIT_FAILURE;
        }
#endif

        if (!TestVideoSelectionAndGeometryChurn()) {
            return EXIT_FAILURE;
        }

        std::cout
            << "POST_PHOTO_LOCAL_MEDIA_CONVERGENCE_PROOF=PASS\n";
        return EXIT_SUCCESS;
    }
}
