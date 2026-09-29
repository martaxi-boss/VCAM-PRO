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

std::string TempRoot(const char* suffix) {
    NSString* path =
        [NSTemporaryDirectory()
            stringByAppendingPathComponent:
                [NSString stringWithFormat:
                    @"vcam-geomws-prefx-%s-%@-%d",
                    suffix,
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
    constexpr std::size_t width = 128;
    constexpr std::size_t height = 96;
    std::uint8_t bytes[width * height * 4];

    for (std::size_t y = 0; y < height; ++y) {
        for (std::size_t x = 0; x < width; ++x) {
            const std::size_t offset = (y * width + x) * 4;
            bytes[offset + 0] =
                static_cast<std::uint8_t>(20 + (x * 220 / width));
            bytes[offset + 1] =
                static_cast<std::uint8_t>(230 - (y * 180 / height));
            bytes[offset + 2] =
                static_cast<std::uint8_t>((x * 5 + y * 3) % 255);
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

bool HasVariant(
    MediaserverdRuntime& runtime,
    const ProductControlSnapshot& control,
    std::size_t width,
    std::size_t height,
    OSType format) {
    const auto snapshot = runtime.snapshotForTesting();
    return runtime.cameraAdapter().hasReusablePhotoVariant(
        width,
        height,
        format,
        snapshot.queueGeneration,
        snapshot.queueEpoch,
        control.photoTransform.revision);
}

struct GeometryFixture {
    CVPixelBufferRef buffer = nullptr;
    std::size_t width = 0;
    std::size_t height = 0;
    OSType format = 0;
};

bool PrepareAndRetain(
    MediaserverdRuntime& runtime,
    const ProductControlSnapshot& control,
    const GeometryFixture& geometry,
    std::uint64_t* evictionCount) {
    const bool existed =
        HasVariant(
            runtime,
            control,
            geometry.width,
            geometry.height,
            geometry.format);
    const std::size_t beforeCount =
        runtime.cameraAdapter().photoVariantCount();

    runtime.observeRealCameraBuffer(
        geometry.buffer);
    CHECK(runtime.drainControlQueueForTesting());
    const CameraDecision decision =
        runtime.decideCameraBuffer(
            geometry.buffer);
    CHECK(IsPrepared(decision));

    if (!existed &&
        beforeCount ==
            CameraConsumerAdapter::kPhotoVariantCapacity &&
        runtime.cameraAdapter().photoVariantCount() ==
            CameraConsumerAdapter::kPhotoVariantCapacity) {
        ++(*evictionCount);
    }
    return true;
}

bool TestFiveGeometryWorkingSetOscillation() {
    const std::string root = TempRoot("cycle");
    CHECK(CreateDirectory(root));
    const std::string input = root + "/input.png";
    CHECK(CreatePhoto(input));

    const std::string controlPath = root + "/control.plist";
    const std::string media = root + "/Media";
    const std::string notification =
        "com.vcampro.geomws.prefx.cycle." +
        std::to_string(getpid());

    ProductControlOwner owner(
        controlPath,
        notification,
        media);
    MediaserverdRuntime runtime(
        controlPath,
        notification);
    CHECK(runtime.start());

    const OSType full =
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    const OSType video =
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;

    GeometryFixture geometries[] = {
        {MakeBuffer(64, 48, full), 64, 48, full},
        {MakeBuffer(80, 60, full), 80, 60, full},
        {MakeBuffer(64, 48, video), 64, 48, video},
        {MakeBuffer(80, 60, video), 80, 60, video},
        {MakeBuffer(96, 72, full), 96, 72, full},
    };
    for (const auto& geometry : geometries) {
        CHECK(geometry.buffer != nullptr);
    }

    runtime.observeRealCameraBuffer(
        geometries[0].buffer);
    CHECK(runtime.drainControlQueueForTesting());
    CHECK(owner.setEnabled(true));

    std::string error;
    CHECK(owner.selectFromTemporaryPath(
        input,
        ProductMediaKind::Photo,
        &error));
    CHECK(error.empty());

    const ProductControlSnapshot selected =
        owner.snapshot();
    CHECK(selected.selectionGeneration != 0);
    CHECK(WaitForInitialPhoto(
        runtime,
        selected.selectionGeneration));
    CHECK(IsPrepared(
        runtime.decideCameraBuffer(
            geometries[0].buffer)));

    std::uint64_t evictionCount = 0;

    for (std::size_t index = 1; index < 5; ++index) {
        CHECK(PrepareAndRetain(
            runtime,
            selected,
            geometries[index],
            &evictionCount));
    }

    CHECK(
        runtime.cameraAdapter().photoVariantCount() ==
        CameraConsumerAdapter::kPhotoVariantCapacity);
    CHECK(!HasVariant(
        runtime,
        selected,
        geometries[0].width,
        geometries[0].height,
        geometries[0].format));

    const auto firstPass =
        runtime.snapshotForTesting();
    const std::uint64_t preparationCountBeforeReturn =
        firstPass.photoVariantPreparationCount;

    CHECK(runtime.suspendControlQueueForTesting());
    runtime.observeRealCameraBuffer(
        geometries[0].buffer);
    const CameraDecision evictedA =
        runtime.decideCameraBuffer(
            geometries[0].buffer);
    CHECK(IsSafeBlack(evictedA));
    CHECK(runtime.resumeControlQueueForTesting());
    CHECK(runtime.drainControlQueueForTesting());
    CHECK(IsPrepared(
        runtime.decideCameraBuffer(
            geometries[0].buffer)));
    ++evictionCount;

    std::uint64_t recurringBlackCount = 1;
    for (std::size_t index = 1; index < 5; ++index) {
        CHECK(runtime.suspendControlQueueForTesting());
        runtime.observeRealCameraBuffer(
            geometries[index].buffer);
        const CameraDecision pending =
            runtime.decideCameraBuffer(
                geometries[index].buffer);
        CHECK(IsSafeBlack(pending));
        ++recurringBlackCount;
        CHECK(runtime.resumeControlQueueForTesting());
        CHECK(runtime.drainControlQueueForTesting());
        CHECK(IsPrepared(
            runtime.decideCameraBuffer(
                geometries[index].buffer)));
        ++evictionCount;
    }

    const auto finalSnapshot =
        runtime.snapshotForTesting();
    const std::uint64_t reprepareCount =
        finalSnapshot.photoVariantPreparationCount -
        preparationCountBeforeReturn;

    CHECK(reprepareCount > 0);
    CHECK(recurringBlackCount == 5);
    CHECK(finalSnapshot.logicalPhotoSessionCreationCount == 1);
    CHECK(finalSnapshot.totalPhotoDecodeCount == 1);
    CHECK(
        runtime.cameraAdapter().
            enabledSupportedOriginalDecisionCount() == 0);

    std::cout
        << "PRE_FIX_WORKING_SET_REPRODUCED=PASS\n"
        << "PRE_FIX_VARIANT_CAPACITY="
        << CameraConsumerAdapter::kPhotoVariantCapacity
        << "\n"
        << "PRE_FIX_UNIQUE_GEOMETRIES=5\n"
        << "PRE_FIX_RETURN_TO_EVICTED_GEOMETRY_BLACK=YES\n"
        << "PRE_FIX_REPREPARATION_COUNT="
        << reprepareCount << "\n"
        << "PRE_FIX_VARIANT_EVICTION_COUNT="
        << evictionCount << "\n"
        << "PRE_FIX_PHOTO_TO_BLACK_OSCILLATION_REPRODUCED=PASS\n"
        << "PRE_FIX_PHOTO_LOGICAL_SESSION_CREATION_COUNT="
        << finalSnapshot.logicalPhotoSessionCreationCount
        << "\n"
        << "PRE_FIX_PHOTO_SOURCE_DECODE_COUNT="
        << finalSnapshot.totalPhotoDecodeCount
        << "\n"
        << "PRE_FIX_ORIGINAL_DECISION_COUNT="
        << runtime.cameraAdapter().
            enabledSupportedOriginalDecisionCount()
        << "\n";

    for (auto& geometry : geometries) {
        CVPixelBufferRelease(
            geometry.buffer);
        geometry.buffer = nullptr;
    }

    [[NSFileManager defaultManager]
        removeItemAtPath:
            [NSString stringWithUTF8String:root.c_str()]
        error:nil];

    return true;
}

bool TestRapidGeometryIdentity() {
    const std::string root = TempRoot("lag");
    CHECK(CreateDirectory(root));
    const std::string input = root + "/input.png";
    CHECK(CreatePhoto(input));

    const std::string controlPath = root + "/control.plist";
    const std::string media = root + "/Media";
    const std::string notification =
        "com.vcampro.geomws.prefx.lag." +
        std::to_string(getpid());

    ProductControlOwner owner(
        controlPath,
        notification,
        media);
    MediaserverdRuntime runtime(
        controlPath,
        notification);
    CHECK(runtime.start());

    const OSType full =
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    const OSType video =
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;

    CVPixelBufferRef seed = MakeBuffer(48, 36, full);
    GeometryFixture geometries[] = {
        {MakeBuffer(64, 48, full), 64, 48, full},
        {MakeBuffer(80, 60, full), 80, 60, full},
        {MakeBuffer(64, 48, video), 64, 48, video},
        {MakeBuffer(80, 60, video), 80, 60, video},
        {MakeBuffer(96, 72, full), 96, 72, full},
    };
    CHECK(seed != nullptr);
    for (const auto& geometry : geometries) {
        CHECK(geometry.buffer != nullptr);
    }

    runtime.observeRealCameraBuffer(seed);
    CHECK(runtime.drainControlQueueForTesting());
    CHECK(owner.setEnabled(true));

    std::string error;
    CHECK(owner.selectFromTemporaryPath(
        input,
        ProductMediaKind::Photo,
        &error));
    CHECK(error.empty());
    const ProductControlSnapshot selected =
        owner.snapshot();
    CHECK(WaitForInitialPhoto(
        runtime,
        selected.selectionGeneration));

    const auto before =
        runtime.snapshotForTesting();
    CHECK(before.appliedGeometryHistoryCount + 5 <=
          before.appliedGeometryHistory.size());

    CHECK(runtime.suspendControlQueueForTesting());
    for (const auto& geometry : geometries) {
        runtime.observeRealCameraBuffer(
            geometry.buffer);
    }
    CHECK(runtime.resumeControlQueueForTesting());
    CHECK(runtime.drainControlQueueForTesting());

    const auto after =
        runtime.snapshotForTesting();
    CHECK(
        after.appliedGeometryHistoryCount >=
        before.appliedGeometryHistoryCount + 5);

    for (std::size_t index = 0; index < 5; ++index) {
        CHECK(
            after.appliedGeometryHistory[
                before.appliedGeometryHistoryCount + index] ==
            GeometryKey(
                geometries[index].width,
                geometries[index].height,
                geometries[index].format));
    }

    std::cout
        << "PRE_FIX_RAPID_GEOMETRY_INTERLEAVING=PASS\n"
        << "PRE_FIX_NO_GEOMETRY_EVENT_ALIASING=PASS\n";

    CVPixelBufferRelease(seed);
    for (auto& geometry : geometries) {
        CVPixelBufferRelease(
            geometry.buffer);
        geometry.buffer = nullptr;
    }

    [[NSFileManager defaultManager]
        removeItemAtPath:
            [NSString stringWithUTF8String:root.c_str()]
        error:nil];

    return true;
}

}  // namespace

int main() {
    @autoreleasepool {
        if (!TestFiveGeometryWorkingSetOscillation()) {
            return EXIT_FAILURE;
        }
        if (!TestRapidGeometryIdentity()) {
            return EXIT_FAILURE;
        }
        return EXIT_SUCCESS;
    }
}
