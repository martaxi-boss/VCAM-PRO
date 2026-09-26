#include "LocalPhotoReader.h"

#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

#include <Accelerate/Accelerate.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

#include <algorithm>
#include <cstdint>
#include <limits>
#include <string>
#include <vector>

namespace vcam::media_engine {

using frame_engine::FrameIdentity;
using frame_engine::FrameTiming;
using frame_engine::FrameValidity;
using frame_engine::OrientationState;
using frame_engine::PreparedFrame;
using frame_engine::ReaderErrorCode;

namespace {

bool IsAllowedOutputPixelFormat(OSType pixelFormat) noexcept {
    return pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
           pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
}

bool LooksLikeRemoteOrURLString(const std::string& path) noexcept {
    return path.find("://") != std::string::npos;
}

vImage_YpCbCrPixelRange PixelRangeForFormat(OSType format) noexcept {
    vImage_YpCbCrPixelRange range{};
    if (format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
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

bool CopyPixelDimension(CFDictionaryRef properties,
                        CFStringRef key,
                        std::size_t* result) {
    if (properties == nullptr || key == nullptr || result == nullptr) {
        return false;
    }
    CFTypeRef value = CFDictionaryGetValue(properties, key);
    if (value == nullptr || CFGetTypeID(value) != CFNumberGetTypeID()) {
        return false;
    }
    long long dimension = 0;
    if (!CFNumberGetValue(
            static_cast<CFNumberRef>(value),
            kCFNumberLongLongType,
            &dimension) ||
        dimension <= 0) {
        return false;
    }
    *result = static_cast<std::size_t>(dimension);
    return true;
}

bool DecodeNormalizedARGB(NSURL* url,
                          std::vector<std::uint8_t>* argb,
                          std::size_t* widthOut,
                          std::size_t* heightOut,
                          std::string* message) {
    if (url == nil || argb == nullptr ||
        widthOut == nullptr || heightOut == nullptr) {
        return false;
    }

    CGImageSourceRef source =
        CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr);
    if (source == nullptr || CGImageSourceGetCount(source) == 0) {
        if (source != nullptr) CFRelease(source);
        if (message != nullptr) {
            *message = "ImageIO could not open the selected image.";
        }
        return false;
    }

    CFDictionaryRef properties =
        CGImageSourceCopyPropertiesAtIndex(source, 0, nullptr);
    std::size_t sourceWidth = 0;
    std::size_t sourceHeight = 0;
    const bool dimensionsValid =
        CopyPixelDimension(properties, kCGImagePropertyPixelWidth, &sourceWidth) &&
        CopyPixelDimension(properties, kCGImagePropertyPixelHeight, &sourceHeight);
    if (properties != nullptr) CFRelease(properties);

    if (!dimensionsValid) {
        CFRelease(source);
        if (message != nullptr) {
            *message = "Selected image has invalid pixel dimensions.";
        }
        return false;
    }

    const std::size_t maxDimension = std::max(sourceWidth, sourceHeight);
    NSDictionary* options = @{
        (NSString*)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
        (NSString*)kCGImageSourceCreateThumbnailWithTransform : @YES,
        (NSString*)kCGImageSourceShouldCacheImmediately : @YES,
        (NSString*)kCGImageSourceThumbnailMaxPixelSize : @(maxDimension)
    };

    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(
        source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);

    if (image == nullptr) {
        if (message != nullptr) {
            *message = "ImageIO failed to decode the selected image.";
        }
        return false;
    }

    std::size_t width = CGImageGetWidth(image);
    std::size_t height = CGImageGetHeight(image);
    width -= width % 2;
    height -= height % 2;

    if (width < 2 || height < 2 ||
        width > std::numeric_limits<std::size_t>::max() / 4 ||
        height > std::numeric_limits<std::size_t>::max() / (width * 4)) {
        CGImageRelease(image);
        if (message != nullptr) {
            *message = "Selected image geometry is unsupported for 4:2:0.";
        }
        return false;
    }

    argb->assign(width * height * 4, 0);

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(
        argb->data(),
        width,
        height,
        8,
        width * 4,
        colorSpace,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Big);
    if (colorSpace != nullptr) CGColorSpaceRelease(colorSpace);

    if (context == nullptr) {
        CGImageRelease(image);
        if (message != nullptr) {
            *message = "Unable to allocate normalized image decode surface.";
        }
        return false;
    }

    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(
        context,
        CGRectMake(0, 0,
                   static_cast<CGFloat>(width),
                   static_cast<CGFloat>(height)),
        image);
    CGContextRelease(context);
    CGImageRelease(image);

    *widthOut = width;
    *heightOut = height;
    return true;
}

CVPixelBufferRef CreateYUVPixelBuffer(std::size_t width,
                                      std::size_t height,
                                      OSType format) {
    NSDictionary* attributes = @{
        (NSString*)kCVPixelBufferIOSurfacePropertiesKey : @{}
    };
    CVPixelBufferRef pixelBuffer = nullptr;
    const CVReturn status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        format,
        (__bridge CFDictionaryRef)attributes,
        &pixelBuffer);
    return status == kCVReturnSuccess ? pixelBuffer : nullptr;
}

bool ConvertARGBToYUV(const std::vector<std::uint8_t>& argb,
                      std::size_t width,
                      std::size_t height,
                      OSType format,
                      CVPixelBufferRef destination) {
    if (destination == nullptr ||
        CVPixelBufferGetPlaneCount(destination) != 2 ||
        argb.size() < width * height * 4) {
        return false;
    }

    const vImage_YpCbCrPixelRange range =
        PixelRangeForFormat(format);
    vImage_ARGBToYpCbCr conversion{};

    const vImage_Error descriptorStatus =
        vImageConvert_ARGBToYpCbCr_GenerateConversion(
            kvImage_ARGBToYpCbCrMatrix_ITU_R_709_2,
            &range,
            &conversion,
            kvImageARGB8888,
            kvImage420Yp8_CbCr8,
            kvImageNoFlags);
    if (descriptorStatus != kvImageNoError) {
        return false;
    }

    if (CVPixelBufferLockBaseAddress(destination, 0) != kCVReturnSuccess) {
        return false;
    }

    vImage_Buffer source{
        const_cast<std::uint8_t*>(argb.data()),
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
    const vImage_Error status =
        vImageConvert_ARGB8888To420Yp8_CbCr8(
            &source,
            &destinationY,
            &destinationCbCr,
            &conversion,
            permuteMap,
            kvImageNoFlags);

    CVPixelBufferUnlockBaseAddress(destination, 0);
    return status == kvImageNoError;
}

ReadResult SimpleResult(
    ReadResultKind kind,
    ReaderErrorCode error = ReaderErrorCode::None,
    const std::string& message = {}) {
    ReadResult result;
    result.kind = kind;
    result.error = error;
    result.message = message;
    return result;
}

}  // namespace

struct LocalPhotoReader::Impl {
    LocalPhotoReaderConfig config{};
    SourceVideoInfo sourceInfo{};
    CVPixelBufferRef decodedPixelBuffer = nullptr;
    std::string lastErrorMessage;
    ReaderErrorCode lastErrorCode = ReaderErrorCode::None;
    std::int64_t frameIndex = 0;
    std::uint64_t decodeCount = 0;
    bool opened = false;
    bool started = false;
    bool cancelled = false;

