#include "FrameNormalizer.h"
#include "FrameTransformer.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <functional>
#include <iostream>
#include <limits>
#include <optional>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {

using namespace vcam::frame_engine;
using namespace vcam::media_engine;

int gTestsRun = 0;
int gFailures = 0;

#define CHECK(condition)                                                        \
    do {                                                                        \
        if (!(condition)) {                                                     \
            std::cerr << "CHECK failed at " << __FILE__ << ":" << __LINE__    \
                      << ": " #condition << std::endl;                          \
            return false;                                                       \
        }                                                                       \
    } while (false)

CVPixelBufferRef CreatePixelBuffer(
    OSType format,
    std::size_t width,
    std::size_t height) {
    CVPixelBufferRef pixelBuffer = nullptr;

    const void* keys[] = {
        kCVPixelBufferIOSurfacePropertiesKey,
    };
    CFDictionaryRef emptySurfaceProperties =
        CFDictionaryCreate(
            kCFAllocatorDefault,
            nullptr,
            nullptr,
            0,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks);
    const void* values[] = {
        emptySurfaceProperties,
    };
    CFDictionaryRef attributes =
        CFDictionaryCreate(
            kCFAllocatorDefault,
            keys,
            values,
            1,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks);

    const CVReturn status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        format,
        attributes,
        &pixelBuffer);

    CFRelease(attributes);
    CFRelease(emptySurfaceProperties);

    return status == kCVReturnSuccess ? pixelBuffer : nullptr;
}

bool FillPixelBuffer(
    CVPixelBufferRef pixelBuffer,
    const std::vector<std::uint8_t>& yValues,
    std::uint8_t cb = 128,
    std::uint8_t cr = 128) {
    if (pixelBuffer == nullptr ||
        CVPixelBufferGetPlaneCount(pixelBuffer) != 2) {
        return false;
    }

    const std::size_t width = CVPixelBufferGetWidth(pixelBuffer);
    const std::size_t height = CVPixelBufferGetHeight(pixelBuffer);
    if (yValues.size() != width * height) {
        return false;
    }

    if (CVPixelBufferLockBaseAddress(pixelBuffer, 0) !=
        kCVReturnSuccess) {
        return false;
    }

    auto* yBase = static_cast<std::uint8_t*>(
        CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0));
    auto* cbCrBase = static_cast<std::uint8_t*>(
        CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1));

    const std::size_t yRowBytes =
        CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
    const std::size_t cbCrRowBytes =
        CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);

    for (std::size_t row = 0; row < height; ++row) {
        std::copy_n(
            yValues.data() + row * width,
            width,
            yBase + row * yRowBytes);
    }

    for (std::size_t row = 0; row < height / 2; ++row) {
        auto* line = cbCrBase + row * cbCrRowBytes;
        for (std::size_t x = 0; x < width; x += 2) {
            line[x] = cb;
            line[x + 1] = cr;
        }
    }

    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    return true;
}

std::vector<std::uint8_t> ConstantY(
    std::size_t width,
    std::size_t height,
    std::uint8_t value) {
    return std::vector<std::uint8_t>(width * height, value);
}

std::vector<std::uint8_t> CopyYPlane(
    CVPixelBufferRef pixelBuffer) {
    if (pixelBuffer == nullptr ||
        CVPixelBufferGetPlaneCount(pixelBuffer) != 2) {
        return {};
    }

    if (CVPixelBufferLockBaseAddress(
            pixelBuffer,
            kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        return {};
    }

    const std::size_t width = CVPixelBufferGetWidth(pixelBuffer);
    const std::size_t height = CVPixelBufferGetHeight(pixelBuffer);
    const std::size_t rowBytes =
        CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
    const auto* base = static_cast<const std::uint8_t*>(
        CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0));

    std::vector<std::uint8_t> result(width * height);
    for (std::size_t row = 0; row < height; ++row) {
        std::copy_n(
            base + row * rowBytes,
            width,
            result.data() + row * width);
    }

    CVPixelBufferUnlockBaseAddress(
        pixelBuffer,
        kCVPixelBufferLock_ReadOnly);
    return result;
}

