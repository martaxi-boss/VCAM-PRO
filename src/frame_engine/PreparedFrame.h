#pragma once

#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

#include <cstddef>
#include <cstdint>
#include <optional>

namespace vcam::frame_engine {

enum class OrientationState : std::uint8_t {
    Unknown = 0,
    SourceNotNormalized,
    Normalized,
};

enum class FrameValidity : std::uint8_t {
    Ready = 0,
    Invalidated,
    Failed,
};

struct FrameIdentity {
    std::uint64_t sequence = 0;
    std::uint64_t mediaGeneration = 0;
    std::uint64_t timelineEpoch = 0;
    std::uint64_t loopIteration = 0;
};

struct FrameTiming {
    CMTime sourcePTS = kCMTimeInvalid;
    CMTime presentationTimestamp = kCMTimeInvalid;
    CMTime duration = kCMTimeInvalid;
    std::optional<std::uint64_t> producedAtHostTime;
};

class FrameLease final {
public:
    FrameLease(const FrameLease& other);
    FrameLease& operator=(const FrameLease& other);
    FrameLease(FrameLease&& other) noexcept;
    FrameLease& operator=(FrameLease&& other) noexcept;
    ~FrameLease();

    CVPixelBufferRef pixelBuffer() const noexcept;
    std::size_t width() const noexcept;
    std::size_t height() const noexcept;
    OSType pixelFormat() const noexcept;
    const FrameIdentity& identity() const noexcept;
    bool isValid() const noexcept;

private:
    friend class PreparedFrame;

    FrameLease(CVPixelBufferRef pixelBuffer,
               std::size_t width,
               std::size_t height,
               OSType pixelFormat,
               const FrameIdentity& identity);

    void release() noexcept;
    void swap(FrameLease& other) noexcept;

    CVPixelBufferRef pixelBuffer_ = nullptr;
    std::size_t width_ = 0;
    std::size_t height_ = 0;
    OSType pixelFormat_ = 0;
    FrameIdentity identity_{};
};

class PreparedFrame final {
public:
    PreparedFrame(CVPixelBufferRef pixelBuffer,
                  const FrameIdentity& identity,
                  const FrameTiming& timing,
                  OrientationState orientation,
                  FrameValidity validity = FrameValidity::Ready,
                  CFStringRef colorPrimaries = nullptr,
                  CFStringRef transferFunction = nullptr,
                  CFStringRef yCbCrMatrix = nullptr,
                  CFDictionaryRef attachments = nullptr);

    PreparedFrame(const PreparedFrame& other);
    PreparedFrame& operator=(const PreparedFrame& other);
    PreparedFrame(PreparedFrame&& other) noexcept;
    PreparedFrame& operator=(PreparedFrame&& other) noexcept;
    ~PreparedFrame();

    CVPixelBufferRef pixelBuffer() const noexcept;
    std::size_t width() const noexcept;
    std::size_t height() const noexcept;
    OSType pixelFormat() const noexcept;

    const FrameIdentity& identity() const noexcept;
    const FrameTiming& timing() const noexcept;
    OrientationState orientation() const noexcept;
    FrameValidity validity() const noexcept;

    CFStringRef colorPrimaries() const noexcept;
    CFStringRef transferFunction() const noexcept;
    CFStringRef yCbCrMatrix() const noexcept;
    CFDictionaryRef attachments() const noexcept;

    bool isInternallyConsistent() const noexcept;
    bool isEligible(std::uint64_t currentMediaGeneration,
                    std::uint64_t currentTimelineEpoch) const noexcept;

    std::optional<FrameLease> acquireLease(
        std::uint64_t currentMediaGeneration,
        std::uint64_t currentTimelineEpoch) const;

    void invalidate() noexcept;
    void markFailed() noexcept;

private:
    static CFStringRef retainString(CFStringRef value) noexcept;
    static void releaseString(CFStringRef& value) noexcept;
    static CFDictionaryRef copyAttachments(CFDictionaryRef value);
    static void releaseDictionary(CFDictionaryRef& value) noexcept;

    void release() noexcept;
    void swap(PreparedFrame& other) noexcept;

    CVPixelBufferRef pixelBuffer_ = nullptr;
    std::size_t width_ = 0;
    std::size_t height_ = 0;
    OSType pixelFormat_ = 0;

    FrameIdentity identity_{};
    FrameTiming timing_{};
    OrientationState orientation_ = OrientationState::Unknown;
    FrameValidity validity_ = FrameValidity::Failed;

    CFStringRef colorPrimaries_ = nullptr;
    CFStringRef transferFunction_ = nullptr;
    CFStringRef yCbCrMatrix_ = nullptr;
    CFDictionaryRef attachments_ = nullptr;
};

}  // namespace vcam::frame_engine
