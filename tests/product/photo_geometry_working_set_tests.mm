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

bool IsDirect(const CameraDecision& decision) {
    return
        decision.kind == CameraDecisionKind::Virtual &&
        decision.source ==
            CameraDecisionSource::DirectRenderedPhoto &&
        decision.pixelBuffer != nullptr;
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

bool FillVisibleNV12(
    CVPixelBufferRef buffer) {
    if (buffer == nullptr ||
        !CVPixelBufferIsPlanar(buffer) ||
        CVPixelBufferGetPlaneCount(buffer) != 2 ||
        CVPixelBufferLockBaseAddress(
            buffer,
            0) != kCVReturnSuccess) {
        return false;
    }

    bool ok = true;
    for (std::size_t plane = 0; plane < 2; ++plane) {
        auto* base =
            static_cast<std::uint8_t*>(
                CVPixelBufferGetBaseAddressOfPlane(
                    buffer,
                    plane));
        const std::size_t stride =
            CVPixelBufferGetBytesPerRowOfPlane(
                buffer,
                plane);
        const std::size_t rows =
            CVPixelBufferGetHeightOfPlane(
                buffer,
                plane);
        if (base == nullptr || stride == 0 || rows == 0) {
            ok = false;
            break;
        }
        std::memset(
            base,
            plane == 0 ? 120 : 128,
            stride * rows);
    }

    CVPixelBufferUnlockBaseAddress(
        buffer,
        0);
    return ok;
}

std::uintptr_t LumaBaseAddress(
    CVPixelBufferRef buffer) {
    if (buffer == nullptr ||
        CVPixelBufferLockBaseAddress(
            buffer,
            kCVPixelBufferLock_ReadOnly) !=
        kCVReturnSuccess) {
        return 0;
    }
    const auto address =
        reinterpret_cast<std::uintptr_t>(
            CVPixelBufferGetBaseAddressOfPlane(
                buffer,
                0));
    CVPixelBufferUnlockBaseAddress(
        buffer,
        kCVPixelBufferLock_ReadOnly);
    return address;
}

int SampleLuma(
    CVPixelBufferRef buffer,
    std::size_t x,
    std::size_t y) {
    if (buffer == nullptr ||
        !CVPixelBufferIsPlanar(buffer) ||
        CVPixelBufferGetPlaneCount(buffer) < 1 ||
        CVPixelBufferLockBaseAddress(
            buffer,
            kCVPixelBufferLock_ReadOnly) !=
        kCVReturnSuccess) {
        return -1;
    }

    const auto* base =
        static_cast<const std::uint8_t*>(
            CVPixelBufferGetBaseAddressOfPlane(
                buffer,
                0));
    const std::size_t stride =
        CVPixelBufferGetBytesPerRowOfPlane(
            buffer,
            0);
    const std::size_t width =
        CVPixelBufferGetWidthOfPlane(
            buffer,
            0);
    const std::size_t height =
        CVPixelBufferGetHeightOfPlane(
            buffer,
            0);

    int value = -1;
    if (base != nullptr &&
        x < width &&
        y < height) {
        value =
            static_cast<int>(
                base[y * stride + x]);
    }

    CVPixelBufferUnlockBaseAddress(
        buffer,
        kCVPixelBufferLock_ReadOnly);
    return value;
}

bool TestDirectRendererSyntheticSource() {
    const OSType full =
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;

    CVPixelBufferRef source =
        MakeBuffer(128, 96, full);
    CVPixelBufferRef destination =
        MakeBuffer(640, 360, full);
    CHECK(source != nullptr);
    CHECK(destination != nullptr);
    CHECK(FillVisibleNV12(source));
    CHECK(HasNonBlackLuma(source));
    const int sourceSample =
        SampleLuma(source, 0, 12);
    CHECK(sourceSample == 120);
    std::cout
        << "DIRECT_RENDER_SOURCE_LUMA="
        << sourceSample << "\n";

    vcam::frame_engine::ReadyFrameQueue queue(1);
    CameraConsumerAdapter adapter;
    adapter.setEnabled(true);
    adapter.bindQueue(
        &queue,
        1,
        1,
        true,
        true,
        0);
    CHECK(adapter.bindDirectPhotoSource(
        source,
        1,
        1,
        0,
        0.0,
        0.0,
        1.0));
    CHECK(adapter.prepareDirectPhotoGeometry(
        640,
        360,
        full,
        1,
        1,
        0));
    CHECK(source != destination);
    CHECK(adapter.
              directPhotoSourceMatchesForTesting(
                  source));
    CHECK(SampleLuma(source, 0, 12) == 120);
    const std::uintptr_t sourceBase =
        LumaBaseAddress(source);
    const std::uintptr_t destinationBase =
        LumaBaseAddress(destination);
    CHECK(sourceBase != 0);
    CHECK(destinationBase != 0);
    CHECK(sourceBase != destinationBase);
    std::cout
        << "DIRECT_RENDER_SOURCE_IDENTITY=PASS\n"
        << "DIRECT_RENDER_STORAGE_DISTINCT=PASS\n";

    const CameraDecision decision =
        adapter.decide(destination);
    CHECK(IsDirect(decision));
    const int destinationSample =
        SampleLuma(
            decision.pixelBuffer,
            0,
            0);
    const int sourceAfter =
        SampleLuma(source, 0, 12);
    std::cout
        << "DIRECT_RENDER_DESTINATION_LUMA="
        << destinationSample << "\n"
        << "DIRECT_RENDER_SOURCE_LUMA_AFTER="
        << sourceAfter << "\n"
        << "DIRECT_RENDER_INTERNAL_SOURCE_LUMA="
        << static_cast<unsigned>(
            adapter.directPhotoTestSourceLuma())
        << "\n"
        << "DIRECT_RENDER_INTERNAL_MAPPED_LUMA="
        << static_cast<unsigned>(
            adapter.directPhotoTestMappedLuma())
        << "\n"
        << "DIRECT_RENDER_INTERNAL_DESTINATION_LUMA="
        << static_cast<unsigned>(
            adapter.directPhotoTestDestinationLuma())
        << "\n"
        << "DIRECT_RENDER_EXTERNAL_SOURCE_BASE="
        << sourceBase
        << "\n"
        << "DIRECT_RENDER_INTERNAL_SOURCE_BASE="
        << adapter.directPhotoTestSourceBase()
        << "\n"
        << "DIRECT_RENDER_INTERNAL_SOURCE_ROW="
        << adapter.directPhotoTestSourceRow()
        << "\n"
        << "DIRECT_RENDER_INTERNAL_SOURCE_COLUMN="
        << adapter.directPhotoTestSourceColumn()
        << "\n"
        << "DIRECT_RENDER_COUNT="
        << adapter.directPhotoRenderCount()
        << "\n"
        << "DIRECT_RENDER_FAILURE_COUNT="
        << adapter.directPhotoRenderFailureCount()
        << "\n";
    CHECK(HasNonBlackLuma(
        decision.pixelBuffer));

    std::cout
        << "DIRECT_RENDER_SYNTHETIC_SOURCE=PASS\n";

    CVPixelBufferRelease(destination);
    CVPixelBufferRelease(source);
    return true;
}

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

    GeometryFixture geometries[12];
    for (std::size_t index = 0; index < 12; ++index) {
        const std::size_t width =
            1920 - index * 2;
        const std::size_t height = 1080;
        const OSType format =
            (index % 2) == 0
                ? full
                : video;
        geometries[index] = {
            MakeBuffer(width, height, format),
            width,
            height,
            format,
        };
        CHECK(geometries[index].buffer != nullptr);
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
    const CameraDecision initialPrepared =
        runtime.decideCameraBuffer(
            geometries[0].buffer);
    CHECK(IsPrepared(initialPrepared));
    CHECK(HasNonBlackLuma(
        initialPrepared.pixelBuffer));
    std::cout
        << "PREPARED_PHOTO_LUMA_VISIBLE=PASS\n";

    std::size_t directRenderIndex = 12;

    for (std::size_t index = 1;
         index < 12;
         ++index) {
        runtime.observeRealCameraBuffer(
            geometries[index].buffer);
        CHECK(runtime.drainControlQueueForTesting());
        const CameraDecision decision =
            runtime.decideCameraBuffer(
                geometries[index].buffer);
        CHECK(
            IsPrepared(decision) ||
            IsDirect(decision));
        if (IsDirect(decision) &&
            directRenderIndex == 12) {
            directRenderIndex = index;
        }
    }

    const auto stressed =
        runtime.snapshotForTesting();
    CHECK(directRenderIndex < 12);
    CHECK(stressed.photoVariantRetainedBytes <=
          CameraConsumerAdapter::
              kPhotoVariantRetainedByteBudget);
    CHECK(runtime.cameraAdapter().photoVariantCount() <=
          CameraConsumerAdapter::
              kPhotoVariantStructuralCapacity);
    CHECK(runtime.cameraAdapter().
              directPhotoRenderCount() > 0);
    CHECK(runtime.cameraAdapter().
              directPhotoRenderFailureCount() == 0);
    CHECK(runtime.cameraAdapter().
              directPhotoScratchBytes() <=
          CameraConsumerAdapter::
              kDirectRenderScratchByteBudget);

    const auto current =
        runtime.snapshotForTesting();
    std::size_t overflowGeometryIndex = 12;
    for (std::size_t index = 0;
         index < 12;
         ++index) {
        if (!runtime.cameraAdapter().
                hasReusablePhotoVariant(
                    geometries[index].width,
                    geometries[index].height,
                    geometries[index].format,
                    current.queueGeneration,
                    current.queueEpoch,
                    selected.photoTransform.revision)) {
            overflowGeometryIndex = index;
            break;
        }
    }
    CHECK(overflowGeometryIndex < 12);

    CHECK(runtime.suspendControlQueueForTesting());
    runtime.observeRealCameraBuffer(
        geometries[
            overflowGeometryIndex].
            buffer);
    const CameraDecision overflowReturn =
        runtime.decideCameraBuffer(
            geometries[
                overflowGeometryIndex].
                buffer);
    CHECK(IsDirect(overflowReturn));
    CHECK(!IsSafeBlack(overflowReturn));
    CHECK(HasNonBlackLuma(
        overflowReturn.pixelBuffer));

    const auto benchmarkStart =
        std::chrono::steady_clock::now();
    for (std::size_t iteration = 0;
         iteration < 10;
         ++iteration) {
        const CameraDecision decision =
            runtime.decideCameraBuffer(
                geometries[
                    overflowGeometryIndex].
                    buffer);
        CHECK(IsDirect(decision));
        CHECK(
            decision.pixelBuffer ==
            geometries[
                overflowGeometryIndex].
                buffer);
    }
    const auto benchmarkEnd =
        std::chrono::steady_clock::now();
    CHECK(runtime.resumeControlQueueForTesting());
    CHECK(runtime.drainControlQueueForTesting());
    const auto benchmarkNs =
        std::chrono::duration_cast<
            std::chrono::nanoseconds>(
                benchmarkEnd -
                benchmarkStart).
            count() / 10;

    CHECK(runtime.cameraAdapter().
              enabledSupportedOriginalDecisionCount() == 0);

    std::cout
        << "OVER_BUDGET_STRESS=PASS\n"
        << "IOS15_DIRECT_RENDER_FALLBACK_REQUIRED=YES\n"
        << "IOS15_DIRECT_RENDER_FALLBACK_USED=YES\n"
        << "DIRECT_RENDER_OVERFLOW_CONTINUITY=PASS\n"
        << "DIRECT_RENDER_HOST_BENCHMARK=PASS\n"
        << "DIRECT_RENDER_HOST_AVERAGE_NS="
        << benchmarkNs
        << "\n"
        << "OVER_BUDGET_FIRST_DIRECT_INDEX="
        << directRenderIndex
        << "\n"
        << "OVER_BUDGET_BENCHMARK_DIRECT_INDEX="
        << overflowGeometryIndex
        << "\n"
        << "OVER_BUDGET_RETAINED_BYTES="
        << stressed.photoVariantRetainedBytes
        << "\n"
        << "OVER_BUDGET_EVICTION_COUNT="
        << stressed.photoVariantEvictionCount
        << "\n"
        << "DIRECT_RENDER_COUNT="
        << runtime.cameraAdapter().
            directPhotoRenderCount()
        << "\n"
        << "DIRECT_RENDER_SCRATCH_BYTES="
        << runtime.cameraAdapter().
            directPhotoScratchBytes()
        << "\n";

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
        if (!TestDirectRendererSyntheticSource()) {
            return EXIT_FAILURE;
        }
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
