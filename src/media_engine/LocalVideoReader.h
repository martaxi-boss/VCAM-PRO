#pragma once

#include "LocalFrameSource.h"

#include <CoreVideo/CoreVideo.h>

#include <cstdint>
#include <memory>
#include <optional>
#include <string>

namespace vcam::media_engine {

struct LocalVideoReaderConfig {
    bool loopEnabled = false;
    OSType outputPixelFormat = 0;
};

class LocalVideoReader final : public LocalFrameSource {
public:
    explicit LocalVideoReader(frame_engine::FrameEngineState& state);
    ~LocalVideoReader() override;

    LocalVideoReader(const LocalVideoReader&) = delete;
    LocalVideoReader& operator=(const LocalVideoReader&) = delete;
    LocalVideoReader(LocalVideoReader&&) = delete;
    LocalVideoReader& operator=(LocalVideoReader&&) = delete;

    bool open(const std::string& filesystemPath,
              const LocalVideoReaderConfig& config);

    bool start() override;
    ReadResult readNext() override;
    void stop() override;

    bool isOpen() const noexcept;
    bool isStarted() const noexcept;
    bool loopEnabled() const noexcept;
    void setLoopEnabled(bool enabled) noexcept;

    std::optional<SourceVideoInfo> sourceInfo() const override;
    const std::string& fileIdentity() const noexcept;

    frame_engine::ReaderErrorCode lastErrorCode() const noexcept;
    const std::string& lastErrorMessage() const noexcept;

private:
    struct Impl;

    bool rebuildReaderForLoop();
    bool startCurrentReaderWithoutNewTimeline();
    void cancelCurrentReaderForReplacement();
    void clearLastError() noexcept;
    void setLastError(frame_engine::ReaderErrorCode code,
                      const std::string& message);

    frame_engine::FrameEngineState& state_;
    std::unique_ptr<Impl> impl_;
};

}  // namespace vcam::media_engine