    ~Impl() {
        if (decodedPixelBuffer != nullptr) {
            CVPixelBufferRelease(decodedPixelBuffer);
        }
    }
};

LocalPhotoReader::LocalPhotoReader(
    frame_engine::FrameEngineState& state)
    : state_(state),
      impl_(std::make_unique<Impl>()) {}

LocalPhotoReader::~LocalPhotoReader() = default;

bool LocalPhotoReader::open(
    const std::string& filesystemPath,
    const LocalPhotoReaderConfig& config) {
    @autoreleasepool {
        clearLastError();

        if (!IsAllowedOutputPixelFormat(config.outputPixelFormat)) {
            setLastError(
                ReaderErrorCode::Unsupported,
                "Photo source supports only explicit 420v or 420f output.");
            return false;
        }
        if (config.cadenceNumerator <= 0 ||
            config.cadenceDenominator <= 0) {
            setLastError(
                ReaderErrorCode::Unsupported,
                "Photo cadence must be a positive explicit FPS ratio.");
            return false;
        }
        if (filesystemPath.empty() ||
            LooksLikeRemoteOrURLString(filesystemPath)) {
            setLastError(
                ReaderErrorCode::InitializationFailed,
                "Photo source accepts local filesystem paths only.");
            return false;
        }

        NSString* path =
            [[NSString alloc] initWithUTF8String:filesystemPath.c_str()];
        if (path == nil) {
            setLastError(
                ReaderErrorCode::InitializationFailed,
                "Photo filesystem path is not valid UTF-8.");
            return false;
        }
        path = [path stringByStandardizingPath];

        BOOL directory = NO;
        if (![[NSFileManager defaultManager]
                fileExistsAtPath:path
                     isDirectory:&directory] ||
            directory) {
            setLastError(
                ReaderErrorCode::InitializationFailed,
                "Local photo path does not exist or is a directory.");
            return false;
        }

        NSURL* url = [NSURL fileURLWithPath:path isDirectory:NO];
        std::vector<std::uint8_t> argb;
        std::size_t width = 0;
        std::size_t height = 0;
        std::string decodeMessage;

        if (url == nil || !url.isFileURL ||
            !DecodeNormalizedARGB(
                url,
                &argb,
                &width,
                &height,
                &decodeMessage)) {
            setLastError(
                ReaderErrorCode::ReadFailed,
                decodeMessage.empty()
                    ? "Unable to decode local photo."
                    : decodeMessage);
            return false;
        }

        CVPixelBufferRef pixelBuffer =
            CreateYUVPixelBuffer(
                width,
                height,
                config.outputPixelFormat);

        if (pixelBuffer == nullptr ||
            !ConvertARGBToYUV(
                argb,
                width,
                height,
                config.outputPixelFormat,
                pixelBuffer)) {
            if (pixelBuffer != nullptr) {
                CVPixelBufferRelease(pixelBuffer);
            }
            setLastError(
                ReaderErrorCode::ReadFailed,
                "Unable to convert decoded photo to the VCAM 4:2:0 source format.");
            return false;
        }

        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_709_2,
            kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_ITU_R_709_2,
            kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            kCVAttachmentMode_ShouldPropagate);

        if (impl_->opened || impl_->started) {
            stop();
        } else if (impl_->decodedPixelBuffer != nullptr) {
            CVPixelBufferRelease(impl_->decodedPixelBuffer);
            impl_->decodedPixelBuffer = nullptr;
        }

        impl_->config = config;
        impl_->decodedPixelBuffer = pixelBuffer;
        impl_->frameIndex = 0;
        ++impl_->decodeCount;
        impl_->opened = true;
        impl_->started = false;
        impl_->cancelled = false;

        impl_->sourceInfo.naturalSize =
            CGSizeMake(
                static_cast<CGFloat>(width),
                static_cast<CGFloat>(height));
        impl_->sourceInfo.preferredTransform =
            CGAffineTransformIdentity;
        impl_->sourceInfo.duration = kCMTimeIndefinite;
        impl_->sourceInfo.outputPixelFormat =
            config.outputPixelFormat;

        state_.selectOrReplaceMedia();
        if (!state_.markReaderReady()) {
            CVPixelBufferRelease(impl_->decodedPixelBuffer);
            impl_->decodedPixelBuffer = nullptr;
            impl_->opened = false;
            state_.markPlaybackFailed();
            setLastError(
                ReaderErrorCode::Unknown,
                "FrameEngineState rejected photo reader-ready transition.");
            return false;
        }

        return true;
    }
}

bool LocalPhotoReader::start() {
    clearLastError();

    if (!impl_->opened ||
        impl_->decodedPixelBuffer == nullptr ||
        impl_->cancelled) {
        setLastError(
            ReaderErrorCode::InitializationFailed,
            "No configured local photo source is available.");
        return false;
    }

    if (impl_->started) {
        return true;
    }

    if (!state_.start() ||
        !state_.beginReading()) {
        state_.markReaderFailed(
            ReaderErrorCode::Unknown);
        state_.markPlaybackFailed();
        setLastError(
            ReaderErrorCode::Unknown,
            "FrameEngineState rejected photo playback start.");
        return false;
    }

    impl_->started = true;
    return true;
}

ReadResult LocalPhotoReader::readNext() {
    if (impl_->cancelled) {
        return SimpleResult(
            ReadResultKind::Cancelled,
            ReaderErrorCode::Cancelled,
            "Photo source was cancelled.");
    }

    if (!impl_->opened ||
        !impl_->started ||
        impl_->decodedPixelBuffer == nullptr) {
        return SimpleResult(
            ReadResultKind::NotReady);
    }

    const CMTime duration =
        CMTimeMake(
            impl_->config.cadenceDenominator,
            impl_->config.cadenceNumerator);
    const CMTime sourcePTS =
        CMTimeMake(
            impl_->frameIndex *
                static_cast<std::int64_t>(
                    impl_->config.cadenceDenominator),
            impl_->config.cadenceNumerator);
    ++impl_->frameIndex;

    FrameTiming timing;
    timing.sourcePTS = sourcePTS;
    timing.presentationTimestamp =
        kCMTimeInvalid;
    timing.duration = duration;
    timing.producedAtHostTime =
        std::nullopt;

    const FrameIdentity identity =
        state_.nextFrameIdentity();

    CFDictionaryRef attachments =
        CVBufferCopyAttachments(
            impl_->decodedPixelBuffer,
            kCVAttachmentMode_ShouldPropagate);

    PreparedFrame frame(
        impl_->decodedPixelBuffer,
        identity,
        timing,
        OrientationState::Normalized,
        FrameValidity::Ready,
        kCVImageBufferColorPrimaries_ITU_R_709_2,
        kCVImageBufferTransferFunction_ITU_R_709_2,
        kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        attachments);

    if (attachments != nullptr) {
        CFRelease(attachments);
    }

    if (!frame.isInternallyConsistent()) {
        frame.markFailed();
        state_.markReaderFailed(
            ReaderErrorCode::ReadFailed);
        state_.markPlaybackFailed();
        setLastError(
            ReaderErrorCode::ReadFailed,
            "Photo PreparedFrame invariant validation failed.");
        return SimpleResult(
            ReadResultKind::Failed,
            lastErrorCode(),
            lastErrorMessage());
    }

    ReadResult result;
    result.kind = ReadResultKind::Frame;
    result.frame.emplace(std::move(frame));
    return result;
}

void LocalPhotoReader::stop() {
    if (impl_->opened || impl_->started) {
        state_.cancelReader();
    }

    if (impl_->decodedPixelBuffer != nullptr) {
        CVPixelBufferRelease(
            impl_->decodedPixelBuffer);
        impl_->decodedPixelBuffer = nullptr;
    }

    impl_->opened = false;
    impl_->started = false;
    impl_->cancelled = true;
    impl_->frameIndex = 0;
    impl_->sourceInfo = {};
}

bool LocalPhotoReader::isOpen() const noexcept {
    return impl_->opened;
}

bool LocalPhotoReader::isStarted() const noexcept {
    return impl_->started;
}

std::uint64_t
LocalPhotoReader::decodeCount() const noexcept {
    return impl_->decodeCount;
}

CVPixelBufferRef
LocalPhotoReader::decodedPixelBufferForTesting() const noexcept {
    return impl_->decodedPixelBuffer;
}

std::optional<SourceVideoInfo>
LocalPhotoReader::sourceInfo() const {
    if (!impl_->opened) {
        return std::nullopt;
    }
    return impl_->sourceInfo;
}

ReaderErrorCode
LocalPhotoReader::lastErrorCode() const noexcept {
    return impl_->lastErrorCode;
}

const std::string&
LocalPhotoReader::lastErrorMessage() const noexcept {
    return impl_->lastErrorMessage;
}

void LocalPhotoReader::clearLastError() noexcept {
    impl_->lastErrorCode =
        ReaderErrorCode::None;
    impl_->lastErrorMessage.clear();
}

void LocalPhotoReader::setLastError(
    ReaderErrorCode code,
    const std::string& message) {
    impl_->lastErrorCode = code;
    impl_->lastErrorMessage = message;
}

}  // namespace vcam::media_engine
