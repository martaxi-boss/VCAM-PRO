#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <iostream>

namespace vcam::product {
bool CommitVirtualCameraOutputIntoOriginal(
    CVPixelBufferRef virtualBuffer,
    CVPixelBufferRef original) noexcept;
bool ReferenceSampleBufferHasStillImageKey(
    CMSampleBufferRef sampleBuffer) noexcept;
}

namespace {

int gTests = 0;
int gFailures = 0;

#define CHECK(condition) do { if (!(condition)) {     std::cerr << "CHECK failed at " << __FILE__ << ":" << __LINE__               << ": " #condition << std::endl; return false; } } while (false)

CVPixelBufferRef MakeBuffer(
    std::size_t width = 64,
    std::size_t height = 48,
    OSType format =
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
    CFMutableDictionaryRef attrs =
        CFDictionaryCreateMutable(
            kCFAllocatorDefault,
            0,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks);
    CFMutableDictionaryRef iosurface =
        CFDictionaryCreateMutable(
            kCFAllocatorDefault,
            0,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks);
    if (attrs == nullptr || iosurface == nullptr) {
        if (attrs != nullptr) CFRelease(attrs);
        if (iosurface != nullptr) CFRelease(iosurface);
        return nullptr;
    }

    CFDictionarySetValue(
        attrs,
        kCVPixelBufferIOSurfacePropertiesKey,
        iosurface);

    CVPixelBufferRef buffer = nullptr;
    const CVReturn status =
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            format,
            attrs,
            &buffer);

    CFRelease(iosurface);
    CFRelease(attrs);

    return status == kCVReturnSuccess
        ? buffer
        : nullptr;
}

bool FillNV12(
    CVPixelBufferRef buffer,
    std::uint8_t yValue,
    std::uint8_t cbcrValue) {
    if (buffer == nullptr ||
        CVPixelBufferGetPlaneCount(buffer) != 2 ||
        CVPixelBufferLockBaseAddress(buffer, 0) !=
            kCVReturnSuccess) {
        return false;
    }

    for (std::size_t plane = 0;
         plane < 2;
         ++plane) {
        auto* base =
            static_cast<std::uint8_t*>(
                CVPixelBufferGetBaseAddressOfPlane(
                    buffer,
                    plane));
        const std::size_t stride =
            CVPixelBufferGetBytesPerRowOfPlane(
                buffer,
                plane);
        const std::size_t height =
            CVPixelBufferGetHeightOfPlane(
                buffer,
                plane);
        if (base == nullptr ||
            stride == 0 ||
            height == 0) {
            CVPixelBufferUnlockBaseAddress(buffer, 0);
            return false;
        }

        const std::uint8_t value =
            plane == 0
                ? yValue
                : cbcrValue;
        for (std::size_t row = 0;
             row < height;
             ++row) {
            std::memset(
                base + row * stride,
                value,
                stride);
        }
    }

    CVPixelBufferUnlockBaseAddress(buffer, 0);
    return true;
}

