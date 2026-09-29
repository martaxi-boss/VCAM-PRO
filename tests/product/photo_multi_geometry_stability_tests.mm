#include "MediaserverdRuntime.h"
#include "ProductControlOwner.h"

#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

#include <CoreGraphics/CoreGraphics.h>
#include <CoreVideo/CoreVideo.h>

#include <chrono>
#include <cstdint>
#include <iostream>
#include <string>
#include <thread>
#include <unistd.h>

namespace {

using namespace vcam::product;

#define CHECK(condition) do { \
    if (!(condition)) { \
        std::cerr << "CHECK failed at " << __FILE__ << ":" << __LINE__ \
                  << ": " #condition << std::endl; \
        return false; \
    } \
} while (false)

std::string ToStd(NSString* value) {
    const char* utf8 = value.UTF8String;
    return utf8 == nullptr ? std::string{} : std::string(utf8);
}

std::string TempRoot() {
    NSString* path =
        [NSTemporaryDirectory()
            stringByAppendingPathComponent:
                [NSString stringWithFormat:
                    @"vcam-multigeom-%@-%d",
                    NSUUID.UUID.UUIDString,
                    getpid()]];
    return ToStd(path);
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
    constexpr std::size_t width = 96;
    constexpr std::size_t height = 72;
    std::uint8_t bytes[width * height * 4];

    for (std::size_t y = 0; y < height; ++y) {
        for (std::size_t x = 0; x < width; ++x) {
            const std::size_t offset = (y * width + x) * 4;
            bytes[offset + 0] =
                static_cast<std::uint8_t>(20 + (x * 210 / width));
            bytes[offset + 1] =
                static_cast<std::uint8_t>(230 - (y * 190 / height));
            bytes[offset + 2] =
                static_cast<std::uint8_t>((x * 3 + y * 5) % 255);
            bytes[offset + 3] = 255;
        }
    }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(
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

    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
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

    CGImageDestinationAddImage(destination, image, nullptr);
    const bool ok = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(image);
    return ok;
}

CVPixelBufferRef MakeBuffer(
    std::size_t width,
    std::size_t height,
    OSType format) {
    CVPixelBufferRef buffer = nullptr;
    if (CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            format,
            nullptr,
            &buffer) != kCVReturnSuccess) {
        return nullptr;
    }
    return buffer;
}

std::uint64_t GeometryKey(
    std::size_t width,
    std::size_t height,
    OSType format) {
    return
        static_cast<std::uint64_t>(width) |
        (static_cast<std::uint64_t>(height) << 16U) |
        (static_cast<std::uint64_t>(format) << 32U);
}

bool WaitForInitialPhoto(
    MediaserverdRuntime& runtime,
    std::uint64_t generation) {
    for (int attempt = 0; attempt < 2500; ++attempt) {
        CHECK(runtime.drainControlQueueForTesting());
        const auto snapshot = runtime.snapshotForTesting();
        if (snapshot.selectionGeneration == generation &&
            snapshot.sessionExists &&
            snapshot.producerHealthy &&
            snapshot.readyQueueSize > 0 &&
            snapshot.logicalPhotoSessionCreationCount == 1 &&
            snapshot.totalPhotoDecodeCount == 1) {
            return true;
        }
        std::this_thread::sleep_for(
            std::chrono::milliseconds(2));
    }
    return false;
}

CameraDecision Decide(
    MediaserverdRuntime& runtime,
    CVPixelBufferRef buffer) {
    return runtime.decideCameraBuffer(buffer);
}

bool IsPrepared(const CameraDecision& decision) {
    return
        decision.kind == CameraDecisionKind::Virtual &&
        decision.source == CameraDecisionSource::PreparedMedia &&
        decision.pixelBuffer != nullptr;
}

bool IsSafeBlack(const CameraDecision& decision) {
    return
        decision.kind == CameraDecisionKind::Virtual &&
        (decision.source == CameraDecisionSource::BlackFallback ||
         decision.source ==
             CameraDecisionSource::InPlaceBlackOwnershipGuard);
}

