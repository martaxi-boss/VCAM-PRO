#pragma once

#include "FrameEngineState.h"
#include "PreparedFrame.h"

#include <CoreGraphics/CoreGraphics.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

#include <cstdint>
#include <memory>
#include <optional>
#include <string>

namespace vcam::media_engine {

enum class ReadResultKind : std::uint8_t {
    Frame = 0,
    EndOfStream,
    LoopRestarted,
    NotReady,
    Failed,
    Cancelled,
};

struct LocalVideoReaderConfig {
    bool loopEnabled = false;
    OSType outputPixelFormat = 0;
};

struct SourceVideoInfo {
    CGSize naturalSize = CGSizeZero;
    CGAffineTransform preferredTransform = CGAffineTransformIdentity;
    CMTime duration = kCMTimeInvalid;
    OSType outputPixelFormat = 0;
};

struct ReadResult {
    ReadResultKind kind = ReadResultKind::NotReady;
    std::optional<frame_engine::PreparedFrame> frame;
    frame_engine::ReaderErrorCode error =
        frame_engine::ReaderErrorCode::None;
    std::string message;
};

class LocalVideoReader final {
public:
    explicit LocalVideoReader(frame_engine::FrameEngineState& state);
    ~LocalVideoReader();

    LocalVideoReader(const LocalVideoReader&) = delete;
    LocalVideoReader& operator=(const LocalVideoReader&) = delete;
    LocalVideoReader(LocalVideoReader&&) = delete;
    LocalVideoReader& operator=(LocalVideoReader&&) = delete;

    bool open(const std::string& filesystemPath,
              const LocalVideoReaderConfig& config);

    bool start();
    ReadResult readNext();
    void stop();

    bool isOpen() const noexcept;
    bool isStarted() const noexcept;
    bool loopEnabled() const noexcept;

    std::optional<SourceVideoInfo> sourceInfo() const;
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