bool ActiveBytesEqual(
    CVPixelBufferRef lhs,
    CVPixelBufferRef rhs) {
    if (lhs == nullptr ||
        rhs == nullptr ||
        CVPixelBufferGetPlaneCount(lhs) != 2 ||
        CVPixelBufferGetPlaneCount(rhs) != 2 ||
        CVPixelBufferLockBaseAddress(
            lhs,
            kCVPixelBufferLock_ReadOnly) !=
            kCVReturnSuccess) {
        return false;
    }

    if (CVPixelBufferLockBaseAddress(
            rhs,
            kCVPixelBufferLock_ReadOnly) !=
        kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(
            lhs,
            kCVPixelBufferLock_ReadOnly);
        return false;
    }

    bool equal = true;
    for (std::size_t plane = 0;
         plane < 2 &&
         equal;
         ++plane) {
        const auto* left =
            static_cast<const std::uint8_t*>(
                CVPixelBufferGetBaseAddressOfPlane(
                    lhs,
                    plane));
        const auto* right =
            static_cast<const std::uint8_t*>(
                CVPixelBufferGetBaseAddressOfPlane(
                    rhs,
                    plane));
        const std::size_t leftStride =
            CVPixelBufferGetBytesPerRowOfPlane(
                lhs,
                plane);
        const std::size_t rightStride =
            CVPixelBufferGetBytesPerRowOfPlane(
                rhs,
                plane);
        const std::size_t height =
            CVPixelBufferGetHeightOfPlane(
                lhs,
                plane);
        const std::size_t width =
            CVPixelBufferGetWidthOfPlane(
                lhs,
                plane);
        const std::size_t activeBytes =
            width * (plane == 0 ? 1U : 2U);

        if (left == nullptr ||
            right == nullptr ||
            CVPixelBufferGetHeightOfPlane(
                rhs,
                plane) != height ||
            CVPixelBufferGetWidthOfPlane(
                rhs,
                plane) != width ||
            leftStride < activeBytes ||
            rightStride < activeBytes) {
            equal = false;
            break;
        }

        for (std::size_t row = 0;
             row < height;
             ++row) {
            if (std::memcmp(
                    left + row * leftStride,
                    right + row * rightStride,
                    activeBytes) != 0) {
                equal = false;
                break;
            }
        }
    }

    CVPixelBufferUnlockBaseAddress(
        rhs,
        kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(
        lhs,
        kCVPixelBufferLock_ReadOnly);
    return equal;
}

CMSampleBufferRef MakeSampleBuffer(
    CVPixelBufferRef imageBuffer,
    bool stillMarked) {
    if (imageBuffer == nullptr) {
        return nullptr;
    }

    CMVideoFormatDescriptionRef format = nullptr;
    if (CMVideoFormatDescriptionCreateForImageBuffer(
            kCFAllocatorDefault,
            imageBuffer,
            &format) != noErr ||
        format == nullptr) {
        return nullptr;
    }

    CMSampleTimingInfo timing{};
    timing.duration = CMTimeMake(1, 30);
    timing.presentationTimeStamp = CMTimeMake(1, 30);
    timing.decodeTimeStamp = kCMTimeInvalid;

    CMSampleBufferRef sample = nullptr;
    const OSStatus status =
        CMSampleBufferCreateReadyWithImageBuffer(
            kCFAllocatorDefault,
            imageBuffer,
            format,
            &timing,
            &sample);
    CFRelease(format);

    if (status != noErr ||
        sample == nullptr) {
        return nullptr;
    }

    if (stillMarked) {
        CMSetAttachment(
            sample,
            CFSTR("StillImageKey"),
            kCFBooleanTrue,
            kCMAttachmentMode_ShouldPropagate);
    }

    return sample;
}

bool TestPhotoVirtualOwnershipCommitsIntoOriginal() {
    CVPixelBufferRef original = MakeBuffer();
    CVPixelBufferRef photo = MakeBuffer();
    CHECK(original != nullptr);
    CHECK(photo != nullptr);
    CHECK(FillNV12(original, 7, 9));
    CHECK(FillNV12(photo, 91, 173));

    CVBufferSetAttachment(
        photo,
        kCVImageBufferColorPrimariesKey,
        kCVImageBufferColorPrimaries_ITU_R_709_2,
        kCVAttachmentMode_ShouldPropagate);

    CHECK(vcam::product::
        CommitVirtualCameraOutputIntoOriginal(
            photo,
            original));
    CHECK(ActiveBytesEqual(photo, original));

    CVAttachmentMode mode =
        kCVAttachmentMode_ShouldNotPropagate;
    CHECK(CVBufferGetAttachment(
              original,
              CFSTR("vcam_patched"),
              &mode) == kCFBooleanTrue);
    CHECK(mode ==
          kCVAttachmentMode_ShouldPropagate);

    CHECK(CVBufferGetAttachment(
              original,
              kCVImageBufferColorPrimariesKey,
              nullptr) ==
          kCVImageBufferColorPrimaries_ITU_R_709_2);

    CVPixelBufferRelease(photo);
    CVPixelBufferRelease(original);
    return true;
}

bool TestNoMediaBlackStillOwnership() {
    CVPixelBufferRef original = MakeBuffer();
    CVPixelBufferRef black = MakeBuffer();
    CHECK(original != nullptr);
    CHECK(black != nullptr);
    CHECK(FillNV12(original, 211, 77));
    CHECK(FillNV12(black, 0, 128));

    CHECK(vcam::product::
        CommitVirtualCameraOutputIntoOriginal(
            black,
            original));
    CHECK(ActiveBytesEqual(black, original));

    CVPixelBufferRelease(black);
    CVPixelBufferRelease(original);
    return true;
}

bool TestStillMarkedPhotoOwnership() {
    CVPixelBufferRef original = MakeBuffer();
    CVPixelBufferRef photo = MakeBuffer();
    CHECK(original != nullptr);
    CHECK(photo != nullptr);
    CHECK(FillNV12(original, 33, 44));
    CHECK(FillNV12(photo, 121, 132));

    CMSampleBufferRef sample =
        MakeSampleBuffer(
            original,
            true);
    CHECK(sample != nullptr);
    CHECK(vcam::product::
        ReferenceSampleBufferHasStillImageKey(
            sample));

    CHECK(vcam::product::
        CommitVirtualCameraOutputIntoOriginal(
            photo,
            original));
    CHECK(ActiveBytesEqual(photo, original));

    CFRelease(sample);
    CVPixelBufferRelease(photo);
    CVPixelBufferRelease(original);
    return true;
}

bool TestUnmarkedSampleNotClassifiedStill() {
    CVPixelBufferRef original = MakeBuffer();
    CHECK(original != nullptr);

    CMSampleBufferRef sample =
        MakeSampleBuffer(
            original,
            false);
    CHECK(sample != nullptr);
    CHECK(!vcam::product::
        ReferenceSampleBufferHasStillImageKey(
            sample));

    CFRelease(sample);
    CVPixelBufferRelease(original);
    return true;
}

bool TestGeometryMismatchDoesNotOverwriteOriginal() {
    CVPixelBufferRef original =
        MakeBuffer(64, 48);
    CVPixelBufferRef different =
        MakeBuffer(66, 50);
    CVPixelBufferRef baseline =
        MakeBuffer(64, 48);
    CHECK(original != nullptr);
    CHECK(different != nullptr);
    CHECK(baseline != nullptr);
    CHECK(FillNV12(original, 19, 29));
    CHECK(FillNV12(baseline, 19, 29));
    CHECK(FillNV12(different, 88, 99));

    CHECK(!vcam::product::
        CommitVirtualCameraOutputIntoOriginal(
            different,
            original));
    CHECK(ActiveBytesEqual(
        baseline,
        original));

    CVPixelBufferRelease(baseline);
    CVPixelBufferRelease(different);
    CVPixelBufferRelease(original);
    return true;
}

void Run(
    const char* name,
    const std::function<bool()>& test) {
    ++gTests;
    if (!test()) {
        ++gFailures;
        std::cerr << "[FAIL] "
                  << name
                  << std::endl;
    } else {
        std::cout << "[PASS] "
                  << name
                  << std::endl;
    }
}

}  // namespace

