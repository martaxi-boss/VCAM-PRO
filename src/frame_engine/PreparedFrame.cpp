#include "PreparedFrame.h"

#include <utility>

namespace vcam::frame_engine {

namespace {

CVPixelBufferRef RetainPixelBuffer(CVPixelBufferRef pixelBuffer) noexcept {
    return pixelBuffer == nullptr ? nullptr : CVPixelBufferRetain(pixelBuffer);
}

void ReleasePixelBuffer(CVPixelBufferRef& pixelBuffer) noexcept {
    if (pixelBuffer != nullptr) {
        CVPixelBufferRelease(pixelBuffer);
        pixelBuffer = nullptr;
    }
}

}  // namespace

FrameLease::FrameLease(CVPixelBufferRef pixelBuffer,
                       std::size_t width,
                       std::size_t height,
                       OSType pixelFormat,
                       const FrameIdentity& identity)
    : pixelBuffer_(RetainPixelBuffer(pixelBuffer)),
      width_(width),
      height_(height),
      pixelFormat_(pixelFormat),
      identity_(identity) {}

FrameLease::FrameLease(const FrameLease& other)
    : pixelBuffer_(RetainPixelBuffer(other.pixelBuffer_)),
      width_(other.width_),
      height_(other.height_),
      pixelFormat_(other.pixelFormat_),
      identity_(other.identity_) {}

FrameLease& FrameLease::operator=(const FrameLease& other) {
    if (this != &other) {
        FrameLease copy(other);
        swap(copy);
    }
    return *this;
}

FrameLease::FrameLease(FrameLease&& other) noexcept
    : pixelBuffer_(other.pixelBuffer_),
      width_(other.width_),
      height_(other.height_),
      pixelFormat_(other.pixelFormat_),
      identity_(other.identity_) {
    other.pixelBuffer_ = nullptr;
    other.width_ = 0;
    other.height_ = 0;
    other.pixelFormat_ = 0;
    other.identity_ = {};
}

FrameLease& FrameLease::operator=(FrameLease&& other) noexcept {
    if (this != &other) {
        release();
        pixelBuffer_ = other.pixelBuffer_;
        width_ = other.width_;
        height_ = other.height_;
        pixelFormat_ = other.pixelFormat_;
        identity_ = other.identity_;

        other.pixelBuffer_ = nullptr;
        other.width_ = 0;
        other.height_ = 0;
        other.pixelFormat_ = 0;
        other.identity_ = {};
    }
    return *this;
}

FrameLease::~FrameLease() {
    release();
}

CVPixelBufferRef FrameLease::pixelBuffer() const noexcept {
    return pixelBuffer_;
}

std::size_t FrameLease::width() const noexcept {
    return width_;
}

std::size_t FrameLease::height() const noexcept {
    return height_;
}

OSType FrameLease::pixelFormat() const noexcept {
    return pixelFormat_;
}

const FrameIdentity& FrameLease::identity() const noexcept {
    return identity_;
}

bool FrameLease::isValid() const noexcept {
    if (pixelBuffer_ == nullptr) {
        return false;
    }
    return width_ == CVPixelBufferGetWidth(pixelBuffer_) &&
           height_ == CVPixelBufferGetHeight(pixelBuffer_) &&
           pixelFormat_ == CVPixelBufferGetPixelFormatType(pixelBuffer_);
}

void FrameLease::release() noexcept {
    ReleasePixelBuffer(pixelBuffer_);
    width_ = 0;
    height_ = 0;
    pixelFormat_ = 0;
    identity_ = {};
}

void FrameLease::swap(FrameLease& other) noexcept {
    std::swap(pixelBuffer_, other.pixelBuffer_);
    std::swap(width_, other.width_);
    std::swap(height_, other.height_);
    std::swap(pixelFormat_, other.pixelFormat_);
    std::swap(identity_, other.identity_);
}

PreparedFrame::PreparedFrame(CVPixelBufferRef pixelBuffer,
                             const FrameIdentity& identity,
                             const FrameTiming& timing,
                             OrientationState orientation,
                             FrameValidity validity,
                             CFStringRef colorPrimaries,
                             CFStringRef transferFunction,
                             CFStringRef yCbCrMatrix,
                             CFDictionaryRef attachments)
    : pixelBuffer_(RetainPixelBuffer(pixelBuffer)),
      identity_(identity),
      timing_(timing),
      orientation_(orientation),
      validity_(pixelBuffer == nullptr && validity == FrameValidity::Ready
                    ? FrameValidity::Failed
                    : validity),
      colorPrimaries_(retainString(colorPrimaries)),
      transferFunction_(retainString(transferFunction)),
      yCbCrMatrix_(retainString(yCbCrMatrix)),
      attachments_(copyAttachments(attachments)) {
    if (pixelBuffer_ != nullptr) {
        width_ = CVPixelBufferGetWidth(pixelBuffer_);
        height_ = CVPixelBufferGetHeight(pixelBuffer_);
        pixelFormat_ = CVPixelBufferGetPixelFormatType(pixelBuffer_);
    }
}

PreparedFrame::PreparedFrame(const PreparedFrame& other)
    : pixelBuffer_(RetainPixelBuffer(other.pixelBuffer_)),
      width_(other.width_),
      height_(other.height_),
      pixelFormat_(other.pixelFormat_),
      identity_(other.identity_),
      timing_(other.timing_),
      orientation_(other.orientation_),
      validity_(other.validity_),
      colorPrimaries_(retainString(other.colorPrimaries_)),
      transferFunction_(retainString(other.transferFunction_)),
      yCbCrMatrix_(retainString(other.yCbCrMatrix_)),
      attachments_(other.attachments_ == nullptr
                       ? nullptr
                       : static_cast<CFDictionaryRef>(CFRetain(other.attachments_))) {}

PreparedFrame& PreparedFrame::operator=(const PreparedFrame& other) {
    if (this != &other) {
        PreparedFrame copy(other);
        swap(copy);
    }
    return *this;
}

PreparedFrame::PreparedFrame(PreparedFrame&& other) noexcept
    : pixelBuffer_(other.pixelBuffer_),
      width_(other.width_),
      height_(other.height_),
      pixelFormat_(other.pixelFormat_),
      identity_(other.identity_),
      timing_(other.timing_),
      orientation_(other.orientation_),
      validity_(other.validity_),
      colorPrimaries_(other.colorPrimaries_),
      transferFunction_(other.transferFunction_),
      yCbCrMatrix_(other.yCbCrMatrix_),
      attachments_(other.attachments_) {
    other.pixelBuffer_ = nullptr;
    other.width_ = 0;
    other.height_ = 0;
    other.pixelFormat_ = 0;
    other.identity_ = {};
    other.timing_ = {};
    other.orientation_ = OrientationState::Unknown;
    other.validity_ = FrameValidity::Failed;
    other.colorPrimaries_ = nullptr;
    other.transferFunction_ = nullptr;
    other.yCbCrMatrix_ = nullptr;
    other.attachments_ = nullptr;
}

PreparedFrame& PreparedFrame::operator=(PreparedFrame&& other) noexcept {
    if (this != &other) {
        release();

        pixelBuffer_ = other.pixelBuffer_;
        width_ = other.width_;
        height_ = other.height_;
        pixelFormat_ = other.pixelFormat_;
        identity_ = other.identity_;
        timing_ = other.timing_;
        orientation_ = other.orientation_;
        validity_ = other.validity_;
        colorPrimaries_ = other.colorPrimaries_;
        transferFunction_ = other.transferFunction_;
        yCbCrMatrix_ = other.yCbCrMatrix_;
        attachments_ = other.attachments_;

        other.pixelBuffer_ = nullptr;
        other.width_ = 0;
        other.height_ = 0;
        other.pixelFormat_ = 0;
        other.identity_ = {};
        other.timing_ = {};
        other.orientation_ = OrientationState::Unknown;
        other.validity_ = FrameValidity::Failed;
        other.colorPrimaries_ = nullptr;
        other.transferFunction_ = nullptr;
        other.yCbCrMatrix_ = nullptr;
        other.attachments_ = nullptr;
    }
    return *this;
}

PreparedFrame::~PreparedFrame() {
    release();
}

CVPixelBufferRef PreparedFrame::pixelBuffer() const noexcept {
    return pixelBuffer_;
}

std::size_t PreparedFrame::width() const noexcept {
    return width_;
}

std::size_t PreparedFrame::height() const noexcept {
    return height_;
}

OSType PreparedFrame::pixelFormat() const noexcept {
    return pixelFormat_;
}

const FrameIdentity& PreparedFrame::identity() const noexcept {
    return identity_;
}

const FrameTiming& PreparedFrame::timing() const noexcept {
    return timing_;
}

OrientationState PreparedFrame::orientation() const noexcept {
    return orientation_;
}

FrameValidity PreparedFrame::validity() const noexcept {
    return validity_;
}

CFStringRef PreparedFrame::colorPrimaries() const noexcept {
    return colorPrimaries_;
}

CFStringRef PreparedFrame::transferFunction() const noexcept {
    return transferFunction_;
}

CFStringRef PreparedFrame::yCbCrMatrix() const noexcept {
    return yCbCrMatrix_;
}

CFDictionaryRef PreparedFrame::attachments() const noexcept {
    return attachments_;
}

bool PreparedFrame::isInternallyConsistent() const noexcept {
    if (pixelBuffer_ == nullptr) {
        return false;
    }

    return width_ == CVPixelBufferGetWidth(pixelBuffer_) &&
           height_ == CVPixelBufferGetHeight(pixelBuffer_) &&
           pixelFormat_ == CVPixelBufferGetPixelFormatType(pixelBuffer_);
}

bool PreparedFrame::isEligible(std::uint64_t currentMediaGeneration,
                               std::uint64_t currentTimelineEpoch) const noexcept {
    return validity_ == FrameValidity::Ready &&
           identity_.mediaGeneration == currentMediaGeneration &&
           identity_.timelineEpoch == currentTimelineEpoch &&
           isInternallyConsistent();
}

std::optional<FrameLease> PreparedFrame::acquireLease(
    std::uint64_t currentMediaGeneration,
    std::uint64_t currentTimelineEpoch) const {
    if (!isEligible(currentMediaGeneration, currentTimelineEpoch)) {
        return std::nullopt;
    }

    return FrameLease(pixelBuffer_, width_, height_, pixelFormat_, identity_);
}

void PreparedFrame::invalidate() noexcept {
    validity_ = FrameValidity::Invalidated;
}

void PreparedFrame::markFailed() noexcept {
    validity_ = FrameValidity::Failed;
}

CFStringRef PreparedFrame::retainString(CFStringRef value) noexcept {
    if (value != nullptr) {
        CFRetain(value);
    }
    return value;
}

void PreparedFrame::releaseString(CFStringRef& value) noexcept {
    if (value != nullptr) {
        CFRelease(value);
        value = nullptr;
    }
}

CFDictionaryRef PreparedFrame::copyAttachments(CFDictionaryRef value) {
    if (value == nullptr) {
        return nullptr;
    }
    return CFDictionaryCreateCopy(kCFAllocatorDefault, value);
}

void PreparedFrame::releaseDictionary(CFDictionaryRef& value) noexcept {
    if (value != nullptr) {
        CFRelease(value);
        value = nullptr;
    }
}

void PreparedFrame::release() noexcept {
    ReleasePixelBuffer(pixelBuffer_);
    releaseString(colorPrimaries_);
    releaseString(transferFunction_);
    releaseString(yCbCrMatrix_);
    releaseDictionary(attachments_);

    width_ = 0;
    height_ = 0;
    pixelFormat_ = 0;
    identity_ = {};
    timing_ = {};
    orientation_ = OrientationState::Unknown;
    validity_ = FrameValidity::Failed;
}

void PreparedFrame::swap(PreparedFrame& other) noexcept {
    std::swap(pixelBuffer_, other.pixelBuffer_);
    std::swap(width_, other.width_);
    std::swap(height_, other.height_);
    std::swap(pixelFormat_, other.pixelFormat_);
    std::swap(identity_, other.identity_);
    std::swap(timing_, other.timing_);
    std::swap(orientation_, other.orientation_);
    std::swap(validity_, other.validity_);
    std::swap(colorPrimaries_, other.colorPrimaries_);
    std::swap(transferFunction_, other.transferFunction_);
    std::swap(yCbCrMatrix_, other.yCbCrMatrix_);
    std::swap(attachments_, other.attachments_);
}

}  // namespace vcam::frame_engine
