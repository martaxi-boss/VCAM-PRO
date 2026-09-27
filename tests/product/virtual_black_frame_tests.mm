#include "VirtualBlackFrame.h"

#include <CoreVideo/CoreVideo.h>

#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <functional>
#include <iostream>

namespace {

using vcam::product::VirtualBlackFrame;

int gTests = 0;
int gFailures = 0;

#define CHECK(condition) do { if (!(condition)) {     std::cerr << "CHECK failed at " << __FILE__ << ":" << __LINE__               << ": " #condition << std::endl; return false; } } while (false)

bool PlaneBytesEqual(
    CVPixelBufferRef buffer,
    std::size_t plane,
    std::uint8_t expected) {
    if (buffer == nullptr ||
        plane >= CVPixelBufferGetPlaneCount(buffer)) {
        return false;
    }

    const auto* base =
        static_cast<const std::uint8_t*>(
            CVPixelBufferGetBaseAddressOfPlane(
                buffer,
                plane));
    const std::size_t bytesPerRow =
        CVPixelBufferGetBytesPerRowOfPlane(
            buffer,
            plane);
    const std::size_t height =
        CVPixelBufferGetHeightOfPlane(
            buffer,
            plane);

    if (base == nullptr ||
        bytesPerRow == 0 ||
        height == 0) {
        return false;
    }

    for (std::size_t row = 0;
         row < height;
         ++row) {
        const auto* rowBytes =
            base + row * bytesPerRow;

        for (std::size_t column = 0;
             column < bytesPerRow;
             ++column) {
            if (rowBytes[column] !=
                expected) {
                return false;
            }
        }
    }

    return true;
}

bool CheckBlackContent(
    OSType format,
    std::uint8_t expectedY) {
    VirtualBlackFrame black;

    CVPixelBufferRef buffer =
        black.prepare(
            64,
            48,
            format);

    CHECK(buffer != nullptr);
    CHECK(CVPixelBufferGetWidth(buffer) == 64);
    CHECK(CVPixelBufferGetHeight(buffer) == 48);
    CHECK(CVPixelBufferGetPixelFormatType(buffer) ==
          format);
    CHECK(CVPixelBufferIsPlanar(buffer));
    CHECK(CVPixelBufferGetPlaneCount(buffer) == 2);

    CHECK(CVPixelBufferLockBaseAddress(
              buffer,
              kCVPixelBufferLock_ReadOnly) ==
          kCVReturnSuccess);

    const bool yCorrect =
        PlaneBytesEqual(
            buffer,
            0,
            expectedY);
    const bool cbcrCorrect =
        PlaneBytesEqual(
            buffer,
            1,
            128);

    CVPixelBufferUnlockBaseAddress(
        buffer,
        kCVPixelBufferLock_ReadOnly);

    CHECK(yCorrect);
    CHECK(cbcrCorrect);

    return true;
}

bool Test420vContent() {
    return CheckBlackContent(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        16);
}

bool Test420fContent() {
    return CheckBlackContent(
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        0);
}

bool TestSameGeometryReusesBuffer() {
    VirtualBlackFrame black;

    CVPixelBufferRef first =
        black.prepare(
            64,
            48,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
    CVPixelBufferRef second =
        black.prepare(
            64,
            48,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);

    CHECK(first != nullptr);
    CHECK(second == first);
    CHECK(black.cacheSize() == 1);

    return true;
}

bool TestGeometryCacheBounded() {
    VirtualBlackFrame black;

    const std::size_t widths[] = {
        64,
        66,
        68,
        70,
    };
    const std::size_t heights[] = {
        48,
        50,
        52,
        54,
    };

    for (std::size_t index = 0;
         index < VirtualBlackFrame::kCacheCapacity;
         ++index) {
        CHECK(black.prepare(
                  widths[index],
                  heights[index],
                  kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) !=
              nullptr);
    }

    CHECK(black.cacheSize() ==
          VirtualBlackFrame::kCacheCapacity);

    CHECK(black.prepare(
              72,
              56,
              kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) ==
          nullptr);

    CHECK(black.cacheSize() ==
          VirtualBlackFrame::kCacheCapacity);

    return true;
}

bool TestUnsupportedFormatRejected() {
    VirtualBlackFrame black;

    CHECK(black.prepare(
              64,
              48,
              kCVPixelFormatType_32BGRA) ==
          nullptr);
    CHECK(black.cacheSize() == 0);

    return true;
}

void Run(
    const char* name,
    const std::function<bool()>& test) {
    ++gTests;

    if (!test()) {
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
    Run(
        "420v black content",
        Test420vContent);
    Run(
        "420f black content",
        Test420fContent);
    Run(
        "same geometry reuses fallback",
        TestSameGeometryReusesBuffer);
    Run(
        "geometry cache remains bounded",
        TestGeometryCacheBounded);
    Run(
        "unsupported format rejected",
        TestUnsupportedFormatRejected);

    std::cout
        << "Virtual black frame tests run: "
        << gTests
        << ", failures: "
        << gFailures
        << std::endl;

    return gFailures == 0
        ? EXIT_SUCCESS
        : EXIT_FAILURE;
}