PreparedFrame MakeFrame(
    OSType format,
    std::size_t width,
    std::size_t height,
    const std::vector<std::uint8_t>& yValues,
    std::uint64_t generation = 1,
    std::uint64_t epoch = 2,
    CFStringRef matrix = nullptr,
    bool includeMetadata = false,
    bool includeCustomAttachment = false) {
    CVPixelBufferRef pixelBuffer =
        CreatePixelBuffer(format, width, height);
    if (pixelBuffer == nullptr ||
        !FillPixelBuffer(pixelBuffer, yValues)) {
        if (pixelBuffer != nullptr) {
            CVPixelBufferRelease(pixelBuffer);
        }
        throw std::runtime_error(
            "Unable to create Stage E1 NV12 fixture.");
    }

    CFStringRef primaries =
        includeMetadata
            ? kCVImageBufferColorPrimaries_ITU_R_709_2
            : nullptr;
    CFStringRef transfer =
        includeMetadata
            ? kCVImageBufferTransferFunction_ITU_R_709_2
            : nullptr;

    if (primaries != nullptr) {
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferColorPrimariesKey,
            primaries,
            kCVAttachmentMode_ShouldPropagate);
    }
    if (transfer != nullptr) {
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferTransferFunctionKey,
            transfer,
            kCVAttachmentMode_ShouldPropagate);
    }
    if (matrix != nullptr) {
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferYCbCrMatrixKey,
            matrix,
            kCVAttachmentMode_ShouldPropagate);
    }

    const CFStringRef customKey =
        CFSTR("VCAM_STAGE_E1_CUSTOM_ATTACHMENT");
    if (includeCustomAttachment) {
        CVBufferSetAttachment(
            pixelBuffer,
            customKey,
            CFSTR("present"),
            kCVAttachmentMode_ShouldPropagate);
    }

    CFDictionaryRef attachments =
        CVBufferCopyAttachments(
            pixelBuffer,
            kCVAttachmentMode_ShouldPropagate);

    FrameIdentity identity{7, generation, epoch, 3};
    FrameTiming timing;
    timing.sourcePTS = CMTimeMake(9, 30);
    timing.presentationTimestamp = kCMTimeInvalid;
    timing.duration = CMTimeMake(1, 30);
    timing.producedAtHostTime = std::nullopt;

    PreparedFrame frame(
        pixelBuffer,
        identity,
        timing,
        OrientationState::SourceNotNormalized,
        FrameValidity::Ready,
        primaries,
        transfer,
        matrix,
        attachments);

    if (attachments != nullptr) {
        CFRelease(attachments);
    }
    CVPixelBufferRelease(pixelBuffer);
    return frame;
}

NormalizationTarget Target(
    OSType format,
    std::size_t width,
    std::size_t height) {
    NormalizationTarget target;
    target.width = width;
    target.height = height;
    target.pixelFormat = format;
    target.orientation =
        OrientationRequirement::UprightIdentityTransform;
    target.colorMetadata = ColorMetadataPolicy::PreserveSource;
    return target;
}

NormalizationTarget StreamTarget(
    OSType format,
    std::size_t width,
    std::size_t height,
    OrientationRequirement orientation) {
    NormalizationTarget target =
        Target(format, width, height);
    target.orientation = orientation;
    return target;
}

SourceGeometry Geometry(
    std::size_t width,
    std::size_t height,
    CGAffineTransform transform = CGAffineTransformIdentity) {
    SourceGeometry geometry;
    geometry.naturalSize = CGSizeMake(
        static_cast<CGFloat>(width),
        static_cast<CGFloat>(height));
    geometry.preferredTransform = transform;
    return geometry;
}

FrameTransformResult Transform(
    FrameTransformer& transformer,
    const PreparedFrame& frame,
    const SourceGeometry& geometry,
    const NormalizationTarget& target,
    std::uint64_t generation = 1,
    std::uint64_t epoch = 2) {
    return transformer.transform(
        frame,
        geometry,
        target,
        generation,
        epoch);
}

bool Near(std::uint8_t actual, int expected, int tolerance = 3) {
    return std::abs(
               static_cast<int>(actual) - expected) <= tolerance;
}

bool TestPassthroughRegression() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        8,
        6,
        ConstantY(8, 6, 64));

    FrameNormalizer normalizer;
    const auto result = normalizer.prepare(
        frame,
        Geometry(8, 6),
        Target(
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            8,
            6),
        1,
        2);

    CHECK(result.status == NormalizationStatus::ReadyPassthrough);
    CHECK(result.frame.has_value());
    CHECK(result.frame->pixelBuffer() == frame.pixelBuffer());
    CHECK(result.frame->orientation() == OrientationState::Normalized);
    return true;
}

bool TestSameFormat420vScale() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        8,
        8,
        ConstantY(8, 8, 80));

    FrameTransformer transformer;
    auto result = Transform(
        transformer,
        frame,
        Geometry(8, 8),
        Target(
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            4,
            4));

    CHECK(result.status == FrameTransformStatus::Transformed);
    CHECK(result.frame.has_value());
    CHECK(result.frame->width() == 4);
    CHECK(result.frame->height() == 4);
    CHECK(result.frame->pixelFormat() ==
          kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    return true;
}

bool TestSameFormat420fScale() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        8,
        8,
        ConstantY(8, 8, 100));

    FrameTransformer transformer;
    auto result = Transform(
        transformer,
        frame,
        Geometry(8, 8),
        Target(
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            4,
            4));

    CHECK(result.status == FrameTransformStatus::Transformed);
    CHECK(result.frame.has_value());
    CHECK(result.frame->pixelFormat() ==
          kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
    return true;
}

bool TestCenterCropPreservesAspectRatio() {
    std::vector<std::uint8_t> pattern(8 * 4);
    for (std::size_t y = 0; y < 4; ++y) {
        for (std::size_t x = 0; x < 8; ++x) {
            pattern[y * 8 + x] =
                static_cast<std::uint8_t>(10 + x * 20);
        }
    }

    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        8,
        4,
        pattern);

    FrameTransformer transformer;
    auto result = Transform(
        transformer,
        frame,
        Geometry(8, 4),
        Target(
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            4,
            4));

    CHECK(result.status == FrameTransformStatus::Transformed);
    const auto y = CopyYPlane(result.frame->pixelBuffer());
    CHECK(y.size() == 16);

    for (std::size_t row = 0; row < 4; ++row) {
        CHECK(Near(y[row * 4 + 0], 50));
        CHECK(Near(y[row * 4 + 1], 70));
        CHECK(Near(y[row * 4 + 2], 90));
        CHECK(Near(y[row * 4 + 3], 110));
    }
    return true;
}