int main() {
    Run(
        "PHOTO virtual content commits into original",
        TestPhotoVirtualOwnershipCommitsIntoOriginal);
    Run(
        "VCAM ON no media still uses black ownership",
        TestNoMediaBlackStillOwnership);
    Run(
        "still marked PHOTO uses virtual ownership",
        TestStillMarkedPhotoOwnership);
    Run(
        "ordinary sample not classified still",
        TestUnmarkedSampleNotClassifiedStill);
    Run(
        "geometry mismatch leaves original untouched",
        TestGeometryMismatchDoesNotOverwriteOriginal);

    if (gFailures == 0) {
        std::cout
            << "STILL_SAME_GEOMETRY_VIRTUAL_OWNERSHIP=PASS\n"
            << "STILL_NO_MEDIA_SAME_GEOMETRY_USES_BLACK=PASS\n"
            << "STILL_PHOTO_READY_SAME_GEOMETRY_USES_PHOTO=PASS\n"
            << "STILL_GEOMETRY_MISMATCH_PRESERVES_ORIGINAL=OBSERVED\n"
            << "STILL_GEOMETRY_RACE_DEVICE_CLASSIFICATION=REQUIRED\n";
    }

    std::cout
        << "Reference hook ownership tests run: "
        << gTests
        << ", failures: "
        << gFailures
        << std::endl;

    return gFailures == 0
        ? EXIT_SUCCESS
        : EXIT_FAILURE;
}
