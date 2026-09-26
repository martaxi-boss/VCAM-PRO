#pragma once

#include "LocalFrameSource.h"

#include <CoreVideo/CoreVideo.h>

#include <cstdint>
#include <memory>
#include <string>

namespace vcam::media_engine {

struct LocalPhotoReaderConfig {
    std::int32_t cadenceNumerator = 30;
    std::int32_t cadenceDenominator = 1;
    OSType outputPixelFormat =
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
};

class LocalPhotoReader final : public LocalFrameSource {
public:
    explicit LocalPhotoReader(frame_engine::FrameEngineState& state);
    ~LocalPhotoReader() override;

    LocalPhotoReader(const LocalPhotoReader&) = delete;
    LocalPhotoReader& operator=(const LocalPhotoReader&) = delete;

    bool open(const std::string& filesystemPath,
              const LocalPhotoReaderConfig& config);

    bool start() override;
    ReadResult readNext() override;
    void stop() override;

    bool isOpen() const noexcept;
    bool isStarted() const noexcept;
    std::uint64_t decodeCount() const noexcept;
    CVPixelBufferRef decodedPixelBufferForTesting() const noexcept;

    std::optional<SourceVideoInfo> sourceInfo() const override;
    frame_engine::ReaderErrorCode lastErrorCode() const noexcept;
    const std::string& lastErrorMessage() const noexcept;

private:
    struct Impl;
    void clearLastError() noexcept;
    void setLastError(frame_engine::ReaderErrorCode code,
                      const std::string& message);

    frame_engine::FrameEngineState& state_;
    std::unique_ptr<Impl> impl_;
};

}  // namespace vcam::media_engine