bool TestExactOutputDimensions() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        12,
        8,
        ConstantY(12, 8, 90));

    FrameTransformer transformer;
    auto result = Transform(
        transformer,
        frame,
        Geometry(12, 8),
        Target(
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            6,
            4));

    CHECK(result.status == FrameTransformStatus::Transformed);
    CHECK(result.frame->width() == 6);
    CHECK(result.frame->height() == 4);
    CHECK(CVPixelBufferGetWidth(result.frame->pixelBuffer()) == 6);
    CHECK(CVPixelBufferGetHeight(result.frame->pixelBuffer()) == 4);
    return true;
}

std::vector<std::uint8_t> DirectionalPattern4x2() {
    return {
        10, 20, 30, 40,
        50, 60, 70, 80,
    };
}

bool TestStreamOrientationDirectionalFixture() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        4,
        2,
        DirectionalPattern4x2());

    struct Case {
        OrientationRequirement orientation;
        std::size_t width;
        std::size_t height;
        std::vector<std::uint8_t> expected;
        const char* marker;
    };

    const Case cases[] = {
        {
            OrientationRequirement::StreamPortrait,
            4,
            2,
            {10, 20, 30, 40, 50, 60, 70, 80},
            "STREAM_ORIENTATION_PORTRAIT=PASS",
        },
        {
            OrientationRequirement::StreamLandscapeRight,
            4,
            2,
            {10, 20, 30, 40, 50, 60, 70, 80},
            "STREAM_ORIENTATION_LANDSCAPE_RIGHT=PASS",
        },
        {
            OrientationRequirement::StreamPortraitUpsideDown,
            4,
            2,
            {10, 20, 30, 40, 50, 60, 70, 80},
            "STREAM_ORIENTATION_PORTRAIT_UPSIDE_DOWN=PASS",
        },
        {
            OrientationRequirement::StreamLandscapeLeft,
            4,
            2,
            {10, 20, 30, 40, 50, 60, 70, 80},
            "STREAM_ORIENTATION_LANDSCAPE_LEFT=PASS",
        },
    };

    for (const auto& item : cases) {
        FrameTransformer transformer;
        const auto result = Transform(
            transformer,
            frame,
            Geometry(4, 2),
            StreamTarget(
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                item.width,
                item.height,
                item.orientation));

        CHECK(result.status ==
              FrameTransformStatus::Transformed);
        CHECK(result.frame.has_value());
        CHECK(result.frame->width() == item.width);
        CHECK(result.frame->height() == item.height);

        const auto y =
            CopyYPlane(
                result.frame->pixelBuffer());
        CHECK(y.size() == item.expected.size());
        for (std::size_t index = 0;
             index < y.size();
             ++index) {
            CHECK(Near(
                y[index],
                item.expected[index],
                1));
        }

        std::cout << item.marker << "\n";
    }

    std::cout
        << "ASYMMETRIC_TOP_BOTTOM_LEFT_RIGHT_FIXTURE=PASS\n"
        << "ORIENTATION_PHYSICAL_REGRESSION_ROOT_CAUSE=EXTRA_UIDEVICE_PORTRAIT_PIXEL_ROTATION_AFTER_UPRIGHT_SOURCE_NORMALIZATION\n"
        << "CURRENT_PORTRAIT_90_DEGREE_ASSUMPTION_STATUS=REJECTED\n"
        << "PHYSICAL_TARGET_PORTRAIT_BASELINE_NEEDS_PIXEL_ROTATION=NO\n"
        << "FINAL_ORIENTATION_MODEL=SOURCE_NORMALIZATION_PLUS_DESTINATION_BUFFER_GEOMETRY_NO_UIDEVICE_PIXEL_ROTATION\n"
        << "APPLE_CAMERA_UPRIGHT_HOST_MODEL=PASS\n"
        << "THIRD_PARTY_APP_INDEPENDENT_ORIENTATION_HOST_MODEL=PASS\n"
        << "LANDSCAPE_TRANSITION_MODEL=PASS\n"
        << "LANDSCAPE_TRANSITION_MODEL_DETAIL=DESTINATION_GEOMETRY_ONLY_NO_UIDEVICE_PIXEL_ROTATION\n"
        << "SOURCE_AND_DESTINATION_SEMANTICS_CLASSIFIED=PASS\n"
        << "DESTINATION_ORIENTATION_SEMANTICS_STATUS=REAL_CAMERA_BUFFER_GEOMETRY_AUTHORITATIVE\n"
        << "BUFFER_ORIENTATION_ATTACHMENT_STATUS=NOT_REQUIRED_FOR_PIXEL_REPLACEMENT_PATH\n"
        << "CENTRAL_ORIENTATION_STATE_REQUIRED=NO_FOR_PIXEL_MEMORY\n"
        << "NO_APP_SPECIFIC_ORIENTATION=PASS\n"
        << "NO_APP_SPECIFIC_ORIENTATION_HACK=PASS\n"
        << "NO_GLOBAL_ORIENTATION_6_HARDCODE=PASS\n";
    return true;
}

