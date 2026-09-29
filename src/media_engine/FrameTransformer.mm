#include "FrameTransformer.h"

#include <Accelerate/Accelerate.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreVideo/CoreVideo.h>

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <mutex>
#include <new>
#include <numeric>
#include <utility>
#include <vector>

namespace vcam::media_engine {

namespace {

using frame_engine::FrameValidity;
using frame_engine::OrientationState;
using frame_engine::PreparedFrame;

constexpr double kTransformTolerance = 1.0e-6;

bool NearlyEqual(CGFloat lhs, CGFloat rhs) noexcept {
    return std::fabs(static_cast<double>(lhs - rhs)) <=
           kTransformTolerance;
}

bool IsSupportedPixelFormat(OSType format) noexcept {
    return format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
           format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
}

struct PoolKey {
    std::size_t width = 0;
    std::size_t height = 0;
    OSType pixelFormat = 0;

    bool operator==(const PoolKey& other) const noexcept {
        return width == other.width &&
               height == other.height &&
               pixelFormat == other.pixelFormat;
    }

    bool valid() const noexcept {
        return width != 0 && height != 0 && pixelFormat != 0;
    }
};

struct ScaleKey {
    std::size_t sourceWidth = 0;
    std::size_t sourceHeight = 0;
    std::size_t destinationWidth = 0;
    std::size_t destinationHeight = 0;

    bool operator==(const ScaleKey& other) const noexcept {
        return sourceWidth == other.sourceWidth &&
               sourceHeight == other.sourceHeight &&
               destinationWidth == other.destinationWidth &&
               destinationHeight == other.destinationHeight;
    }
};

struct CropRect {
    std::size_t x = 0;
    std::size_t y = 0;
    std::size_t width = 0;
    std::size_t height = 0;
};

struct PhotoTransformRegions {
    CropRect source{};
    CropRect destination{};
};

bool IsDefaultPhotoTransform(
    const PhotoTransformState& transform) noexcept {
    return
        std::fabs(transform.translationX) <=
            kTransformTolerance &&
        std::fabs(transform.translationY) <=
            kTransformTolerance &&
        std::fabs(transform.scale - 1.0) <=
            kTransformTolerance;
}

std::size_t EvenExtent(
    double requested,
    std::size_t maximum) noexcept {
    if (maximum < 2) {
        return 0;
    }

    std::size_t value =
        static_cast<std::size_t>(
            std::llround(requested));
    value = std::max<std::size_t>(
        2,
        std::min(maximum, value));
    value -= value % 2;
    return value == 0 ? 2 : value;
}

long long EvenOffset(long long value) noexcept {
    if ((value % 2) != 0) {
        value += value > 0 ? -1 : 1;
    }
    return value;
}

bool ComputePhotoTransformRegions(
    std::size_t width,
    std::size_t height,
    const PhotoTransformState& requested,
    PhotoTransformRegions* regions) noexcept {
    if (regions == nullptr ||
        width < 2 ||
        height < 2 ||
        (width % 2) != 0 ||
        (height % 2) != 0) {
        return false;
    }

    const PhotoTransformState transform =
        NormalizePhotoTransformState(
            requested);

    PhotoTransformRegions result;
    result.source = {0, 0, width, height};
    result.destination = {0, 0, width, height};

    if (transform.scale >
        1.0 + kTransformTolerance) {
        const std::size_t cropWidth =
            EvenExtent(
                static_cast<double>(width) /
                    transform.scale,
                width);
        const std::size_t cropHeight =
            EvenExtent(
                static_cast<double>(height) /
                    transform.scale,
                height);
        if (cropWidth == 0 ||
            cropHeight == 0) {
            return false;
        }

        const std::size_t maxX =
            width - cropWidth;
        const std::size_t maxY =
            height - cropHeight;

        const long long shiftX =
            EvenOffset(
                static_cast<long long>(
                    std::llround(
                        transform.translationX *
                        static_cast<double>(maxX) /
                        2.0)));
        const long long shiftY =
            EvenOffset(
                static_cast<long long>(
                    std::llround(
                        transform.translationY *
                        static_cast<double>(maxY) /
                        2.0)));

        long long sourceX =
            static_cast<long long>(maxX / 2) -
            shiftX;
        long long sourceY =
            static_cast<long long>(maxY / 2) -
            shiftY;

        sourceX = std::max<long long>(
            0,
            std::min<long long>(
                static_cast<long long>(maxX),
                sourceX));
        sourceY = std::max<long long>(
            0,
            std::min<long long>(
                static_cast<long long>(maxY),
                sourceY));

        result.source = {
            static_cast<std::size_t>(sourceX) &
                ~std::size_t{1},
            static_cast<std::size_t>(sourceY) &
                ~std::size_t{1},
            cropWidth,
            cropHeight,
        };
    } else if (
        transform.scale <
        1.0 - kTransformTolerance) {
        const std::size_t destinationWidth =
            EvenExtent(
                static_cast<double>(width) *
                    transform.scale,
                width);
        const std::size_t destinationHeight =
            EvenExtent(
                static_cast<double>(height) *
                    transform.scale,
                height);
        if (destinationWidth == 0 ||
            destinationHeight == 0) {
            return false;
        }

        const std::size_t maxX =
            width - destinationWidth;
        const std::size_t maxY =
            height - destinationHeight;

        long long destinationX =
            static_cast<long long>(maxX / 2) +
            EvenOffset(
                static_cast<long long>(
                    std::llround(
                        transform.translationX *
                        static_cast<double>(maxX) /
                        2.0)));
        long long destinationY =
            static_cast<long long>(maxY / 2) +
            EvenOffset(
                static_cast<long long>(
                    std::llround(
                        transform.translationY *
                        static_cast<double>(maxY) /
                        2.0)));

        destinationX = std::max<long long>(
            0,
            std::min<long long>(
                static_cast<long long>(maxX),
                destinationX));
        destinationY = std::max<long long>(
            0,
            std::min<long long>(
                static_cast<long long>(maxY),
                destinationY));

        result.destination = {
            static_cast<std::size_t>(destinationX) &
                ~std::size_t{1},
            static_cast<std::size_t>(destinationY) &
                ~std::size_t{1},
            destinationWidth,
            destinationHeight,
        };
    } else if (
        std::fabs(transform.translationX) >
            kTransformTolerance ||
        std::fabs(transform.translationY) >
            kTransformTolerance) {
        const long long maxPanX =
            static_cast<long long>(
                (width / 4) &
                ~std::size_t{1});
        const long long maxPanY =
            static_cast<long long>(
                (height / 4) &
                ~std::size_t{1});

        const long long dx =
            EvenOffset(
                static_cast<long long>(
                    std::llround(
                        transform.translationX *
                        static_cast<double>(maxPanX))));
        const long long dy =
            EvenOffset(
                static_cast<long long>(
                    std::llround(
                        transform.translationY *
                        static_cast<double>(maxPanY))));

        const std::size_t absX =
            static_cast<std::size_t>(
                dx < 0 ? -dx : dx);
        const std::size_t absY =
            static_cast<std::size_t>(
                dy < 0 ? -dy : dy);
        const std::size_t visibleWidth =
            width - absX;
        const std::size_t visibleHeight =
            height - absY;
        if (visibleWidth < 2 ||
            visibleHeight < 2) {
            return false;
        }

        result.source = {
            dx < 0 ? absX : 0,
            dy < 0 ? absY : 0,
            visibleWidth &
                ~std::size_t{1},
            visibleHeight &
                ~std::size_t{1},
        };
        result.destination = {
            dx > 0 ? absX : 0,
            dy > 0 ? absY : 0,
            result.source.width,
            result.source.height,
        };
    }

    *regions = result;
    return true;
}

enum class MatrixKind : std::uint8_t {
    None = 0,
    ITU601,
    ITU709,
};

struct ConversionKey {
    OSType sourceFormat = 0;
    OSType targetFormat = 0;
    MatrixKind matrix = MatrixKind::None;

