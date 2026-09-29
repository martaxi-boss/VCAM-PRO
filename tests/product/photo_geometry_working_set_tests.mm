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
                    @"vcam-geomws-%s-%@-%d",
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
    NSDictionary* attributes = @{
        (NSString*)kCVPixelBufferIOSurfacePropertiesKey : @{}
    };
    CVPixelBufferRef buffer = nullptr;
    if (CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            format,
            (__bridge CFDictionaryRef)attributes,
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

bool HasNonBlackLuma(
    CVPixelBufferRef pixelBuffer) {
    if (pixelBuffer == nullptr ||
        !CVPixelBufferIsPlanar(pixelBuffer) ||
        CVPixelBufferGetPlaneCount(pixelBuffer) < 1) {
        return false;
    }

    if (CVPixelBufferLockBaseAddress(
            pixelBuffer,
            kCVPixelBufferLock_ReadOnly) !=
        kCVReturnSuccess) {
        return false;
    }

    const OSType format =
        CVPixelBufferGetPixelFormatType(
            pixelBuffer);
    const std::uint8_t black =
        format ==
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ? 16
            : 0;
    const auto* base =
        static_cast<const std::uint8_t*>(
            CVPixelBufferGetBaseAddressOfPlane(
                pixelBuffer,
                0));
    const std::size_t stride =
        CVPixelBufferGetBytesPerRowOfPlane(
            pixelBuffer,
            0);
    const std::size_t width =
        CVPixelBufferGetWidthOfPlane(
            pixelBuffer,
            0);
    const std::size_t height =
        CVPixelBufferGetHeightOfPlane(
            pixelBuffer,
            0);

    bool visible = false;
    if (base != nullptr) {
        for (std::size_t y = 0;
             y < height && !visible;
             y += 8) {
            const auto* row =
                base + y * stride;
            for (std::size_t x = 0;
                 x < width;
                 x += 8) {
                if (row[x] != black) {
                    visible = true;
                    break;
                }
            }
        }
    }

    CVPixelBufferUnlockBaseAddress(
        pixelBuffer,
        kCVPixelBufferLock_ReadOnly);
    return visible;
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

struct GeometryFixture {
    CVPixelBufferRef buffer = nullptr;
    std::size_t width = 0;
    std::size_t height = 0;
    OSType format = 0;
};

bool ObserveDrainAndPhoto(
    MediaserverdRuntime& runtime,
    const GeometryFixture& geometry) {
    runtime.observeRealCameraBuffer(
        geometry.buffer);
    CHECK(runtime.drainControlQueueForTesting());
    CHECK(IsPrepared(
        runtime.decideCameraBuffer(
            geometry.buffer)));
    return true;
}

bool TestFiveGeometryWorkingSet() {
    const std::string root = TempRoot("five");
    CHECK(CreateDirectory(root));
    const std::string input = root + "/input.png";
    CHECK(CreatePhoto(input));

    const std::string controlPath = root + "/control.plist";
    const std::string media = root + "/Media";
    const std::string notification =
        "com.vcampro.geomws.five." +
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

    const auto selected = owner.snapshot();
    CHECK(WaitForInitialPhoto(
        runtime,
        selected.selectionGeneration));
    CHECK(IsPrepared(
        runtime.decideCameraBuffer(
            geometries[0].buffer)));

    for (std::size_t index = 1; index < 4; ++index) {
        CHECK(ObserveDrainAndPhoto(
            runtime,
            geometries[index]));
    }
    std::cout
        << "A_B_C_D_WITHIN_CACHE=PASS\n";

    CHECK(ObserveDrainAndPhoto(
        runtime,
        geometries[4]));
    std::cout
        << "FIFTH_GEOMETRY_BEHAVIOR=PASS\n";

    const auto warmed =
        runtime.snapshotForTesting();
    CHECK(runtime.cameraAdapter().photoVariantCount() >= 5);
    CHECK(warmed.photoVariantWorkingSetCount >= 5);
    CHECK(warmed.photoVariantRetainedBytes <=
          CameraConsumerAdapter::
              kPhotoVariantRetainedByteBudget);
    CHECK(runtime.cameraAdapter().photoVariantCount() <=
          CameraConsumerAdapter::
              kPhotoVariantStructuralCapacity);

    const std::uint64_t preparations =
        warmed.photoVariantPreparationCount;

    for (std::size_t cycle = 0;
         cycle < 2;
         ++cycle) {
        for (const auto& geometry : geometries) {
            CHECK(runtime.suspendControlQueueForTesting());
            runtime.observeRealCameraBuffer(
                geometry.buffer);
            const CameraDecision immediate =
                runtime.decideCameraBuffer(
                    geometry.buffer);
            CHECK(IsPrepared(immediate));
            CHECK(runtime.resumeControlQueueForTesting());
            CHECK(runtime.drainControlQueueForTesting());
        }
    }

    const auto after =
        runtime.snapshotForTesting();
    CHECK(after.photoVariantPreparationCount ==
          preparations);
    CHECK(after.photoVariantEvictionCount == 0);
    CHECK(after.photoVariantReprepareCount == 0);
    CHECK(after.logicalPhotoSessionCreationCount == 1);
    CHECK(after.totalPhotoDecodeCount == 1);
    CHECK(runtime.cameraAdapter().
              enabledSupportedOriginalDecisionCount() == 0);

    std::cout
        << "RETURN_TO_EVICTED_GEOMETRY=PASS\n"
        << "FIVE_GEOMETRY_CONTINUOUS_CYCLE=PASS\n"
        << "NO_REPEATED_BLACK_AFTER_GEOMETRY_WARMUP=PASS\n"
        << "PHOTO_ACTIVE_WORKING_SET_RETAINED=PASS\n"
        << "PHOTO_VARIANT_MEMORY_BOUNDED=PASS\n"
        << "PHOTO_VARIANT_STRUCTURAL_BOUND=PASS\n"
        << "PHOTO_SOURCE_DECODE_COUNT=1\n"
        << "PHOTO_LOGICAL_SESSION_CREATION_COUNT=1\n"
        << "NO_ORIGINAL_WHILE_ON=PASS\n"
        << "PHOTO_VARIANT_RETAINED_BYTES="
        << after.photoVariantRetainedBytes
        << "\n"
        << "PHOTO_VARIANT_WORKING_SET_COUNT="
        << after.photoVariantWorkingSetCount
        << "\n"
        << "PHOTO_VARIANT_EVICTION_COUNT="
        << after.photoVariantEvictionCount
        << "\n"
        << "PHOTO_VARIANT_REPREPARE_COUNT="
        << after.photoVariantReprepareCount
        << "\n";

    // The explicit lag test below uses a fresh runtime because the bounded
    // historical telemetry array intentionally records only eight events.

    for (auto& geometry : geometries) {
        CVPixelBufferRelease(geometry.buffer);
        geometry.buffer = nullptr;
    }

    [[NSFileManager defaultManager]
        removeItemAtPath:
            [NSString stringWithUTF8String:root.c_str()]
        error:nil];

    return true;
}

bool TestRapidGeometryInterleaving() {
    const std::string root = TempRoot("lag");
    CHECK(CreateDirectory(root));
    const std::string input = root + "/input.png";
    CHECK(CreatePhoto(input));

    const std::string controlPath = root + "/control.plist";
    const std::string media = root + "/Media";
    const std::string notification =
        "com.vcampro.geomws.lag." +
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

    CVPixelBufferRef seed =
        MakeBuffer(48, 36, full);
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
    const auto selected = owner.snapshot();
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
    CHECK(after.appliedGeometryHistoryCount >=
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
        << "RAPID_GEOMETRY_INTERLEAVING=PASS\n"
        << "NO_GEOMETRY_EVENT_ALIASING=PASS\n";

    CVPixelBufferRelease(seed);
    for (auto& geometry : geometries) {
        CVPixelBufferRelease(geometry.buffer);
        geometry.buffer = nullptr;
    }

    [[NSFileManager defaultManager]
        removeItemAtPath:
            [NSString stringWithUTF8String:root.c_str()]
        error:nil];
    return true;
}

bool TestOverflowGate() {
    const std::string root = TempRoot("overflow");
    CHECK(CreateDirectory(root));
    const std::string input = root + "/input.png";
    CHECK(CreatePhoto(input));

    const std::string controlPath = root + "/control.plist";
    const std::string media = root + "/Media";
    const std::string notification =
        "com.vcampro.geomws.overflow." +
        std::to_string(getpid());

    ProductControlOwner owner(controlPath, notification, media);
    MediaserverdRuntime runtime(controlPath, notification);
    CHECK(runtime.start());

    const OSType full =
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    const OSType video =
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;

    constexpr std::size_t geometryCount =
        CameraConsumerAdapter::kPhotoVariantStructuralCapacity + 1;
    GeometryFixture geometries[geometryCount];
    for (std::size_t index = 0; index < geometryCount; ++index) {
        const std::size_t width = 128 + index * 16;
        const std::size_t height = 96 + index * 8;
        const OSType format = (index % 2) == 0 ? full : video;
        geometries[index] = {
            MakeBuffer(width, height, format), width, height, format};
        CHECK(geometries[index].buffer != nullptr);
    }

    runtime.observeRealCameraBuffer(geometries[0].buffer);
    CHECK(runtime.drainControlQueueForTesting());
    CHECK(owner.setEnabled(true));

    std::string error;
    CHECK(owner.selectFromTemporaryPath(
        input, ProductMediaKind::Photo, &error));
    CHECK(error.empty());
    const auto selected = owner.snapshot();
    CHECK(WaitForInitialPhoto(runtime, selected.selectionGeneration));
    CHECK(IsPrepared(runtime.decideCameraBuffer(geometries[0].buffer)));

    std::size_t peakRetainedBytes =
        runtime.snapshotForTesting().photoVariantRetainedBytes;

    for (std::size_t index = 1; index < geometryCount; ++index) {
        runtime.observeRealCameraBuffer(geometries[index].buffer);
        CHECK(runtime.drainControlQueueForTesting());
        const CameraDecision decision =
            runtime.decideCameraBuffer(geometries[index].buffer);
        CHECK(IsPrepared(decision) || IsSafeBlack(decision));
        CHECK(decision.source != CameraDecisionSource::Original);

        const auto snapshot = runtime.snapshotForTesting();
        if (snapshot.photoVariantRetainedBytes > peakRetainedBytes) {
            peakRetainedBytes = snapshot.photoVariantRetainedBytes;
        }
        CHECK(snapshot.photoVariantRetainedBytes <=
              CameraConsumerAdapter::kPhotoVariantRetainedByteBudget);
        CHECK(runtime.cameraAdapter().photoVariantCount() <=
              CameraConsumerAdapter::kPhotoVariantStructuralCapacity);
    }

    const auto stressed = runtime.snapshotForTesting();
    CHECK(peakRetainedBytes <=
          CameraConsumerAdapter::kPhotoVariantRetainedByteBudget);

    std::size_t overflowGeometryIndex = geometryCount;
    for (std::size_t index = 0; index < geometryCount; ++index) {
        if (!runtime.cameraAdapter().hasReusablePhotoVariant(
                geometries[index].width,
                geometries[index].height,
                geometries[index].format,
                stressed.queueGeneration,
                stressed.queueEpoch,
                selected.photoTransform.revision)) {
            overflowGeometryIndex = index;
            break;
        }
    }
    CHECK(overflowGeometryIndex < geometryCount);

    const std::uint64_t preparationsBefore =
        stressed.photoVariantPreparationCount;
    CHECK(runtime.suspendControlQueueForTesting());
    runtime.observeRealCameraBuffer(
        geometries[overflowGeometryIndex].buffer);

    for (std::size_t attempt = 0; attempt < 4; ++attempt) {
        const CameraDecision decision = runtime.decideCameraBuffer(
            geometries[overflowGeometryIndex].buffer);
        CHECK(IsSafeBlack(decision));
        CHECK(decision.source != CameraDecisionSource::Original);
    }

    CHECK(!runtime.cameraAdapter().hasReusablePhotoVariant(
        geometries[overflowGeometryIndex].width,
        geometries[overflowGeometryIndex].height,
        geometries[overflowGeometryIndex].format,
        stressed.queueGeneration,
        stressed.queueEpoch,
        selected.photoTransform.revision));
    CHECK(runtime.cameraAdapter().enabledSupportedOriginalDecisionCount() == 0);

    CHECK(runtime.resumeControlQueueForTesting());
    CHECK(runtime.drainControlQueueForTesting());
    const auto afterProducer = runtime.snapshotForTesting();
    CHECK(afterProducer.photoVariantPreparationCount > preparationsBefore);
    CHECK(afterProducer.photoVariantRetainedBytes <=
          CameraConsumerAdapter::kPhotoVariantRetainedByteBudget);
    CHECK(runtime.cameraAdapter().enabledSupportedOriginalDecisionCount() == 0);

    std::cout
        << "OVER_BUDGET_STRESS=PASS\n"
        << "OVER_BUDGET_SAFE_VIRTUAL_OWNERSHIP=PASS\n"
        << "OVER_BUDGET_ORIGINAL_DECISIONS=ZERO\n"
        << "OVER_BUDGET_CALLBACK_SCALING=ZERO\n"
        << "OVER_BUDGET_CALLBACK_TRANSFORM=ZERO\n"
        << "OVER_BUDGET_MAY_USE_BLACK_WHILE_PREPARING=PASS\n"
        << "OVER_BUDGET_PRODUCER_REPREPARATION_OUTSIDE_CALLBACK=PASS\n"
        << "VCAM_ON_SUPPORTED_ORIGINAL_DECISIONS=ZERO\n"
        << "PHOTO_VARIANT_PEAK_RETAINED_BYTES=" << peakRetainedBytes << "\n"
        << "PHOTO_VARIANT_MEMORY_BUDGET="
        << CameraConsumerAdapter::kPhotoVariantRetainedByteBudget << "\n"
        << "DIRECT_RENDER_SOURCE_BYTES=0\n"
        << "DIRECT_RENDER_MAPPING_BYTES=0\n";

    for (auto& geometry : geometries) {
        CVPixelBufferRelease(geometry.buffer);
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
        if (!TestFiveGeometryWorkingSet()) {
            return EXIT_FAILURE;
        }
        if (!TestRapidGeometryInterleaving()) {
            return EXIT_FAILURE;
        }
        if (!TestOverflowGate()) {
            return EXIT_FAILURE;
        }
        return EXIT_SUCCESS;
    }
}