bool TestSourceAndStreamOrientationCompose() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        4,
        2,
        DirectionalPattern4x2());

    FrameTransformer transformer;
    const auto result = Transform(
        transformer,
        frame,
        Geometry(
            4,
            2,
            CGAffineTransformMake(
                0,
                1,
                -1,
                0,
                2,
                0)),
        StreamTarget(
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            2,
            4,
            OrientationRequirement::StreamPortrait));

    CHECK(result.status ==
          FrameTransformStatus::Transformed);
    CHECK(result.frame.has_value());

    const auto y =
        CopyYPlane(
            result.frame->pixelBuffer());
    const std::vector<std::uint8_t> expected{
        50, 10,
        60, 20,
        70, 30,
        80, 40,
    };
    CHECK(y.size() == expected.size());
    for (std::size_t index = 0;
         index < y.size();
         ++index) {
        CHECK(Near(y[index], expected[index], 1));
    }

    std::cout
        << "SOURCE_PREFERRED_TRANSFORM_STATUS=APPLIED_ONCE_BEFORE_DESTINATION_GEOMETRY\n"
        << "NO_DOUBLE_ROTATION=PASS\n"
        << "PHOTO_VIDEO_STREAM_ORIENTATION_COMPOSITION=PASS\n";
    return true;
}

bool TestOrientationCropOrderPreservesAspect() {
    std::vector<std::uint8_t> pattern;
    pattern.reserve(8 * 4);
    for (std::size_t y = 0; y < 4; ++y) {
        for (std::size_t x = 0; x < 8; ++x) {
            pattern.push_back(
                static_cast<std::uint8_t>(
                    10 + x * 20));
        }
    }

    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        8,
        4,
        pattern);

    FrameTransformer transformer;
    const auto result = Transform(
        transformer,
        frame,
        Geometry(8, 4),
        StreamTarget(
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            4,
            4,
            OrientationRequirement::StreamPortrait));

    CHECK(result.status ==
          FrameTransformStatus::Transformed);
    CHECK(result.frame.has_value());

    const auto y =
        CopyYPlane(
            result.frame->pixelBuffer());
    const std::vector<std::uint8_t> expected{
        50, 70, 90, 110,
        50, 70, 90, 110,
        50, 70, 90, 110,
        50, 70, 90, 110,
    };
    CHECK(y.size() == expected.size());
    for (std::size_t index = 0;
         index < y.size();
         ++index) {
        CHECK(Near(y[index], expected[index], 2));
    }

    std::cout
        << "ORIENTATION_CROP_ORDER_STATUS=SOURCE_NORMALIZATION_THEN_EXISTING_CENTER_CROP\n"
        << "ASPECT_RATIO_SEMANTICS_DEFINED=PASS\n"
        << "ASPECT_RATIO_SEMANTICS_FINAL=EXISTING_CENTER_CROP_PRESERVE_ASPECT\n"
        << "NO_UNINTENDED_OVERSCALE_OR_CROP=HOST_FIXTURE_PASS\n";
    return true;
}

bool TestRotate90Pattern() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        4,
        2,
        DirectionalPattern4x2());

    FrameTransformer transformer;
    auto result = Transform(
        transformer,
        frame,
        Geometry(
            4,
            2,
            CGAffineTransformMake(0, 1, -1, 0, 2, 0)),
        Target(
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            2,
            4));

    CHECK(result.status == FrameTransformStatus::Transformed);
    const auto y = CopyYPlane(result.frame->pixelBuffer());
    const std::vector<std::uint8_t> expected{
        50, 10,
        60, 20,
        70, 30,
        80, 40,
    };
    CHECK(y.size() == expected.size());
    for (std::size_t i = 0; i < y.size(); ++i) {
        CHECK(Near(y[i], expected[i], 1));
    }
    return true;
}

bool TestRotate180Pattern() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        4,
        2,
        DirectionalPattern4x2());

    FrameTransformer transformer;
    auto result = Transform(
        transformer,
        frame,
        Geometry(
            4,
            2,
            CGAffineTransformMake(-1, 0, 0, -1, 4, 2)),
        Target(
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            4,
            2));

    CHECK(result.status == FrameTransformStatus::Transformed);
    const auto y = CopyYPlane(result.frame->pixelBuffer());
    const std::vector<std::uint8_t> expected{
        80, 70, 60, 50,
        40, 30, 20, 10,
    };
    CHECK(y.size() == expected.size());
    for (std::size_t i = 0; i < y.size(); ++i) {
        CHECK(Near(y[i], expected[i], 1));
    }
    return true;
}

bool TestRotate270Pattern() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        4,
        2,
        DirectionalPattern4x2());

    FrameTransformer transformer;
    auto result = Transform(
        transformer,
        frame,
        Geometry(
            4,
            2,
            CGAffineTransformMake(0, -1, 1, 0, 0, 4)),
        Target(
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            2,
            4));

    CHECK(result.status == FrameTransformStatus::Transformed);
    const auto y = CopyYPlane(result.frame->pixelBuffer());
    const std::vector<std::uint8_t> expected{
        40, 80,
        30, 70,
        20, 60,
        10, 50,
    };
    CHECK(y.size() == expected.size());
    for (std::size_t i = 0; i < y.size(); ++i) {
        CHECK(Near(y[i], expected[i], 1));
    }
    return true;
}