    bool operator==(const ConversionKey& other) const noexcept {
        return sourceFormat == other.sourceFormat &&
               targetFormat == other.targetFormat &&
               matrix == other.matrix;
    }
};

struct RotationInfo {
    bool supported = false;
    std::uint8_t constant = kRotate0DegreesClockwise;
    bool swapsDimensions = false;
};

class PixelBufferHolder final {
public:
    PixelBufferHolder() = default;
    explicit PixelBufferHolder(CVPixelBufferRef buffer) : buffer_(buffer) {}

    ~PixelBufferHolder() {
        reset();
    }

    PixelBufferHolder(const PixelBufferHolder&) = delete;
    PixelBufferHolder& operator=(const PixelBufferHolder&) = delete;

    CVPixelBufferRef get() const noexcept {
        return buffer_;
    }

    void reset(CVPixelBufferRef buffer = nullptr) noexcept {
        if (buffer_ != nullptr) {
            CVPixelBufferRelease(buffer_);
        }
        buffer_ = buffer;
    }

private:
    CVPixelBufferRef buffer_ = nullptr;
};

class PixelBufferLock final {
public:
    PixelBufferLock(CVPixelBufferRef buffer, CVOptionFlags flags)
        : buffer_(buffer),
          flags_(flags),
          status_(buffer == nullptr
                      ? kCVReturnInvalidArgument
                      : CVPixelBufferLockBaseAddress(buffer, flags)) {}

    ~PixelBufferLock() {
        if (status_ == kCVReturnSuccess && buffer_ != nullptr) {
            CVPixelBufferUnlockBaseAddress(buffer_, flags_);
        }
    }

    PixelBufferLock(const PixelBufferLock&) = delete;
    PixelBufferLock& operator=(const PixelBufferLock&) = delete;

