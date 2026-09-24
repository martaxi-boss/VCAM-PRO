#include "FrameNormalizer.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

#include <cstdlib>
#include <functional>
#include <iostream>
#include <optional>
#include <stdexcept>
#include <string>
#include <utility>

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
    std::size_t width = 8,
    std::size_t height = 6) {
    CVPixelBufferRef pixelBuffer = nullptr;
    const CVReturn result = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        format,
        nullptr,
        &pixelBuffer);
    return result == kCVReturnSuccess ? pixelBuffer : nullptr;
}

PreparedFrame MakeFrame(
    OSType format,
    std::size_t width = 8,
    std::size_t height = 6,
    std::uint64_t generation = 1,
    std::uint64_t epoch = 1,
    FrameValidity validity = FrameValidity::Ready,
    CFStringRef primaries = nullptr,
    CFStringRef transfer = nullptr,
    CFStringRef matrix = nullptr,
    CFDictionaryRef attachments = nullptr) {
    CVPixelBufferRef pixelBuffer =
        CreatePixelBuffer(format, width, height);
    if (pixelBuffer == nullptr) {
        throw std::runtime_error(
            "Unable to create CVPixelBuffer fixture.");
    }

    FrameIdentity identity{4, generation, epoch, 2};
    FrameTiming timing;
    timing.sourcePTS = CMTimeMake(4, 30);
    timing.presentationTimestamp = kCMTimeInvalid;
    timing.duration = CMTimeMake(1, 30);

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
    CVPixelBufferRelease(pixelBuffer);

    if (validity == FrameValidity::Invalidated) {
        frame.invalidate();
    } else if (validity == FrameValidity::Failed) {
        frame.markFailed();
    }

    return frame;
}

NormalizationTarget Target(
    OSType format,
    std::size_t width = 8,
    std::size_t height = 6,
    ColorMetadataPolicy colorPolicy =
        ColorMetadataPolicy::PreserveSource) {
    NormalizationTarget target;
    target.width = width;
    target.height = height;
    target.pixelFormat = format;
    target.orientation =
        OrientationRequirement::UprightIdentityTransform;
    target.colorMetadata = colorPolicy;
    return target;
}

SourceGeometry IdentityGeometry() {
    SourceGeometry geometry;
    geometry.naturalSize = CGSizeMake(8, 6);
    geometry.preferredTransform = CGAffineTransformIdentity;
    return geometry;
}

NormalizationResult Prepare(
    PreparedFrame& frame,
    const SourceGeometry& geometry,
    const NormalizationTarget& target,
    std::uint64_t generation = 1,
    std::uint64_t epoch = 1) {
    FrameNormalizer normalizer;
    return normalizer.prepare(
        frame,
        geometry,
        target,
        generation,
        epoch);
}

bool Test420vPassthrough() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    auto result = Prepare(
        frame,
        IdentityGeometry(),
        Target(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));

    CHECK(result.status == NormalizationStatus::ReadyPassthrough);
    CHECK(result.frame.has_value());
    CHECK(result.frame->orientation() == OrientationState::Normalized);
    return true;
}

bool Test420fPassthrough() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
    auto result = Prepare(
        frame,
        IdentityGeometry(),
        Target(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange));

    CHECK(result.status == NormalizationStatus::ReadyPassthrough);
    CHECK(result.frame.has_value());
    CHECK(result.frame->orientation() == OrientationState::Normalized);
    return true;
}

bool TestSamePixelStorageIdentity() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    CVPixelBufferRef sourceStorage = frame.pixelBuffer();

    auto result = Prepare(
        frame,
        IdentityGeometry(),
        Target(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));

    CHECK(result.frame.has_value());
    CHECK(result.frame->pixelBuffer() == sourceStorage);
    return true;
}

bool TestOutputOwnsStorageIndependently() {
    std::optional<PreparedFrame> output;
    CVPixelBufferRef expectedStorage = nullptr;

    {
        auto source = MakeFrame(
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
        expectedStorage = source.pixelBuffer();

        auto result = Prepare(
            source,
            IdentityGeometry(),
            Target(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));
        CHECK(result.frame.has_value());
        output.emplace(std::move(*result.frame));
    }

    CHECK(output.has_value());
    CHECK(output->pixelBuffer() == expectedStorage);
    CHECK(output->isInternallyConsistent());
    CHECK(CVPixelBufferGetWidth(output->pixelBuffer()) == 8);
    return true;
}

bool TestNormalizedOnlyForCompatiblePassthrough() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    auto result = Prepare(
        frame,
        IdentityGeometry(),
        Target(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));

    CHECK(result.status == NormalizationStatus::ReadyPassthrough);
    CHECK(result.frame->orientation() == OrientationState::Normalized);
    return true;
}

bool TestNonIdentityTransformRequiresTransform() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    SourceGeometry geometry = IdentityGeometry();
    geometry.preferredTransform =
        CGAffineTransformMake(0, 1, -1, 0, 0, 0);

    auto result = Prepare(
        frame,
        geometry,
        Target(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));

    CHECK(result.status == NormalizationStatus::TransformRequired);
    CHECK(result.requirement == TransformRequirement::Orientation);
    CHECK(!result.frame.has_value());
    return true;
}

bool TestWidthMismatchRequiresTransform() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    auto result = Prepare(
        frame,
        IdentityGeometry(),
        Target(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 9, 6));

    CHECK(result.status == NormalizationStatus::TransformRequired);
    CHECK(result.requirement == TransformRequirement::Size);
    CHECK(!result.frame.has_value());
    return true;
}

