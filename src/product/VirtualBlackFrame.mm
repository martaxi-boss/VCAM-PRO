#include "VirtualBlackFrame.h"

#include <CoreFoundation/CoreFoundation.h>

#include <cstdint>
#include <cstring>
#include <limits>

namespace vcam::product {

namespace {

CFNumberRef CreateSizeNumber(
    std::size_t value) {
    if (value >
        static_cast<std::size_t>(
            std::numeric_limits<std::int64_t>::max())) {
        return nullptr;
    }

    const std::int64_t signedValue =
        static_cast<std::int64_t>(value);

    return CFNumberCreate(
        kCFAllocatorDefault,
        kCFNumberSInt64Type,
        &signedValue);
}

CFNumberRef CreateFormatNumber(
    OSType value) {
    const std::int64_t signedValue =
        static_cast<std::int64_t>(value);

    return CFNumberCreate(
        kCFAllocatorDefault,
        kCFNumberSInt64Type,
        &signedValue);
}

bool FillBlack(
    CVPixelBufferRef pixelBuffer,
    OSType pixelFormat) {
    if (pixelBuffer == nullptr ||
        !CVPixelBufferIsPlanar(pixelBuffer) ||
        CVPixelBufferGetPlaneCount(
            pixelBuffer) != 2) {
        return false;
    }

    if (CVPixelBufferLockBaseAddress(
            pixelBuffer,
            0) != kCVReturnSuccess) {
        return false;
    }

    bool success = false;

    do {
        void* yBase =
            CVPixelBufferGetBaseAddressOfPlane(
                pixelBuffer,
                0);
        void* cbcrBase =
            CVPixelBufferGetBaseAddressOfPlane(
                pixelBuffer,
                1);

        const std::size_t yBytesPerRow =
            CVPixelBufferGetBytesPerRowOfPlane(
                pixelBuffer,
                0);
        const std::size_t cbcrBytesPerRow =
            CVPixelBufferGetBytesPerRowOfPlane(
                pixelBuffer,
                1);
        const std::size_t yHeight =
            CVPixelBufferGetHeightOfPlane(
                pixelBuffer,
                0);
        const std::size_t cbcrHeight =
            CVPixelBufferGetHeightOfPlane(
                pixelBuffer,
                1);

        if (yBase == nullptr ||
            cbcrBase == nullptr ||
            yBytesPerRow == 0 ||
            cbcrBytesPerRow == 0 ||
            yHeight == 0 ||
            cbcrHeight == 0) {
            break;
        }

        const int yValue =
            pixelFormat ==
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                ? 16
                : 0;

        auto* y =
            static_cast<std::uint8_t*>(
                yBase);
        auto* cbcr =
            static_cast<std::uint8_t*>(
                cbcrBase);

        for (std::size_t row = 0;
             row < yHeight;
             ++row) {
            std::memset(
                y + row * yBytesPerRow,
                yValue,
                yBytesPerRow);
        }

        for (std::size_t row = 0;
             row < cbcrHeight;
             ++row) {
            std::memset(
                cbcr + row * cbcrBytesPerRow,
                128,
                cbcrBytesPerRow);
        }

        success = true;
    } while (false);

    CVPixelBufferUnlockBaseAddress(
        pixelBuffer,
        0);

    return success;
}

}  // namespace

VirtualBlackFrame::~VirtualBlackFrame() {
    std::lock_guard<std::mutex> lock(
        mutex_);

    for (std::size_t index = 0;
         index < count_;
         ++index) {
        if (entries_[index].pixelBuffer !=
            nullptr) {
            CVPixelBufferRelease(
                entries_[index].pixelBuffer);
            entries_[index].pixelBuffer =
                nullptr;
        }
    }
}

bool VirtualBlackFrame::
isSupportedPixelFormat(
    OSType pixelFormat) noexcept {
    return
        pixelFormat ==
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        pixelFormat ==
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
}

CVPixelBufferRef
VirtualBlackFrame::prepare(
    std::size_t width,
    std::size_t height,
    OSType pixelFormat) {
    if (width == 0 ||
        height == 0 ||
        !isSupportedPixelFormat(
            pixelFormat)) {
        return nullptr;
    }

    std::lock_guard<std::mutex> lock(
        mutex_);

    for (std::size_t index = 0;
         index < count_;
         ++index) {
        const Entry& entry =
            entries_[index];

        if (entry.width == width &&
            entry.height == height &&
            entry.pixelFormat ==
                pixelFormat) {
            return entry.pixelBuffer;
        }
    }

    if (count_ >= kCacheCapacity) {
        return nullptr;
    }

    CVPixelBufferRef pixelBuffer =
        createBlackBuffer(
            width,
            height,
            pixelFormat);

    if (pixelBuffer == nullptr) {
        return nullptr;
    }

    Entry& entry =
        entries_[count_++];
    entry.width = width;
    entry.height = height;
    entry.pixelFormat = pixelFormat;
    entry.pixelBuffer = pixelBuffer;

    return entry.pixelBuffer;
}

std::size_t
VirtualBlackFrame::cacheSize() const {
    std::lock_guard<std::mutex> lock(
        mutex_);
    return count_;
}

CVPixelBufferRef
VirtualBlackFrame::createBlackBuffer(
    std::size_t width,
    std::size_t height,
    OSType pixelFormat) {
    CFMutableDictionaryRef
        pixelAttributes =
            CFDictionaryCreateMutable(
                kCFAllocatorDefault,
                0,
                &kCFTypeDictionaryKeyCallBacks,
                &kCFTypeDictionaryValueCallBacks);
    CFMutableDictionaryRef
        ioSurfaceProperties =
            CFDictionaryCreateMutable(
                kCFAllocatorDefault,
                0,
                &kCFTypeDictionaryKeyCallBacks,
                &kCFTypeDictionaryValueCallBacks);

    CFNumberRef widthNumber =
        CreateSizeNumber(width);
    CFNumberRef heightNumber =
        CreateSizeNumber(height);
    CFNumberRef formatNumber =
        CreateFormatNumber(
            pixelFormat);

    if (pixelAttributes == nullptr ||
        ioSurfaceProperties == nullptr ||
        widthNumber == nullptr ||
        heightNumber == nullptr ||
        formatNumber == nullptr) {
        if (widthNumber != nullptr) {
            CFRelease(widthNumber);
        }
        if (heightNumber != nullptr) {
            CFRelease(heightNumber);
        }
        if (formatNumber != nullptr) {
            CFRelease(formatNumber);
        }
        if (ioSurfaceProperties != nullptr) {
            CFRelease(
                ioSurfaceProperties);
        }
        if (pixelAttributes != nullptr) {
            CFRelease(pixelAttributes);
        }
        return nullptr;
    }

    CFDictionarySetValue(
        pixelAttributes,
        kCVPixelBufferWidthKey,
        widthNumber);
    CFDictionarySetValue(
        pixelAttributes,
        kCVPixelBufferHeightKey,
        heightNumber);
    CFDictionarySetValue(
        pixelAttributes,
        kCVPixelBufferPixelFormatTypeKey,
        formatNumber);
    CFDictionarySetValue(
        pixelAttributes,
        kCVPixelBufferIOSurfacePropertiesKey,
        ioSurfaceProperties);

    CVPixelBufferPoolRef pool = nullptr;
    const CVReturn poolStatus =
        CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            nullptr,
            pixelAttributes,
            &pool);

    CFRelease(widthNumber);
    CFRelease(heightNumber);
    CFRelease(formatNumber);
    CFRelease(ioSurfaceProperties);
    CFRelease(pixelAttributes);

    if (poolStatus != kCVReturnSuccess ||
        pool == nullptr) {
        return nullptr;
    }

    CVPixelBufferRef pixelBuffer =
        nullptr;
    const CVReturn bufferStatus =
        CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pool,
            &pixelBuffer);

    CVPixelBufferPoolRelease(pool);

    if (bufferStatus != kCVReturnSuccess ||
        pixelBuffer == nullptr) {
        return nullptr;
    }

    if (!FillBlack(
            pixelBuffer,
            pixelFormat)) {
        CVPixelBufferRelease(
            pixelBuffer);
        return nullptr;
    }

    return pixelBuffer;
}

}  // namespace vcam::product