    bool locked() const noexcept {
        return status_ == kCVReturnSuccess;
    }

private:
    CVPixelBufferRef buffer_ = nullptr;
    CVOptionFlags flags_ = 0;
    CVReturn status_ = kCVReturnInvalidArgument;
};

CFNumberRef CreateSizeNumber(std::size_t value) {
    if (value > static_cast<std::size_t>(
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

CFNumberRef CreateFormatNumber(OSType value) {
    const std::int64_t signedValue =
        static_cast<std::int64_t>(value);
    return CFNumberCreate(
        kCFAllocatorDefault,
        kCFNumberSInt64Type,
        &signedValue);
}

CVPixelBufferPoolRef CreatePixelBufferPool(const PoolKey& key) {
    if (!key.valid()) {
        return nullptr;
    }

    CFMutableDictionaryRef pixelAttributes =
        CFDictionaryCreateMutable(
            kCFAllocatorDefault,
            0,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks);
    CFMutableDictionaryRef ioSurfaceProperties =
        CFDictionaryCreateMutable(
            kCFAllocatorDefault,
            0,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks);

    CFNumberRef width = CreateSizeNumber(key.width);
    CFNumberRef height = CreateSizeNumber(key.height);
    CFNumberRef format = CreateFormatNumber(key.pixelFormat);

    if (pixelAttributes == nullptr ||
        ioSurfaceProperties == nullptr ||
        width == nullptr ||
        height == nullptr ||
        format == nullptr) {
        if (width != nullptr) {
            CFRelease(width);
        }
        if (height != nullptr) {
            CFRelease(height);
        }
        if (format != nullptr) {
            CFRelease(format);
        }
        if (ioSurfaceProperties != nullptr) {
            CFRelease(ioSurfaceProperties);
        }
        if (pixelAttributes != nullptr) {
            CFRelease(pixelAttributes);
        }
        return nullptr;
    }

    CFDictionarySetValue(
        pixelAttributes,
        kCVPixelBufferWidthKey,
        width);
    CFDictionarySetValue(
        pixelAttributes,
        kCVPixelBufferHeightKey,
        height);
    CFDictionarySetValue(
        pixelAttributes,
        kCVPixelBufferPixelFormatTypeKey,
        format);
    CFDictionarySetValue(
        pixelAttributes,
        kCVPixelBufferIOSurfacePropertiesKey,
        ioSurfaceProperties);

    CVPixelBufferPoolRef pool = nullptr;
    const CVReturn status = CVPixelBufferPoolCreate(
        kCFAllocatorDefault,
        nullptr,
        pixelAttributes,
        &pool);

    CFRelease(width);
    CFRelease(height);
    CFRelease(format);
    CFRelease(ioSurfaceProperties);
    CFRelease(pixelAttributes);

    return status == kCVReturnSuccess ? pool : nullptr;
}

bool AcquirePixelBuffer(
    CVPixelBufferPoolRef pool,
    PixelBufferHolder* output) {
    if (pool == nullptr || output == nullptr) {
        return false;
    }

    CVPixelBufferRef pixelBuffer = nullptr;
    const CVReturn status =
        CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pool,
            &pixelBuffer);
    if (status != kCVReturnSuccess || pixelBuffer == nullptr) {
        return false;
    }

    output->reset(pixelBuffer);
    return true;
}

RotationInfo ParseRotation(
    const CGAffineTransform& transform) noexcept {
    const CGFloat determinant =
        transform.a * transform.d -
        transform.b * transform.c;

    if (!NearlyEqual(determinant, 1.0)) {
        return {};
    }

    if (NearlyEqual(transform.a, 1.0) &&
        NearlyEqual(transform.b, 0.0) &&
        NearlyEqual(transform.c, 0.0) &&
        NearlyEqual(transform.d, 1.0)) {
        return {
            true,
            static_cast<std::uint8_t>(kRotate0DegreesClockwise),
            false,
        };
    }

    if (NearlyEqual(transform.a, 0.0) &&
        NearlyEqual(transform.b, 1.0) &&
        NearlyEqual(transform.c, -1.0) &&
        NearlyEqual(transform.d, 0.0)) {
        return {
            true,
            static_cast<std::uint8_t>(kRotate90DegreesClockwise),
            true,
        };
    }

    if (NearlyEqual(transform.a, -1.0) &&
        NearlyEqual(transform.b, 0.0) &&
        NearlyEqual(transform.c, 0.0) &&
        NearlyEqual(transform.d, -1.0)) {
        return {
            true,
            static_cast<std::uint8_t>(kRotate180DegreesClockwise),
            false,
        };
    }

    if (NearlyEqual(transform.a, 0.0) &&
        NearlyEqual(transform.b, -1.0) &&
        NearlyEqual(transform.c, 1.0) &&
        NearlyEqual(transform.d, 0.0)) {
        return {
            true,
            static_cast<std::uint8_t>(kRotate270DegreesClockwise),
            true,
        };
    }

    return {};
}

RotationInfo TargetStreamRotation(
    OrientationRequirement orientation) noexcept {
    switch (orientation) {
        case OrientationRequirement::UprightIdentityTransform:
        case OrientationRequirement::StreamLandscapeLeft:
            return {
                true,
                static_cast<std::uint8_t>(
                    kRotate0DegreesClockwise),
                false,
            };
        case OrientationRequirement::StreamPortrait:
            return {
                true,
                static_cast<std::uint8_t>(
                    kRotate90DegreesClockwise),
                true,
            };
        case OrientationRequirement::StreamLandscapeRight:
            return {
                true,
                static_cast<std::uint8_t>(
                    kRotate180DegreesClockwise),
                false,
            };
        case OrientationRequirement::StreamPortraitUpsideDown:
            return {
                true,
                static_cast<std::uint8_t>(
                    kRotate270DegreesClockwise),
                true,
            };
        case OrientationRequirement::PreserveSourceOrientation:
            return {};
    }
    return {};
}

bool ComputeCenterCrop(
    std::size_t sourceWidth,
    std::size_t sourceHeight,
    std::size_t targetWidth,
    std::size_t targetHeight,
    CropRect* crop) {
    if (crop == nullptr ||
        sourceWidth == 0 ||
        sourceHeight == 0 ||
        targetWidth == 0 ||
        targetHeight == 0 ||
        (sourceWidth % 2) != 0 ||
        (sourceHeight % 2) != 0 ||
        (targetWidth % 2) != 0 ||
        (targetHeight % 2) != 0) {
        return false;
    }

    const std::size_t divisor =
        std::gcd(targetWidth, targetHeight);
    const std::size_t ratioWidth = targetWidth / divisor;
    const std::size_t ratioHeight = targetHeight / divisor;

    if (ratioWidth == 0 || ratioHeight == 0) {
        return false;
    }

    std::size_t multiplier = std::min(
        sourceWidth / ratioWidth,
        sourceHeight / ratioHeight);

    if ((multiplier % 2) != 0) {
        --multiplier;
    }

    if (multiplier == 0) {
        return false;
    }

    const std::size_t cropWidth = ratioWidth * multiplier;
    const std::size_t cropHeight = ratioHeight * multiplier;

    if (cropWidth == 0 ||
        cropHeight == 0 ||
        cropWidth > sourceWidth ||
        cropHeight > sourceHeight ||
        (cropWidth % 2) != 0 ||
        (cropHeight % 2) != 0) {
        return false;
    }

    std::size_t cropX = (sourceWidth - cropWidth) / 2;
    std::size_t cropY = (sourceHeight - cropHeight) / 2;

    cropX -= cropX % 2;
    cropY -= cropY % 2;

    if (cropX + cropWidth > sourceWidth ||
        cropY + cropHeight > sourceHeight) {
        return false;
    }

    *crop = {cropX, cropY, cropWidth, cropHeight};
    return true;
}

vImage_YpCbCrPixelRange PixelRangeForFormat(
    OSType format) noexcept {
    vImage_YpCbCrPixelRange range{};

    if (format ==
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
        range.Yp_bias = 16;
        range.CbCr_bias = 128;
        range.YpRangeMax = 235;
        range.CbCrRangeMax = 240;
    } else {
        range.Yp_bias = 0;
        range.CbCr_bias = 128;
        range.YpRangeMax = 255;
        range.CbCrRangeMax = 255;
    }

    range.YpMax = 255;
    range.YpMin = 0;
    range.CbCrMax = 255;
    range.CbCrMin = 0;
    return range;
}

MatrixKind MatrixKindForFrame(
    const PreparedFrame& source) noexcept {
    const CFStringRef matrix = source.yCbCrMatrix();
    if (matrix == nullptr) {
        return MatrixKind::None;
    }

    if (CFEqual(
            matrix,
            kCVImageBufferYCbCrMatrix_ITU_R_601_4)) {
        return MatrixKind::ITU601;
    }

    if (CFEqual(
            matrix,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2)) {
        return MatrixKind::ITU709;
    }

    return MatrixKind::None;
}

const vImage_YpCbCrToARGBMatrix* YpCbCrToARGBMatrixForKind(
    MatrixKind kind) noexcept {
    switch (kind) {
        case MatrixKind::ITU601:
            return kvImage_YpCbCrToARGBMatrix_ITU_R_601_4;
        case MatrixKind::ITU709:
            return kvImage_YpCbCrToARGBMatrix_ITU_R_709_2;
        case MatrixKind::None:
            return nullptr;
    }
    return nullptr;
}

const vImage_ARGBToYpCbCrMatrix* ARGBToYpCbCrMatrixForKind(
    MatrixKind kind) noexcept {
    switch (kind) {
        case MatrixKind::ITU601:
            return kvImage_ARGBToYpCbCrMatrix_ITU_R_601_4;
        case MatrixKind::ITU709:
            return kvImage_ARGBToYpCbCrMatrix_ITU_R_709_2;
        case MatrixKind::None:
            return nullptr;
    }
    return nullptr;
}

void ApplyPropagatingMetadata(
    CVPixelBufferRef destination,
    const PreparedFrame& source) {
    if (destination == nullptr) {
        return;
    }

    if (source.attachments() != nullptr) {
        CVBufferSetAttachments(
            destination,
            source.attachments(),
            kCVAttachmentMode_ShouldPropagate);
    }

    if (source.colorPrimaries() != nullptr) {
        CVBufferSetAttachment(
            destination,
            kCVImageBufferColorPrimariesKey,
            source.colorPrimaries(),
            kCVAttachmentMode_ShouldPropagate);
    }

    if (source.transferFunction() != nullptr) {
        CVBufferSetAttachment(
            destination,
            kCVImageBufferTransferFunctionKey,
            source.transferFunction(),
            kCVAttachmentMode_ShouldPropagate);
    }

    if (source.yCbCrMatrix() != nullptr) {
        CVBufferSetAttachment(
            destination,
            kCVImageBufferYCbCrMatrixKey,
            source.yCbCrMatrix(),
            kCVAttachmentMode_ShouldPropagate);
    }
}

}  // namespace

PhotoTransformState NormalizePhotoTransformState(
    PhotoTransformState transform) noexcept {
    if (!std::isfinite(transform.translationX)) {
        transform.translationX = 0.0;
    }
    if (!std::isfinite(transform.translationY)) {
        transform.translationY = 0.0;
    }
    if (!std::isfinite(transform.scale) ||
        transform.scale <= 0.0) {
        transform.scale = 1.0;
    }

    transform.translationX =
        std::clamp(
            transform.translationX,
            -1.0,
            1.0);
    transform.translationY =
        std::clamp(
            transform.translationY,
            -1.0,
            1.0);
    transform.scale =
        std::clamp(
            transform.scale,
            0.25,
            4.0);
    return transform;
}

struct FrameTransformer::Impl {
    ~Impl() {
        releasePool(outputPool);
        releasePool(rotationPool);
        releasePool(streamRotationPool);
        releasePool(conversionInputPool);
        releasePool(photoTransformPool);
    }

    static void releasePool(CVPixelBufferPoolRef& pool) noexcept {
        if (pool != nullptr) {
            CFRelease(pool);
            pool = nullptr;
        }
    }

    bool ensurePool(
        const PoolKey& requested,
        CVPixelBufferPoolRef* pool,
        PoolKey* currentKey,
        std::uint64_t* buildCount) {
        if (pool == nullptr ||
            currentKey == nullptr ||
            buildCount == nullptr) {
            return false;
        }

        if (*pool != nullptr && *currentKey == requested) {
            return true;
        }

        CVPixelBufferPoolRef replacement =
            CreatePixelBufferPool(requested);
        if (replacement == nullptr) {
            return false;
        }

        releasePool(*pool);
        *pool = replacement;
        *currentKey = requested;
        ++(*buildCount);
        return true;
    }

    bool ensureScaleScratch(
        const ScaleKey& requested,
        const vImage_Buffer& sourceY,
        const vImage_Buffer& destinationY,
        const vImage_Buffer& sourceCbCr,
        const vImage_Buffer& destinationCbCr) {
        const vImage_Flags flags = kvImageHighQualityResampling;
        const vImage_Error yRequired =
            vImageScale_Planar8(
                &sourceY,
                &destinationY,
                nullptr,
                flags | kvImageGetTempBufferSize);
        const vImage_Error cbCrRequired =
            vImageScale_CbCr8(
                &sourceCbCr,
                &destinationCbCr,
                nullptr,
                flags | kvImageGetTempBufferSize);

        if (yRequired < 0 || cbCrRequired < 0) {
            return false;
        }

        const std::size_t ySize =
            static_cast<std::size_t>(yRequired);
        const std::size_t cbCrSize =
            static_cast<std::size_t>(cbCrRequired);

        bool rebuilt = false;

        if (!(scaleKey == requested) ||
            yScaleScratch.size() < ySize) {
            yScaleScratch.resize(ySize);
            rebuilt = true;
        }

        if (!(scaleKey == requested) ||
            cbCrScaleScratch.size() < cbCrSize) {
            cbCrScaleScratch.resize(cbCrSize);
            rebuilt = true;
        }

        if (rebuilt || !(scaleKey == requested)) {
            scaleKey = requested;
            ++stats.scaleScratchBuilds;
        }

        return true;
    }

    bool rotateNV12(
        CVPixelBufferRef source,
        CVPixelBufferRef destination,
        std::uint8_t rotationConstant) {
        if (source == nullptr ||
            destination == nullptr ||
            CVPixelBufferGetPlaneCount(source) != 2 ||
            CVPixelBufferGetPlaneCount(destination) != 2) {
            return false;
        }

        PixelBufferLock sourceLock(
            source,
            kCVPixelBufferLock_ReadOnly);
        PixelBufferLock destinationLock(destination, 0);
        if (!sourceLock.locked() || !destinationLock.locked()) {
            return false;
        }

        vImage_Buffer sourceY{
            CVPixelBufferGetBaseAddressOfPlane(source, 0),
            CVPixelBufferGetHeightOfPlane(source, 0),
            CVPixelBufferGetWidthOfPlane(source, 0),
            CVPixelBufferGetBytesPerRowOfPlane(source, 0),
        };
        vImage_Buffer destinationY{
            CVPixelBufferGetBaseAddressOfPlane(destination, 0),
            CVPixelBufferGetHeightOfPlane(destination, 0),
            CVPixelBufferGetWidthOfPlane(destination, 0),
            CVPixelBufferGetBytesPerRowOfPlane(destination, 0),
        };

        vImage_Buffer sourceCbCr{
            CVPixelBufferGetBaseAddressOfPlane(source, 1),
            CVPixelBufferGetHeightOfPlane(source, 1),
            CVPixelBufferGetWidthOfPlane(source, 1),
            CVPixelBufferGetBytesPerRowOfPlane(source, 1),
        };
        vImage_Buffer destinationCbCr{
            CVPixelBufferGetBaseAddressOfPlane(destination, 1),
            CVPixelBufferGetHeightOfPlane(destination, 1),
            CVPixelBufferGetWidthOfPlane(destination, 1),
            CVPixelBufferGetBytesPerRowOfPlane(destination, 1),
        };

        const vImage_Error yStatus =
            vImageRotate90_Planar8(
                &sourceY,
                &destinationY,
                rotationConstant,
                static_cast<Pixel_8>(0),
                kvImageNoFlags);

        const vImage_Error cbCrStatus =
            vImageRotate90_Planar16U(
                &sourceCbCr,
                &destinationCbCr,
                rotationConstant,
                static_cast<Pixel_16U>(0x8080),
                kvImageNoFlags);

        return yStatus == kvImageNoError &&
               cbCrStatus == kvImageNoError;
    }

    bool scaleNV12(
        CVPixelBufferRef source,
        CVPixelBufferRef destination) {
        if (source == nullptr ||
            destination == nullptr ||
            CVPixelBufferGetPlaneCount(source) != 2 ||
            CVPixelBufferGetPlaneCount(destination) != 2) {
            return false;
        }

        const std::size_t sourceWidth =
            CVPixelBufferGetWidth(source);
        const std::size_t sourceHeight =
            CVPixelBufferGetHeight(source);
        const std::size_t destinationWidth =
            CVPixelBufferGetWidth(destination);
        const std::size_t destinationHeight =
            CVPixelBufferGetHeight(destination);

        CropRect crop;
        if (!ComputeCenterCrop(
                sourceWidth,
                sourceHeight,
                destinationWidth,
                destinationHeight,
                &crop)) {
            return false;
        }

        PixelBufferLock sourceLock(
            source,
            kCVPixelBufferLock_ReadOnly);
        PixelBufferLock destinationLock(destination, 0);
        if (!sourceLock.locked() || !destinationLock.locked()) {
            return false;
        }

        auto* sourceYBase =
            static_cast<std::uint8_t*>(
                CVPixelBufferGetBaseAddressOfPlane(source, 0));
        auto* sourceCbCrBase =
            static_cast<std::uint8_t*>(
                CVPixelBufferGetBaseAddressOfPlane(source, 1));

        if (sourceYBase == nullptr || sourceCbCrBase == nullptr) {
            return false;
        }

        const std::size_t sourceYRowBytes =
            CVPixelBufferGetBytesPerRowOfPlane(source, 0);
        const std::size_t sourceCbCrRowBytes =
            CVPixelBufferGetBytesPerRowOfPlane(source, 1);

        vImage_Buffer sourceY{
            sourceYBase +
                crop.y * sourceYRowBytes +
                crop.x,
            crop.height,
            crop.width,
            sourceYRowBytes,
        };
        vImage_Buffer destinationY{
            CVPixelBufferGetBaseAddressOfPlane(destination, 0),
            CVPixelBufferGetHeightOfPlane(destination, 0),
            CVPixelBufferGetWidthOfPlane(destination, 0),
            CVPixelBufferGetBytesPerRowOfPlane(destination, 0),
        };

        vImage_Buffer sourceCbCr{
            sourceCbCrBase +
                (crop.y / 2) * sourceCbCrRowBytes +
                crop.x,
            crop.height / 2,
            crop.width / 2,
            sourceCbCrRowBytes,
        };
        vImage_Buffer destinationCbCr{
            CVPixelBufferGetBaseAddressOfPlane(destination, 1),
            CVPixelBufferGetHeightOfPlane(destination, 1),
            CVPixelBufferGetWidthOfPlane(destination, 1),
            CVPixelBufferGetBytesPerRowOfPlane(destination, 1),
        };

        const ScaleKey requested{
            crop.width,
            crop.height,
            destinationWidth,
            destinationHeight,
        };

        if (!ensureScaleScratch(
                requested,
                sourceY,
                destinationY,
                sourceCbCr,
                destinationCbCr)) {
            return false;
        }

        void* yScratch =
            yScaleScratch.empty()
                ? nullptr
                : yScaleScratch.data();
        void* cbCrScratch =
            cbCrScaleScratch.empty()
                ? nullptr
                : cbCrScaleScratch.data();

        const vImage_Flags flags = kvImageHighQualityResampling;

        const vImage_Error yStatus =
            vImageScale_Planar8(
                &sourceY,
                &destinationY,
                yScratch,
                flags);
        const vImage_Error cbCrStatus =
            vImageScale_CbCr8(
                &sourceCbCr,
                &destinationCbCr,
                cbCrScratch,
                flags);

        return yStatus == kvImageNoError &&
               cbCrStatus == kvImageNoError;
    }

    bool applyPhotoTransformNV12(
        CVPixelBufferRef source,
        CVPixelBufferRef destination,
        const PhotoTransformState& transform) {
        if (source == nullptr ||
            destination == nullptr ||
            CVPixelBufferGetPlaneCount(source) != 2 ||
            CVPixelBufferGetPlaneCount(destination) != 2 ||
            CVPixelBufferGetWidth(source) !=
                CVPixelBufferGetWidth(destination) ||
            CVPixelBufferGetHeight(source) !=
                CVPixelBufferGetHeight(destination) ||
            CVPixelBufferGetPixelFormatType(source) !=
                CVPixelBufferGetPixelFormatType(destination)) {
            return false;
        }

        const std::size_t width =
            CVPixelBufferGetWidth(source);
        const std::size_t height =
            CVPixelBufferGetHeight(source);

        PhotoTransformRegions regions;
        if (!ComputePhotoTransformRegions(
                width,
                height,
                transform,
                &regions)) {
            return false;
        }

        PixelBufferLock sourceLock(
            source,
            kCVPixelBufferLock_ReadOnly);
        PixelBufferLock destinationLock(
            destination,
            0);
        if (!sourceLock.locked() ||
            !destinationLock.locked()) {
            return false;
        }

        const OSType format =
            CVPixelBufferGetPixelFormatType(
                destination);
        const std::uint8_t blackY =
            format ==
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                ? 16
                : 0;

        for (std::size_t plane = 0;
             plane < 2;
             ++plane) {
            auto* base =
                static_cast<std::uint8_t*>(
                    CVPixelBufferGetBaseAddressOfPlane(
                        destination,
                        plane));
            const std::size_t stride =
                CVPixelBufferGetBytesPerRowOfPlane(
                    destination,
                    plane);
            const std::size_t rows =
                CVPixelBufferGetHeightOfPlane(
                    destination,
                    plane);
            if (base == nullptr ||
                stride == 0 ||
                rows == 0) {
                return false;
            }
            std::memset(
                base,
                plane == 0 ? blackY : 128,
                stride * rows);
        }

        auto* sourceYBase =
            static_cast<std::uint8_t*>(
                CVPixelBufferGetBaseAddressOfPlane(
                    source,
                    0));
        auto* sourceCbCrBase =
            static_cast<std::uint8_t*>(
                CVPixelBufferGetBaseAddressOfPlane(
                    source,
                    1));
        auto* destinationYBase =
            static_cast<std::uint8_t*>(
                CVPixelBufferGetBaseAddressOfPlane(
                    destination,
                    0));
        auto* destinationCbCrBase =
            static_cast<std::uint8_t*>(
                CVPixelBufferGetBaseAddressOfPlane(
                    destination,
                    1));

        if (sourceYBase == nullptr ||
            sourceCbCrBase == nullptr ||
            destinationYBase == nullptr ||
            destinationCbCrBase == nullptr) {
            return false;
        }

        const std::size_t sourceYStride =
            CVPixelBufferGetBytesPerRowOfPlane(
                source,
                0);
        const std::size_t sourceCbCrStride =
            CVPixelBufferGetBytesPerRowOfPlane(
                source,
                1);
        const std::size_t destinationYStride =
            CVPixelBufferGetBytesPerRowOfPlane(
                destination,
                0);
        const std::size_t destinationCbCrStride =
            CVPixelBufferGetBytesPerRowOfPlane(
                destination,
                1);

        vImage_Buffer sourceY{
            sourceYBase +
                regions.source.y *
                    sourceYStride +
                regions.source.x,
            regions.source.height,
            regions.source.width,
            sourceYStride,
        };
        vImage_Buffer sourceCbCr{
            sourceCbCrBase +
                (regions.source.y / 2) *
                    sourceCbCrStride +
                regions.source.x,
            regions.source.height / 2,
            regions.source.width / 2,
            sourceCbCrStride,
        };
        vImage_Buffer destinationY{
            destinationYBase +
                regions.destination.y *
                    destinationYStride +
                regions.destination.x,
            regions.destination.height,
            regions.destination.width,
            destinationYStride,
        };
        vImage_Buffer destinationCbCr{
            destinationCbCrBase +
                (regions.destination.y / 2) *
                    destinationCbCrStride +
                regions.destination.x,
            regions.destination.height / 2,
            regions.destination.width / 2,
            destinationCbCrStride,
        };

        const ScaleKey requested{
            regions.source.width,
            regions.source.height,
            regions.destination.width,
            regions.destination.height,
        };

        if (!ensureScaleScratch(
                requested,
                sourceY,
                destinationY,
                sourceCbCr,
                destinationCbCr)) {
            return false;
        }

        const vImage_Flags flags =
            kvImageHighQualityResampling;
        const vImage_Error yStatus =
            vImageScale_Planar8(
                &sourceY,
                &destinationY,
                yScaleScratch.empty()
                    ? nullptr
                    : yScaleScratch.data(),
                flags);
        const vImage_Error cbCrStatus =
            vImageScale_CbCr8(
                &sourceCbCr,
                &destinationCbCr,
                cbCrScaleScratch.empty()
                    ? nullptr
                    : cbCrScaleScratch.data(),
                flags);

        return yStatus == kvImageNoError &&
               cbCrStatus == kvImageNoError;
    }

    bool ensureConversionDescriptors(
        OSType sourceFormat,
        OSType targetFormat,
        MatrixKind matrixKind) {
        const ConversionKey requested{
            sourceFormat,
            targetFormat,
            matrixKind,
        };

        if (conversionValid && conversionKey == requested) {
            return true;
        }

        const vImage_YpCbCrToARGBMatrix* toARGBMatrix =
            YpCbCrToARGBMatrixForKind(matrixKind);
        const vImage_ARGBToYpCbCrMatrix* fromARGBMatrix =
            ARGBToYpCbCrMatrixForKind(matrixKind);

        if (toARGBMatrix == nullptr ||
            fromARGBMatrix == nullptr) {
            return false;
        }

        const vImage_YpCbCrPixelRange sourceRange =
            PixelRangeForFormat(sourceFormat);
        const vImage_YpCbCrPixelRange targetRange =
            PixelRangeForFormat(targetFormat);

        vImage_YpCbCrToARGB newToARGB{};
        vImage_ARGBToYpCbCr newFromARGB{};

        const vImage_Error toARGBStatus =
            vImageConvert_YpCbCrToARGB_GenerateConversion(
                toARGBMatrix,
                &sourceRange,
                &newToARGB,
                kvImage420Yp8_CbCr8,
                kvImageARGB8888,
                kvImageNoFlags);
        if (toARGBStatus != kvImageNoError) {
            return false;
        }

        const vImage_Error fromARGBStatus =
            vImageConvert_ARGBToYpCbCr_GenerateConversion(
                fromARGBMatrix,
                &targetRange,
                &newFromARGB,
                kvImageARGB8888,
                kvImage420Yp8_CbCr8,
                kvImageNoFlags);
        if (fromARGBStatus != kvImageNoError) {
            return false;
        }

        yCbCrToARGB = newToARGB;
        argbToYpCbCr = newFromARGB;
        conversionKey = requested;
        conversionValid = true;
        ++stats.conversionDescriptorBuilds;
        return true;
    }

    bool ensureARGBScratch(
        std::size_t width,
        std::size_t height) {
        if (width == 0 ||
            height == 0 ||
            width > std::numeric_limits<std::size_t>::max() / 4) {
            return false;
        }

        const std::size_t rowBytes = width * 4;
        if (height >
            std::numeric_limits<std::size_t>::max() / rowBytes) {
            return false;
        }

        const std::size_t required = rowBytes * height;

        if (argbWidth == width &&
            argbHeight == height &&
            argbScratch.size() >= required) {
            return true;
        }

        argbScratch.resize(required);
        argbWidth = width;
        argbHeight = height;
        ++stats.argbScratchBuilds;
        return true;
    }

    bool convertRange(
        CVPixelBufferRef source,
        CVPixelBufferRef destination,
        MatrixKind matrixKind) {
        if (source == nullptr ||
            destination == nullptr ||
            CVPixelBufferGetPlaneCount(source) != 2 ||
            CVPixelBufferGetPlaneCount(destination) != 2) {
            return false;
        }

        const std::size_t width = CVPixelBufferGetWidth(source);
        const std::size_t height = CVPixelBufferGetHeight(source);
        if (width != CVPixelBufferGetWidth(destination) ||
            height != CVPixelBufferGetHeight(destination)) {
            return false;
        }

        const OSType sourceFormat =
            CVPixelBufferGetPixelFormatType(source);
        const OSType destinationFormat =
            CVPixelBufferGetPixelFormatType(destination);

        if (!ensureConversionDescriptors(
                sourceFormat,
                destinationFormat,
                matrixKind) ||
            !ensureARGBScratch(width, height)) {
            return false;
        }

        PixelBufferLock sourceLock(
            source,
            kCVPixelBufferLock_ReadOnly);
        PixelBufferLock destinationLock(destination, 0);
        if (!sourceLock.locked() || !destinationLock.locked()) {
            return false;
        }

        vImage_Buffer sourceY{
            CVPixelBufferGetBaseAddressOfPlane(source, 0),
            CVPixelBufferGetHeightOfPlane(source, 0),
            CVPixelBufferGetWidthOfPlane(source, 0),
            CVPixelBufferGetBytesPerRowOfPlane(source, 0),
        };
        vImage_Buffer sourceCbCr{
            CVPixelBufferGetBaseAddressOfPlane(source, 1),
            CVPixelBufferGetHeightOfPlane(source, 1),
            CVPixelBufferGetWidthOfPlane(source, 1),
            CVPixelBufferGetBytesPerRowOfPlane(source, 1),
        };

        vImage_Buffer argb{
            argbScratch.data(),
            height,
            width,
            width * 4,
        };

        vImage_Buffer destinationY{
            CVPixelBufferGetBaseAddressOfPlane(destination, 0),
            CVPixelBufferGetHeightOfPlane(destination, 0),
            CVPixelBufferGetWidthOfPlane(destination, 0),
            CVPixelBufferGetBytesPerRowOfPlane(destination, 0),
        };
        vImage_Buffer destinationCbCr{
            CVPixelBufferGetBaseAddressOfPlane(destination, 1),
            CVPixelBufferGetHeightOfPlane(destination, 1),
            CVPixelBufferGetWidthOfPlane(destination, 1),
            CVPixelBufferGetBytesPerRowOfPlane(destination, 1),
        };

        const std::uint8_t permuteMap[4] = {0, 1, 2, 3};

        const vImage_Error toARGBStatus =
            vImageConvert_420Yp8_CbCr8ToARGB8888(
                &sourceY,
                &sourceCbCr,
                &argb,
                &yCbCrToARGB,
                permuteMap,
                255,
                kvImageNoFlags);
        if (toARGBStatus != kvImageNoError) {
            return false;
        }

        const vImage_Error fromARGBStatus =
            vImageConvert_ARGB8888To420Yp8_CbCr8(
                &argb,
                &destinationY,
                &destinationCbCr,
                &argbToYpCbCr,
                permuteMap,
                kvImageNoFlags);

        return fromARGBStatus == kvImageNoError;
    }

    FrameTransformerStats stats{};

    CVPixelBufferPoolRef outputPool = nullptr;
    PoolKey outputPoolKey{};

    CVPixelBufferPoolRef rotationPool = nullptr;
    PoolKey rotationPoolKey{};

    CVPixelBufferPoolRef streamRotationPool = nullptr;
    PoolKey streamRotationPoolKey{};

    CVPixelBufferPoolRef conversionInputPool = nullptr;
    PoolKey conversionInputPoolKey{};

    CVPixelBufferPoolRef photoTransformPool = nullptr;
    PoolKey photoTransformPoolKey{};

    mutable std::mutex photoTransformMutex;
    PhotoTransformState photoTransform{};

    ScaleKey scaleKey{};
    std::vector<std::uint8_t> yScaleScratch;
    std::vector<std::uint8_t> cbCrScaleScratch;

    std::vector<std::uint8_t> argbScratch;
    std::size_t argbWidth = 0;
    std::size_t argbHeight = 0;

    ConversionKey conversionKey{};
    bool conversionValid = false;
    vImage_YpCbCrToARGB yCbCrToARGB{};
    vImage_ARGBToYpCbCr argbToYpCbCr{};
};

FrameTransformer::FrameTransformer()
    : impl_(std::make_unique<Impl>()) {}

FrameTransformer::~FrameTransformer() = default;

void FrameTransformer::setPhotoTransform(
    const PhotoTransformState& transform) noexcept {
    std::lock_guard<std::mutex> lock(
        impl_->photoTransformMutex);
    impl_->photoTransform =
        NormalizePhotoTransformState(
            transform);
}

PhotoTransformState
FrameTransformer::photoTransform() const noexcept {
    std::lock_guard<std::mutex> lock(
        impl_->photoTransformMutex);
    return impl_->photoTransform;
}

bool FrameTransformer::
hasNonDefaultPhotoTransform() const noexcept {
    return !IsDefaultPhotoTransform(
        photoTransform());
}

FrameTransformResult FrameTransformer::transform(
    const PreparedFrame& source,
    const SourceGeometry& geometry,
    const NormalizationTarget& target,
    std::uint64_t currentMediaGeneration,
    std::uint64_t currentTimelineEpoch) {
    try {
        return transformImpl(
            source,
            geometry,
            target,
            currentMediaGeneration,
            currentTimelineEpoch);
    } catch (const std::bad_alloc&) {
        FrameTransformResult result;
        result.status = FrameTransformStatus::AllocationFailure;
        return result;
    }
}

FrameTransformResult FrameTransformer::transformImpl(
    const PreparedFrame& source,
    const SourceGeometry& geometry,
    const NormalizationTarget& target,
    std::uint64_t currentMediaGeneration,
    std::uint64_t currentTimelineEpoch) {
    FrameTransformResult result;

    if (target.width == 0 ||
        target.height == 0 ||
        (target.width % 2) != 0 ||
        (target.height % 2) != 0 ||
        !IsSupportedPixelFormat(target.pixelFormat) ||
        target.orientation ==
            OrientationRequirement::PreserveSourceOrientation) {
        result.status = FrameTransformStatus::UnsupportedTarget;
        return result;
    }

    if (source.validity() != FrameValidity::Ready ||
        !source.isInternallyConsistent() ||
        source.pixelBuffer() == nullptr ||
        !IsSupportedPixelFormat(source.pixelFormat()) ||
        source.width() == 0 ||
        source.height() == 0 ||
        (source.width() % 2) != 0 ||
        (source.height() % 2) != 0 ||
        CVPixelBufferGetPlaneCount(source.pixelBuffer()) != 2) {
        result.status = FrameTransformStatus::InvalidFrame;
        return result;
    }

    if (source.identity().mediaGeneration !=
        currentMediaGeneration) {
        result.status = FrameTransformStatus::GenerationMismatch;
        return result;
    }

    if (source.identity().timelineEpoch !=
        currentTimelineEpoch) {
        result.status = FrameTransformStatus::TimelineMismatch;
        return result;
    }

    const RotationInfo rotation =
        ParseRotation(geometry.preferredTransform);
    if (!rotation.supported) {
        result.status = FrameTransformStatus::UnsupportedGeometry;
        return result;
    }

    const PoolKey outputKey{
        target.width,
        target.height,
        target.pixelFormat,
    };
    if (!impl_->ensurePool(
            outputKey,
            &impl_->outputPool,
            &impl_->outputPoolKey,
            &impl_->stats.outputPoolBuilds)) {
        result.status = FrameTransformStatus::PoolFailure;
        return result;
    }

    PixelBufferHolder output;
    if (!AcquirePixelBuffer(impl_->outputPool, &output)) {
        result.status = FrameTransformStatus::PoolFailure;
        return result;
    }

    CVPixelBufferRef working = source.pixelBuffer();
    std::size_t workingWidth = source.width();
    std::size_t workingHeight = source.height();
    PixelBufferHolder rotated;

    if (rotation.constant !=
        static_cast<std::uint8_t>(kRotate0DegreesClockwise)) {
        const std::size_t rotatedWidth =
            rotation.swapsDimensions
                ? source.height()
                : source.width();
        const std::size_t rotatedHeight =
            rotation.swapsDimensions
                ? source.width()
                : source.height();

        const PoolKey rotationKey{
            rotatedWidth,
            rotatedHeight,
            source.pixelFormat(),
        };

        if (!impl_->ensurePool(
                rotationKey,
                &impl_->rotationPool,
                &impl_->rotationPoolKey,
                &impl_->stats.rotationPoolBuilds) ||
            !AcquirePixelBuffer(impl_->rotationPool, &rotated)) {
            result.status = FrameTransformStatus::PoolFailure;
            return result;
        }

        if (!impl_->rotateNV12(
                source.pixelBuffer(),
                rotated.get(),
                rotation.constant)) {
            result.status = FrameTransformStatus::TransformFailure;
            return result;
        }

        working = rotated.get();
        workingWidth = rotatedWidth;
        workingHeight = rotatedHeight;
    }

    const RotationInfo streamRotation =
        TargetStreamRotation(
            target.orientation);
    if (!streamRotation.supported) {
        result.status =
            FrameTransformStatus::UnsupportedTarget;
        return result;
    }

    PixelBufferHolder streamRotated;
    if (streamRotation.constant !=
        static_cast<std::uint8_t>(
            kRotate0DegreesClockwise)) {
        const std::size_t streamWidth =
            streamRotation.swapsDimensions
                ? workingHeight
                : workingWidth;
        const std::size_t streamHeight =
            streamRotation.swapsDimensions
                ? workingWidth
                : workingHeight;

        const PoolKey streamKey{
            streamWidth,
            streamHeight,
            source.pixelFormat(),
        };

        if (!impl_->ensurePool(
                streamKey,
                &impl_->streamRotationPool,
                &impl_->streamRotationPoolKey,
                &impl_->stats.streamRotationPoolBuilds) ||
            !AcquirePixelBuffer(
                impl_->streamRotationPool,
                &streamRotated)) {
            result.status =
                FrameTransformStatus::PoolFailure;
            return result;
        }

        if (!impl_->rotateNV12(
                working,
                streamRotated.get(),
                streamRotation.constant)) {
            result.status =
                FrameTransformStatus::TransformFailure;
            return result;
        }

        working = streamRotated.get();
        workingWidth = streamWidth;
        workingHeight = streamHeight;
    }

    if (source.pixelFormat() == target.pixelFormat) {
        if (!impl_->scaleNV12(working, output.get())) {
            result.status = FrameTransformStatus::TransformFailure;
            return result;
        }
    } else {
        const MatrixKind matrixKind =
            MatrixKindForFrame(source);
        if (matrixKind == MatrixKind::None) {
            result.status =
                FrameTransformStatus::UnsupportedColorConversion;
            return result;
        }

        const PoolKey conversionKey{
            target.width,
            target.height,
            source.pixelFormat(),
        };

        if (!impl_->ensurePool(
                conversionKey,
                &impl_->conversionInputPool,
                &impl_->conversionInputPoolKey,
                &impl_->stats.conversionInputPoolBuilds)) {
            result.status = FrameTransformStatus::PoolFailure;
            return result;
        }

        PixelBufferHolder conversionInput;
        if (!AcquirePixelBuffer(
                impl_->conversionInputPool,
                &conversionInput)) {
            result.status = FrameTransformStatus::PoolFailure;
            return result;
        }

        if (!impl_->scaleNV12(
                working,
                conversionInput.get()) ||
            !impl_->convertRange(
                conversionInput.get(),
                output.get(),
                matrixKind)) {
            result.status = FrameTransformStatus::TransformFailure;
            return result;
        }
    }

    CVPixelBufferRef finalOutput =
        output.get();
    PixelBufferHolder photoTransformed;

    const PhotoTransformState
        activePhotoTransform =
            photoTransform();
    if (!IsDefaultPhotoTransform(
            activePhotoTransform)) {
        const PoolKey photoKey{
            target.width,
            target.height,
            target.pixelFormat,
        };

        if (!impl_->ensurePool(
                photoKey,
                &impl_->photoTransformPool,
                &impl_->photoTransformPoolKey,
                &impl_->stats.photoTransformPoolBuilds) ||
            !AcquirePixelBuffer(
                impl_->photoTransformPool,
                &photoTransformed) ||
            !impl_->applyPhotoTransformNV12(
                output.get(),
                photoTransformed.get(),
                activePhotoTransform)) {
            result.status =
                FrameTransformStatus::TransformFailure;
            return result;
        }

        finalOutput =
            photoTransformed.get();
    }

    ApplyPropagatingMetadata(
        finalOutput,
        source);

    PreparedFrame transformed(
        finalOutput,
        source.identity(),
        source.timing(),
        OrientationState::Normalized,
        FrameValidity::Ready,
        source.colorPrimaries(),
        source.transferFunction(),
        source.yCbCrMatrix(),
        source.attachments());

    if (!transformed.isInternallyConsistent() ||
        transformed.width() != target.width ||
        transformed.height() != target.height ||
        transformed.pixelFormat() != target.pixelFormat) {
        result.status = FrameTransformStatus::TransformFailure;
        return result;
    }

    result.status = FrameTransformStatus::Transformed;
    result.frame.emplace(std::move(transformed));
    return result;
}

FrameTransformerStats FrameTransformer::stats() const noexcept {
    return impl_->stats;
}

}  // namespace vcam::media_engine