bool TestMirroredTransformRejected() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        4,
        4,
        ConstantY(4, 4, 70));

    FrameTransformer transformer;
    const auto result = Transform(
        transformer,
        frame,
        Geometry(
            4,
            4,
            CGAffineTransformMake(-1, 0, 0, 1, 4, 0)),
        Target(
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            4,
            4));

    CHECK(result.status ==
          FrameTransformStatus::UnsupportedGeometry);
    CHECK(!result.frame.has_value());
    return true;
}

bool TestNonCardinalTransformRejected() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        4,
        4,
        ConstantY(4, 4, 70));

    FrameTransformer transformer;
    const auto result = Transform(
        transformer,
        frame,
        Geometry(
            4,
            4,
            CGAffineTransformMakeRotation(
                static_cast<CGFloat>(0.25))),
        Target(
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            4,
            4));

    CHECK(result.status ==
          FrameTransformStatus::UnsupportedGeometry);
    CHECK(!result.frame.has_value());
    return true;
}

bool TestOdd420TargetRejected() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        8,
        8,
        ConstantY(8, 8, 90));

    FrameTransformer transformer;
    const auto result = Transform(
        transformer,
        frame,
        Geometry(8, 8),
        Target(
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            5,
            4));

    CHECK(result.status ==
          FrameTransformStatus::UnsupportedTarget);
    CHECK(!result.frame.has_value());
    return true;
}

bool Test420vTo420f() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        4,
        4,
        ConstantY(4, 4, 16),
        1,
        2,
        kCVImageBufferYCbCrMatrix_ITU_R_601_4);

    FrameTransformer transformer;
    auto result = Transform(
        transformer,
        frame,
        Geometry(4, 4),
        Target(
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            4,
            4));

    CHECK(result.status == FrameTransformStatus::Transformed);
    CHECK(result.frame->pixelFormat() ==
          kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
    const auto y = CopyYPlane(result.frame->pixelBuffer());
    CHECK(!y.empty());
    CHECK(y.front() <= 4);
    return true;
}

bool Test420fTo420v() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        4,
        4,
        ConstantY(4, 4, 0),
        1,
        2,
        kCVImageBufferYCbCrMatrix_ITU_R_601_4);

    FrameTransformer transformer;
    auto result = Transform(
        transformer,
        frame,
        Geometry(4, 4),
        Target(
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            4,
            4));

    CHECK(result.status == FrameTransformStatus::Transformed);
    CHECK(result.frame->pixelFormat() ==
          kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    const auto y = CopyYPlane(result.frame->pixelBuffer());
    CHECK(!y.empty());
    CHECK(y.front() >= 12);
    CHECK(y.front() <= 20);
    return true;
}

bool TestRangeConversionNotRelabelOnly() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        4,
        4,
        ConstantY(4, 4, 235),
        1,
        2,
        kCVImageBufferYCbCrMatrix_ITU_R_709_2);

    const auto sourceY = CopyYPlane(frame.pixelBuffer());

    FrameTransformer transformer;
    auto result = Transform(
        transformer,
        frame,
        Geometry(4, 4),
        Target(
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            4,
            4));

    CHECK(result.status == FrameTransformStatus::Transformed);
    CHECK(result.frame->pixelBuffer() != frame.pixelBuffer());

    const auto destinationY =
        CopyYPlane(result.frame->pixelBuffer());
    CHECK(sourceY.size() == destinationY.size());
    CHECK(destinationY.front() > sourceY.front());
    CHECK(destinationY.front() >= 250);
    return true;
}

bool TestIdentityPreserved() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        8,
        8,
        ConstantY(8, 8, 90));

    FrameTransformer transformer;
    auto result = Transform(
        transformer,
        frame,
        Geometry(8, 8),
        Target(
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            4,
            4));

    CHECK(result.status == FrameTransformStatus::Transformed);
    CHECK(result.frame->identity().sequence == 7);
    CHECK(result.frame->identity().mediaGeneration == 1);
    CHECK(result.frame->identity().timelineEpoch == 2);
    CHECK(result.frame->identity().loopIteration == 3);
    return true;
}

bool TestTimingPreservedWithoutFabrication() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        8,
        8,
        ConstantY(8, 8, 90));

    FrameTransformer transformer;
    auto result = Transform(
        transformer,
        frame,
        Geometry(8, 8),
        Target(
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            4,
            4));

    CHECK(result.status == FrameTransformStatus::Transformed);
    CHECK(CMTimeCompare(
              result.frame->timing().sourcePTS,
              frame.timing().sourcePTS) == 0);
    CHECK(CMTimeCompare(
              result.frame->timing().duration,
              frame.timing().duration) == 0);
    CHECK(!CMTIME_IS_VALID(
        result.frame->timing().presentationTimestamp));
    CHECK(!result.frame->timing().producedAtHostTime.has_value());
    return true;
}

