#pragma once

#include "FrameEngineState.h"
#include "PreparedFrame.h"

#include <CoreGraphics/CoreGraphics.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

#include <cstdint>
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

class LocalFrameSource {
public:
    virtual ~LocalFrameSource() = default;
    virtual bool start() = 0;
    virtual ReadResult readNext() = 0;
    virtual void stop() = 0;
    virtual std::optional<SourceVideoInfo> sourceInfo() const = 0;
};

}  // namespace vcam::media_engine