bool TestHeightMismatchRequiresTransform() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    auto result = Prepare(
        frame,
        IdentityGeometry(),
        Target(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 8, 7));

    CHECK(result.status == NormalizationStatus::TransformRequired);
    CHECK(result.requirement == TransformRequirement::Size);
    CHECK(!result.frame.has_value());
    return true;
}

bool TestPixelFormatMismatchRequiresTransform() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    auto result = Prepare(
        frame,
        IdentityGeometry(),
        Target(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange));

    CHECK(result.status == NormalizationStatus::TransformRequired);
    CHECK(result.requirement == TransformRequirement::PixelFormat);
    CHECK(!result.frame.has_value());
    return true;
}

bool TestInvalidFrameNoOutput() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        8,
        6,
        1,
        1,
        FrameValidity::Invalidated);

    auto result = Prepare(
        frame,
        IdentityGeometry(),
        Target(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));

    CHECK(result.status == NormalizationStatus::InvalidFrame);
    CHECK(!result.frame.has_value());
    return true;
}

bool TestGenerationMismatchNoOutput() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        8,
        6,
        2,
        1);

    auto result = Prepare(
        frame,
        IdentityGeometry(),
        Target(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        3,
        1);

    CHECK(result.status == NormalizationStatus::GenerationMismatch);
    CHECK(!result.frame.has_value());
    return true;
}

bool TestEpochMismatchNoOutput() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        8,
        6,
        1,
        3);

    auto result = Prepare(
        frame,
        IdentityGeometry(),
        Target(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        1,
        4);

    CHECK(result.status == NormalizationStatus::TimelineMismatch);
    CHECK(!result.frame.has_value());
    return true;
}

bool TestColorMetadataPreserved() {
    CFStringRef primaries = CFSTR("VCAM_TEST_PRIMARIES");
    CFStringRef transfer = CFSTR("VCAM_TEST_TRANSFER");
    CFStringRef matrix = CFSTR("VCAM_TEST_MATRIX");

    const void* keys[] = {CFSTR("VCAM_TEST_ATTACHMENT")};
    const void* values[] = {CFSTR("present")};
    CFDictionaryRef attachments = CFDictionaryCreate(
        kCFAllocatorDefault,
        keys,
        values,
        1,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);

    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        8,
        6,
        1,
        1,
        FrameValidity::Ready,
        primaries,
        transfer,
        matrix,
        attachments);
    CFRelease(attachments);

    auto result = Prepare(
        frame,
        IdentityGeometry(),
        Target(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));

    CHECK(result.frame.has_value());
    CHECK(CFEqual(result.frame->colorPrimaries(), primaries));
    CHECK(CFEqual(result.frame->transferFunction(), transfer));
    CHECK(CFEqual(result.frame->yCbCrMatrix(), matrix));
    CHECK(result.frame->attachments() != nullptr);
    CHECK(CFEqual(result.frame->attachments(), frame.attachments()));
    return true;
}

bool TestAttachmentsPreserved() {
    const void* keys[] = {CFSTR("VCAM_TEST_KEY")};
    const void* values[] = {CFSTR("VCAM_TEST_VALUE")};
    CFDictionaryRef attachments = CFDictionaryCreate(
        kCFAllocatorDefault,
        keys,
        values,
        1,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);

    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        8,
        6,
        1,
        1,
        FrameValidity::Ready,
        nullptr,
        nullptr,
        nullptr,
        attachments);
    CFRelease(attachments);

    auto result = Prepare(
        frame,
        IdentityGeometry(),
        Target(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange));

    CHECK(result.frame.has_value());
    CHECK(CFEqual(result.frame->attachments(), frame.attachments()));
    return true;
}

bool TestUnknownColorMetadataRemainsUnknown() {
    auto frame = MakeFrame(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);

    auto result = Prepare(
        frame,
        IdentityGeometry(),
        Target(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));

    CHECK(result.frame.has_value());
    CHECK(result.frame->colorPrimaries() == nullptr);
    CHECK(result.frame->transferFunction() == nullptr);
    CHECK(result.frame->yCbCrMatrix() == nullptr);
    return true;
}

void Run(const std::string& name,
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
    Run("420v passthrough", Test420vPassthrough);
    Run("420f passthrough", Test420fPassthrough);
    Run("Same pixel storage identity", TestSamePixelStorageIdentity);
    Run("Output owns storage independently", TestOutputOwnsStorageIndependently);
    Run("Normalized only for compatible passthrough", TestNormalizedOnlyForCompatiblePassthrough);
    Run("Non-identity transform requires transform", TestNonIdentityTransformRequiresTransform);
    Run("Width mismatch requires transform", TestWidthMismatchRequiresTransform);
    Run("Height mismatch requires transform", TestHeightMismatchRequiresTransform);
    Run("Pixel format mismatch requires transform", TestPixelFormatMismatchRequiresTransform);
    Run("Invalid frame no output", TestInvalidFrameNoOutput);
    Run("Generation mismatch no output", TestGenerationMismatchNoOutput);
    Run("Epoch mismatch no output", TestEpochMismatchNoOutput);
    Run("Color metadata preserved", TestColorMetadataPreserved);
    Run("Attachments preserved", TestAttachmentsPreserved);
    Run("Unknown color metadata remains unknown", TestUnknownColorMetadataRemainsUnknown);

    std::cout << "Stage C1 normalizer tests run: " << gTestsRun
              << ", failures: " << gFailures << std::endl;
    return gFailures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