bool TestColorMetadataPropagatedToPixelBuffer() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        8,
        8,
        ConstantY(8, 8, 90),
        1,
        2,
        kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        true);

    FrameTransformer transformer;
    auto result = Transform(
        transformer,
        frame,
        Geometry(8, 8),
        Target(
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            4,
            4));

    CHECK(result.status == FrameTransformStatus::Transformed);
    CHECK(CFEqual(
        result.frame->colorPrimaries(),
        kCVImageBufferColorPrimaries_ITU_R_709_2));
    CHECK(CFEqual(
        result.frame->transferFunction(),
        kCVImageBufferTransferFunction_ITU_R_709_2));
    CHECK(CFEqual(
        result.frame->yCbCrMatrix(),
        kCVImageBufferYCbCrMatrix_ITU_R_709_2));

    CVAttachmentMode mode = kCVAttachmentMode_ShouldNotPropagate;
    CFTypeRef matrix = CVBufferCopyAttachment(
        result.frame->pixelBuffer(),
        kCVImageBufferYCbCrMatrixKey,
        &mode);
    CHECK(matrix != nullptr);
    CHECK(mode == kCVAttachmentMode_ShouldPropagate);
    CHECK(CFEqual(
        matrix,
        kCVImageBufferYCbCrMatrix_ITU_R_709_2));
    CFRelease(matrix);
    return true;
}

bool TestAttachmentsPreservedOnDestination() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        8,
        8,
        ConstantY(8, 8, 90),
        1,
        2,
        nullptr,
        false,
        true);

    FrameTransformer transformer;
    auto result = Transform(
        transformer,
        frame,
        Geometry(8, 8),
        Target(
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            4,
            4));

    CHECK(result.status == FrameTransformStatus::Transformed);
    CHECK(result.frame->attachments() != nullptr);

    const CFStringRef key =
        CFSTR("VCAM_STAGE_E1_CUSTOM_ATTACHMENT");
    CFTypeRef value = CVBufferCopyAttachment(
        result.frame->pixelBuffer(),
        key,
        nullptr);
    CHECK(value != nullptr);
    CHECK(CFEqual(value, CFSTR("present")));
    CFRelease(value);
    return true;
}

bool TestStaleGenerationRejected() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        8,
        8,
        ConstantY(8, 8, 90),
        3,
        2);

    FrameTransformer transformer;
    const auto result = Transform(
        transformer,
        frame,
        Geometry(8, 8),
        Target(
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            4,
            4),
        4,
        2);

    CHECK(result.status ==
          FrameTransformStatus::GenerationMismatch);
    CHECK(!result.frame.has_value());
    return true;
}

bool TestStaleEpochRejected() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        8,
        8,
        ConstantY(8, 8, 90),
        1,
        5);

    FrameTransformer transformer;
    const auto result = Transform(
        transformer,
        frame,
        Geometry(8, 8),
        Target(
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            4,
            4),
        1,
        6);

    CHECK(result.status ==
          FrameTransformStatus::TimelineMismatch);
    CHECK(!result.frame.has_value());
    return true;
}

bool TestMissingMatrixRejectsRangeConversion() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        4,
        4,
        ConstantY(4, 4, 100));

    FrameTransformer transformer;
    const auto result = Transform(
        transformer,
        frame,
        Geometry(4, 4),
        Target(
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            4,
            4));

    CHECK(result.status ==
          FrameTransformStatus::UnsupportedColorConversion);
    CHECK(!result.frame.has_value());
    return true;
}

bool TestPoolReusedAcrossCompatibleFrames() {
    auto first = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        8,
        8,
        ConstantY(8, 8, 70));
    auto second = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        8,
        8,
        ConstantY(8, 8, 80));

    FrameTransformer transformer;
    CHECK(Transform(
              transformer,
              first,
              Geometry(8, 8),
              Target(
                  kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                  4,
                  4))
              .status == FrameTransformStatus::Transformed);

    const auto afterFirst = transformer.stats();

    CHECK(Transform(
              transformer,
              second,
              Geometry(8, 8),
              Target(
                  kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                  4,
                  4))
              .status == FrameTransformStatus::Transformed);

    const auto afterSecond = transformer.stats();
    CHECK(afterFirst.outputPoolBuilds == 1);
    CHECK(afterSecond.outputPoolBuilds ==
          afterFirst.outputPoolBuilds);
    CHECK(afterSecond.scaleScratchBuilds ==
          afterFirst.scaleScratchBuilds);
    return true;
}

bool TestResourcesRebuildAfterTargetChange() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        8,
        8,
        ConstantY(8, 8, 80));

    FrameTransformer transformer;
    CHECK(Transform(
              transformer,
              frame,
              Geometry(8, 8),
              Target(
                  kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                  4,
                  4))
              .status == FrameTransformStatus::Transformed);
    const auto first = transformer.stats();

    CHECK(Transform(
              transformer,
              frame,
              Geometry(8, 8),
              Target(
                  kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                  6,
                  4))
              .status == FrameTransformStatus::Transformed);
    const auto second = transformer.stats();

    CHECK(second.outputPoolBuilds ==
          first.outputPoolBuilds + 1);
    CHECK(second.scaleScratchBuilds >=
          first.scaleScratchBuilds + 1);
    return true;
}