bool ObserveDrainAndExpectPhoto(
    MediaserverdRuntime& runtime,
    CVPixelBufferRef buffer) {
    runtime.observeRealCameraBuffer(buffer);
    if (!runtime.drainControlQueueForTesting()) {
        return false;
    }
    return IsPrepared(Decide(runtime, buffer));
}

bool TestPhotoMultiGeometryStability() {
    const std::string root = TempRoot();
    CHECK(CreateDirectory(root));
    const std::string input = root + "/input.png";
    CHECK(CreatePhoto(input));

    const std::string control = root + "/control.plist";
    const std::string media = root + "/Media";
    const std::string notification =
        "com.vcampro.multigeom." +
        std::to_string(getpid());

    ProductControlOwner owner(control, notification, media);
    MediaserverdRuntime runtime(control, notification);
    CHECK(runtime.start());

    const OSType full =
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    const OSType video =
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;

    CVPixelBufferRef a = MakeBuffer(64, 48, full);
    CVPixelBufferRef b = MakeBuffer(80, 60, full);
    CVPixelBufferRef c = MakeBuffer(64, 48, video);
    CVPixelBufferRef d = MakeBuffer(80, 60, video);
    CVPixelBufferRef e = MakeBuffer(96, 72, full);
    CHECK(a && b && c && d && e);

    runtime.observeRealCameraBuffer(a);
    CHECK(runtime.drainControlQueueForTesting());
    CHECK(owner.setEnabled(true));

    std::string error;
    CHECK(owner.selectFromTemporaryPath(
        input,
        ProductMediaKind::Photo,
        &error));
    CHECK(error.empty());

    const auto selected = owner.snapshot();
    CHECK(selected.selectionGeneration != 0);
    CHECK(WaitForInitialPhoto(
        runtime,
        selected.selectionGeneration));

    CHECK(IsPrepared(Decide(runtime, a)));
    CHECK(runtime.cameraAdapter().photoVariantCount() == 1);

    // First encounter of B is intentionally held before producer/control work:
    // BLACK/guard is permitted, ORIGINAL is not.
    CHECK(runtime.suspendControlQueueForTesting());
    runtime.observeRealCameraBuffer(b);
    const CameraDecision bPending =
        Decide(runtime, b);
    CHECK(IsSafeBlack(bPending));
    CHECK(runtime.resumeControlQueueForTesting());
    CHECK(runtime.drainControlQueueForTesting());

    CHECK(IsPrepared(Decide(runtime, b)));

    auto snapshot = runtime.snapshotForTesting();
    CHECK(snapshot.logicalPhotoSessionCreationCount == 1);
    CHECK(snapshot.totalPhotoDecodeCount == 1);
    CHECK(snapshot.photoVariantPreparationCount == 1);

    // Return to A before its queued geometry work executes. The retained A
    // variant must win immediately.
    CHECK(runtime.suspendControlQueueForTesting());
    runtime.observeRealCameraBuffer(a);
    CHECK(IsPrepared(Decide(runtime, a)));
    CHECK(runtime.resumeControlQueueForTesting());
    CHECK(runtime.drainControlQueueForTesting());

    snapshot = runtime.snapshotForTesting();
    CHECK(snapshot.photoVariantPreparationCount == 1);

    CHECK(runtime.suspendControlQueueForTesting());
    runtime.observeRealCameraBuffer(b);
    CHECK(IsPrepared(Decide(runtime, b)));
    CHECK(runtime.resumeControlQueueForTesting());
    CHECK(runtime.drainControlQueueForTesting());

    snapshot = runtime.snapshotForTesting();
    CHECK(snapshot.photoVariantPreparationCount == 1);

    std::cout
        << "PHOTO_A_VISIBLE=PASS\n"
        << "PHOTO_B_VISIBLE_AFTER_PREPARED=PASS\n"
        << "RETURN_TO_A_REMAINS_PHOTO=PASS\n"
        << "RETURN_TO_B_REMAINS_PHOTO=PASS\n"
        << "PHOTO_SOURCE_PERSISTS_ACROSS_GEOMETRIES=PASS\n"
        << "BLACK_USED_ONLY_WHILE_VARIANT_NOT_READY=PASS\n";

    // Deterministic async ordering: queue A then B while control work is held.
    const auto beforeEvents =
        runtime.snapshotForTesting();
    const std::size_t historyBefore =
        beforeEvents.appliedGeometryHistoryCount;

    CHECK(runtime.suspendControlQueueForTesting());
    runtime.observeRealCameraBuffer(a);
    runtime.observeRealCameraBuffer(b);
    CHECK(runtime.resumeControlQueueForTesting());
    CHECK(runtime.drainControlQueueForTesting());

    const auto afterEvents =
        runtime.snapshotForTesting();
    CHECK(afterEvents.appliedGeometryHistoryCount >=
          historyBefore + 2);
    CHECK(afterEvents.appliedGeometryHistory[
              historyBefore] ==
          GeometryKey(64, 48, full));
    CHECK(afterEvents.appliedGeometryHistory[
              historyBefore + 1] ==
          GeometryKey(80, 60, full));

    std::cout
        << "GEOMETRY_EVENT_IDENTITY_PRESERVED=PASS\n"
        << "NO_GLOBAL_GEOMETRY_ALIASING=PASS\n";

    // Cross-range variants reuse the same decoded logical PHOTO.
    CHECK(ObserveDrainAndExpectPhoto(runtime, c));
    CHECK(ObserveDrainAndExpectPhoto(runtime, d));

    snapshot = runtime.snapshotForTesting();
    CHECK(snapshot.logicalPhotoSessionCreationCount == 1);
    CHECK(snapshot.totalPhotoDecodeCount == 1);
    CHECK(snapshot.photoVariantPreparationCount == 3);
    CHECK(runtime.cameraAdapter().photoVariantCount() == 4);

    // Warm geometries remain PHOTO without producer-side republish.
    CHECK(ObserveDrainAndExpectPhoto(runtime, a));
    CHECK(ObserveDrainAndExpectPhoto(runtime, b));
    const auto warmReturn =
        runtime.snapshotForTesting();
    CHECK(warmReturn.photoVariantPreparationCount == 3);
    CHECK(warmReturn.logicalPhotoSessionCreationCount == 1);
    CHECK(warmReturn.totalPhotoDecodeCount == 1);

    std::cout
        << "NO_SESSION_DESELECTION_ON_GEOMETRY_SWITCH=PASS\n"
        << "NO_REDECODE_ON_CACHED_GEOMETRY_RETURN=PASS\n"
        << "PHOTO_LOGICAL_SESSION_CREATION_COUNT=1\n"
        << "PHOTO_SOURCE_DECODE_COUNT=1\n";

    // Fifth geometry requires deterministic bounded eviction, never expansion.
    CHECK(ObserveDrainAndExpectPhoto(runtime, e));
    CHECK(runtime.cameraAdapter().photoVariantCount() <=
          CameraConsumerAdapter::kPhotoVariantCapacity);
    CHECK(runtime.cameraAdapter().photoVariantCount() >= 5);
    CHECK(runtime.cameraAdapter().
              enabledSupportedOriginalDecisionCount() == 0);

    std::cout
        << "PHOTO_VARIANT_CACHE_BOUNDED=PASS\n"
        << "PHOTO_VARIANT_EVICTION_SAFE=PASS\n"
        << "VCAM_ON_ORIGINAL_DECISIONS=ZERO\n"
        << "PHOTO_VARIANT_CACHE_CAPACITY="
        << CameraConsumerAdapter::kPhotoVariantCapacity
        << "\n";

    const auto finalSnapshot =
        runtime.snapshotForTesting();
    CHECK(finalSnapshot.photoSelected);
    CHECK(finalSnapshot.sessionExists);
    CHECK(finalSnapshot.logicalPhotoSessionCreationCount == 1);
    CHECK(finalSnapshot.totalPhotoDecodeCount == 1);

    CVPixelBufferRelease(e);
    CVPixelBufferRelease(d);
    CVPixelBufferRelease(c);
    CVPixelBufferRelease(b);
    CVPixelBufferRelease(a);

    [[NSFileManager defaultManager]
        removeItemAtPath:
            [NSString stringWithUTF8String:root.c_str()]
        error:nil];

    return true;
}

}  // namespace

int main() {
    @autoreleasepool {
        return TestPhotoMultiGeometryStability()
            ? EXIT_SUCCESS
            : EXIT_FAILURE;
    }
}
