#pragma once

#include <CoreVideo/CoreVideo.h>

#include <array>
#include <cstddef>
#include <mutex>

namespace vcam::product {

class VirtualBlackFrame final {
public:
    static constexpr std::size_t kCacheCapacity = 4;

    VirtualBlackFrame() = default;
    ~VirtualBlackFrame();

    VirtualBlackFrame(
        const VirtualBlackFrame&) = delete;
    VirtualBlackFrame& operator=(
        const VirtualBlackFrame&) = delete;

    CVPixelBufferRef prepare(
        std::size_t width,
        std::size_t height,
        OSType pixelFormat);

    std::size_t cacheSize() const;

    static bool isSupportedPixelFormat(
        OSType pixelFormat) noexcept;

private:
    struct Entry {
        std::size_t width = 0;
        std::size_t height = 0;
        OSType pixelFormat = 0;
        CVPixelBufferRef pixelBuffer = nullptr;
    };

    static CVPixelBufferRef createBlackBuffer(
        std::size_t width,
        std::size_t height,
        OSType pixelFormat);

    mutable std::mutex mutex_;
    std::array<Entry, kCacheCapacity> entries_{};
    std::size_t count_ = 0;
};

}  // namespace vcam::product