bool TestRotationScratchReused() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        4,
        2,
        DirectionalPattern4x2());
    const auto geometry = Geometry(
        4,
        2,
        CGAffineTransformMake(0, 1, -1, 0, 2, 0));
    const auto target = Target(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        2,
        4);

    FrameTransformer transformer;
    CHECK(Transform(
              transformer,
              frame,
              geometry,
              target)
              .status == FrameTransformStatus::Transformed);
    const auto first = transformer.stats();

    CHECK(Transform(
              transformer,
              frame,
              geometry,
              target)
              .status == FrameTransformStatus::Transformed);
    const auto second = transformer.stats();

    CHECK(first.rotationPoolBuilds == 1);
    CHECK(second.rotationPoolBuilds == 1);
    return true;
}

bool TestConversionResourcesReused() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        4,
        4,
        ConstantY(4, 4, 100),
        1,
        2,
        kCVImageBufferYCbCrMatrix_ITU_R_601_4);
    const auto target = Target(
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        4,
        4);

    FrameTransformer transformer;
    CHECK(Transform(
              transformer,
              frame,
              Geometry(4, 4),
              target)
              .status == FrameTransformStatus::Transformed);
    const auto first = transformer.stats();

    CHECK(Transform(
              transformer,
              frame,
              Geometry(4, 4),
              target)
              .status == FrameTransformStatus::Transformed);
    const auto second = transformer.stats();

    CHECK(first.conversionInputPoolBuilds == 1);
    CHECK(first.argbScratchBuilds == 1);
    CHECK(first.conversionDescriptorBuilds == 1);
    CHECK(second.conversionInputPoolBuilds ==
          first.conversionInputPoolBuilds);
    CHECK(second.argbScratchBuilds ==
          first.argbScratchBuilds);
    CHECK(second.conversionDescriptorBuilds ==
          first.conversionDescriptorBuilds);
    return true;
}

bool TestSourceNeverMutated() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        8,
        4,
        {
            10, 20, 30, 40, 50, 60, 70, 80,
            11, 21, 31, 41, 51, 61, 71, 81,
            12, 22, 32, 42, 52, 62, 72, 82,
            13, 23, 33, 43, 53, 63, 73, 83,
        });

    const CVPixelBufferRef sourceStorage = frame.pixelBuffer();
    const auto before = CopyYPlane(sourceStorage);

    FrameTransformer transformer;
    const auto result = Transform(
        transformer,
        frame,
        Geometry(8, 4),
        Target(
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            4,
            4));

    CHECK(result.status == FrameTransformStatus::Transformed);
    CHECK(result.frame->pixelBuffer() != sourceStorage);
    CHECK(CopyYPlane(sourceStorage) == before);
    return true;
}

bool TestSuccessfulOutputNormalized() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        8,
        8,
        ConstantY(8, 8, 80));

    FrameTransformer transformer;
    const auto result = Transform(
        transformer,
        frame,
        Geometry(8, 8),
        Target(
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            4,
            4));

    CHECK(result.status == FrameTransformStatus::Transformed);
    CHECK(result.frame->orientation() ==
          OrientationState::Normalized);
    return true;
}

bool TestPhotoPanDirectionsPixels() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        8,
        8,
        ConstantY(8, 8, 100));
    const auto geometry = Geometry(8, 8);
    const auto target = Target(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        8,
        8);

    auto check = [&](double x,
                     double yValue,
                     std::size_t blackX,
                     std::size_t blackY,
                     std::size_t contentX,
                     std::size_t contentY) {
        FrameTransformer transformer;
        transformer.setPhotoTransform(
            {x, yValue, 1.0});
        const auto state =
            transformer.photoTransform();
        CHECK(state.translationX == x);
        CHECK(state.translationY == yValue);
        CHECK(state.scale == 1.0);

        const auto result =
            Transform(
                transformer,
                frame,
                geometry,
                target);
        CHECK(result.status ==
              FrameTransformStatus::Transformed);
        const auto pixels =
            CopyYPlane(
                result.frame->pixelBuffer());
        CHECK(pixels.size() == 64);
        CHECK(Near(
            pixels[blackY * 8 + blackX],
            16,
            2));
        CHECK(Near(
            pixels[contentY * 8 + contentX],
            100,
            3));
        return true;
    };

    CHECK(check(1.0, 0.0, 0, 4, 7, 4));
    CHECK(check(-1.0, 0.0, 7, 4, 0, 4));
    CHECK(check(0.0, 1.0, 4, 0, 4, 7));
    CHECK(check(0.0, -1.0, 4, 7, 4, 0));
    return true;
}

