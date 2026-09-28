#include "MediaserverdRuntime.h"
#include "ProductControlOwner.h"

#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

#include <CoreGraphics/CoreGraphics.h>
#include <CoreVideo/CoreVideo.h>

#include <chrono>
#include <cstdint>
#include <cstring>
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
                    @"vcam-prefx-multigeom-%@-%d",
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
                static_cast<std::uint8_t>(30 + (x * 190 / width));
            bytes[offset + 1] =
                static_cast<std::uint8_t>(220 - (y * 170 / height));
            bytes[offset + 2] =
                static_cast<std::uint8_t>((x + y) % 255);
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
    OSType format =
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
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
    OSType pixelFormat) {
    return
        static_cast<std::uint64_t>(width) |
        (static_cast<std::uint64_t>(height) << 16U) |
        (static_cast<std::uint64_t>(pixelFormat) << 32U);
}

bool WaitForPhotoReady(
    MediaserverdRuntime& runtime,
    std::uint64_t generation,
    std::uint64_t minimumSessionCount,
    MediaserverdRuntimeTestSnapshot* out = nullptr) {
    for (int attempt = 0; attempt < 2500; ++attempt) {
        if (!runtime.drainControlQueueForTesting()) {
            return false;
        }

        const auto snapshot = runtime.snapshotForTesting();
        if (snapshot.selectionGeneration == generation &&
            snapshot.sessionExists &&
            snapshot.producerHealthy &&
            snapshot.readyQueueSize > 0 &&
            snapshot.logicalPhotoSessionCreationCount >=
                minimumSessionCount) {
            if (out != nullptr) {
                *out = snapshot;
            }
            return true;
        }

        std::this_thread::sleep_for(
            std::chrono::milliseconds(2));
    }
    return false;
}

bool ExpectPhoto(
    MediaserverdRuntime& runtime,
    CVPixelBufferRef geometry) {
    const CameraDecision decision =
        runtime.decideCameraBuffer(geometry);
    return
        decision.kind == CameraDecisionKind::Virtual &&
        decision.source == CameraDecisionSource::PreparedMedia &&
        decision.pixelBuffer != nullptr;
}

bool TestPreFixMultiGeometrySessionChurn() {
    const std::string root = TempRoot();
    CHECK(CreateDirectory(root));
    const std::string input = root + "/input.png";
    CHECK(CreatePhoto(input));

    const std::string control = root + "/control.plist";
    const std::string media = root + "/Media";
    const std::string notification =
        "com.vcampro.prefx.multigeom." +
        std::to_string(getpid());

    ProductControlOwner owner(control, notification, media);
    MediaserverdRuntime runtime(control, notification);
    CHECK(runtime.start());

    CVPixelBufferRef a = MakeBuffer(64, 48);
    CVPixelBufferRef b = MakeBuffer(80, 60);
    CHECK(a != nullptr);
    CHECK(b != nullptr);

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

    MediaserverdRuntimeTestSnapshot initial;
    CHECK(WaitForPhotoReady(
        runtime,
        selected.selectionGeneration,
        1,
        &initial));
    CHECK(initial.logicalPhotoSessionCreationCount == 1);
    CHECK(initial.totalPhotoDecodeCount == 1);
    CHECK(ExpectPhoto(runtime, a));

    runtime.observeRealCameraBuffer(b);
    MediaserverdRuntimeTestSnapshot afterB;
    CHECK(WaitForPhotoReady(
        runtime,
        selected.selectionGeneration,
        2,
        &afterB));
    CHECK(ExpectPhoto(runtime, b));

    runtime.observeRealCameraBuffer(a);
    MediaserverdRuntimeTestSnapshot afterA2;
    CHECK(WaitForPhotoReady(
        runtime,
        selected.selectionGeneration,
        3,
        &afterA2));
    CHECK(ExpectPhoto(runtime, a));

    runtime.observeRealCameraBuffer(b);
    MediaserverdRuntimeTestSnapshot afterB2;
    CHECK(WaitForPhotoReady(
        runtime,
        selected.selectionGeneration,
        4,
        &afterB2));
    CHECK(ExpectPhoto(runtime, b));

    CHECK(afterB2.logicalPhotoSessionCreationCount >= 4);
    CHECK(afterB2.totalPhotoDecodeCount >= 4);

    const std::size_t historyBefore =
        afterB2.appliedGeometryHistoryCount;
    CHECK(historyBefore + 2 <=
          afterB2.appliedGeometryHistory.size());

    CHECK(runtime.suspendControlQueueForTesting());
    runtime.observeRealCameraBuffer(a);
    runtime.observeRealCameraBuffer(b);
    CHECK(runtime.resumeControlQueueForTesting());
    CHECK(runtime.drainControlQueueForTesting());

    const auto aliased = runtime.snapshotForTesting();
    CHECK(aliased.appliedGeometryHistoryCount >= historyBefore + 2);

    const std::uint64_t keyB =
        GeometryKey(
            80,
            60,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);

    const std::size_t last =
        aliased.appliedGeometryHistoryCount;
    CHECK(aliased.appliedGeometryHistory[last - 2] == keyB);
    CHECK(aliased.appliedGeometryHistory[last - 1] == keyB);

    std::cout
        << "PRE_FIX_MULTI_GEOMETRY_REPRODUCED=PASS\n"
        << "PRE_FIX_SESSION_CHURN_REPRODUCED=PASS\n"
        << "PRE_FIX_REDECODE_REPRODUCED=PASS\n"
        << "PRE_FIX_GLOBAL_GEOMETRY_ALIASING_REPRODUCED=PASS\n"
        << "PRE_FIX_LOGICAL_SESSION_CREATION_COUNT="
        << aliased.logicalPhotoSessionCreationCount
        << "\n"
        << "PRE_FIX_TOTAL_PHOTO_DECODE_COUNT="
        << aliased.totalPhotoDecodeCount
        << "\n"
        << "PRODUCT_COMPOSITION_TEST_DIRECT_ADAPTER_BIND=NO\n"
        << "PRODUCT_COMPOSITION_TEST_DIRECT_SESSION_CONSTRUCTION=NO\n";

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
        return TestPreFixMultiGeometrySessionChurn()
            ? EXIT_SUCCESS
            : EXIT_FAILURE;
    }
}