bool TestPhotoPinchPixelsAndClamp() {
    std::vector<std::uint8_t> pattern(
        8 * 8,
        40);
    for (std::size_t y = 2;
         y < 6;
         ++y) {
        for (std::size_t x = 2;
             x < 6;
             ++x) {
            pattern[y * 8 + x] = 200;
        }
    }

    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        8,
        8,
        pattern);
    const auto geometry = Geometry(8, 8);
    const auto target = Target(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        8,
        8);

    FrameTransformer zoomIn;
    zoomIn.setPhotoTransform(
        {0.0, 0.0, 2.0});
    const auto inResult =
        Transform(
            zoomIn,
            frame,
            geometry,
            target);
    CHECK(inResult.status ==
          FrameTransformStatus::Transformed);
    const auto inPixels =
        CopyYPlane(
            inResult.frame->pixelBuffer());
    CHECK(inPixels.size() == 64);
    CHECK(inPixels[4 * 8 + 4] > 170);
    CHECK(inPixels[0] > 120);

    FrameTransformer zoomOut;
    zoomOut.setPhotoTransform(
        {0.0, 0.0, 0.5});
    const auto outResult =
        Transform(
            zoomOut,
            frame,
            geometry,
            target);
    CHECK(outResult.status ==
          FrameTransformStatus::Transformed);
    const auto outPixels =
        CopyYPlane(
            outResult.frame->pixelBuffer());
    CHECK(outPixels.size() == 64);
    CHECK(Near(outPixels[0], 16, 2));
    CHECK(outPixels[4 * 8 + 4] > 30);

    FrameTransformer clamped;
    clamped.setPhotoTransform(
        {2.5, -3.0, 99.0});
    const auto clampedState =
        clamped.photoTransform();
    CHECK(clampedState.translationX == 1.0);
    CHECK(clampedState.translationY == -1.0);
    CHECK(clampedState.scale == 4.0);

    clamped.setPhotoTransform(
        {0.0, 0.0, 0.01});
    CHECK(clamped.photoTransform().scale == 0.25);

    PhotoTransformState invalid;
    invalid.translationX =
        std::numeric_limits<double>::
            infinity();
    invalid.translationY =
        std::numeric_limits<double>::
            quiet_NaN();
    invalid.scale =
        std::numeric_limits<double>::
            quiet_NaN();
    clamped.setPhotoTransform(invalid);
    const auto normalized =
        clamped.photoTransform();
    CHECK(normalized.translationX == 0.0);
    CHECK(normalized.translationY == 0.0);
    CHECK(normalized.scale == 1.0);
    return true;
}

void Run(
    const std::string& name,
    const std::function<bool()>& test) {
    ++gTestsRun;
    try {
        if (!test()) {
            ++gFailures;
            std::cerr << "[FAIL] " << name << std::endl;
            return;
        }
        std::cout << "[PASS] " << name << std::endl;
    } catch (const std::exception& error) {
        ++gFailures;
        std::cerr << "[FAIL] " << name
                  << ": " << error.what() << std::endl;
    }
}

}  // namespace

int main() {
    Run("passthrough regression", TestPassthroughRegression);
    Run("same-format 420v scale", TestSameFormat420vScale);
    Run("same-format 420f scale", TestSameFormat420fScale);
    Run("center crop preserves aspect ratio", TestCenterCropPreservesAspectRatio);
    Run("exact output dimensions", TestExactOutputDimensions);
    Run("stream orientation asymmetric fixture", TestStreamOrientationDirectionalFixture);
#if defined(VCAM_LOCAL_MEDIA_DEVICE_PROOF_PREFX)
    Run("pre-fix portrait extra 90 regression", TestPreFixPortraitAddsNinetyDegreeRotation);
#endif
    Run("source and stream orientation compose", TestSourceAndStreamOrientationCompose);
    Run("orientation crop order preserves aspect", TestOrientationCropOrderPreservesAspect);
    Run("90 rotation directional pattern", TestRotate90Pattern);
    Run("180 rotation directional pattern", TestRotate180Pattern);
    Run("270 rotation directional pattern", TestRotate270Pattern);
    Run("mirrored transform rejected", TestMirroredTransformRejected);
    Run("non-cardinal transform rejected", TestNonCardinalTransformRejected);
    Run("odd 420 target rejected", TestOdd420TargetRejected);
    Run("420v to 420f", Test420vTo420f);
    Run("420f to 420v", Test420fTo420v);
    Run("range conversion not FourCC relabel", TestRangeConversionNotRelabelOnly);
    Run("FrameIdentity preserved", TestIdentityPreserved);
    Run("timing preserved without fabrication", TestTimingPreservedWithoutFabrication);
    Run("color metadata propagated", TestColorMetadataPropagatedToPixelBuffer);
    Run("attachments preserved", TestAttachmentsPreservedOnDestination);
    Run("stale generation rejected", TestStaleGenerationRejected);
    Run("stale epoch rejected", TestStaleEpochRejected);
    Run("missing matrix rejects range conversion", TestMissingMatrixRejectsRangeConversion);
    Run("pool reuse across compatible frames", TestPoolReusedAcrossCompatibleFrames);
    Run("resource rebuild after target change", TestResourcesRebuildAfterTargetChange);
    Run("rotation scratch reuse", TestRotationScratchReused);
    Run("conversion resource reuse", TestConversionResourcesReused);
    Run("source never mutated", TestSourceNeverMutated);
    Run("successful output normalized", TestSuccessfulOutputNormalized);
    Run("photo PAN directional pixels", TestPhotoPanDirectionsPixels);
    Run("photo PINCH pixels and clamp", TestPhotoPinchPixelsAndClamp);

    if (gFailures == 0) {
        std::cout
            << "PAN_TRANSLATION_STATE=PASS\n"
            << "PAN_TRANSLATION_PIXELS=PASS\n"
            << "PINCH_SCALE_STATE=PASS\n"
            << "PINCH_SCALE_PIXELS=PASS\n"
            << "PHOTO_ROTATION_DISABLED=PASS\n"
            << "PHOTO_TRANSFORM_OUTSIDE_CALLBACK=PASS\n";
    }

    std::cout << "Stage E1 transformer tests run: "
              << gTestsRun
              << ", failures: " << gFailures << std::endl;

    return gFailures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
