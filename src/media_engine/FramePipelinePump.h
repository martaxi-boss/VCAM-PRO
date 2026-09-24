#pragma once

#include "FrameEngineState.h"
#include "FrameNormalizer.h"
#include "LocalVideoReader.h"
#include "ReadyFrameQueue.h"

#include <cstdint>
#include <optional>

namespace vcam::media_engine {

class FramePipelinePumpTestAccess;

enum class FramePipelinePumpStatus : std::uint8_t {
    Published = 0,
    TransformRequired,
    QueueDropped,
    EndOfStream,
    LoopRestarted,
    NotReady,
    ReaderFailed,
    Cancelled,
    NormalizationRejected,
};

struct FramePipelinePumpResult {
    FramePipelinePumpStatus status = FramePipelinePumpStatus::NotReady;

    ReadResultKind readResult = ReadResultKind::NotReady;
    frame_engine::ReaderErrorCode readerError =
        frame_engine::ReaderErrorCode::None;

    NormalizationStatus normalizationStatus =
        NormalizationStatus::InvalidFrame;
    TransformRequirement transformRequirement =
        TransformRequirement::None;

    frame_engine::PublishResult publishResult =
        frame_engine::PublishResult::DroppedInvalid;

    std::optional<frame_engine::FrameIdentity> frameIdentity;
    std::optional<frame_engine::FrameTiming> frameTiming;
};

class FramePipelinePump final {
public:
    FramePipelinePump(
        frame_engine::FrameEngineState& state,
        LocalVideoReader& reader,
        FrameNormalizer& normalizer,
        frame_engine::ReadyFrameQueue& queue,
        const NormalizationTarget& target);

    FramePipelinePumpResult pumpOnce();

    const NormalizationTarget& target() const noexcept;

private:
    friend class FramePipelinePumpTestAccess;

    FramePipelinePumpResult processFrame(
        frame_engine::PreparedFrame frame,
        const SourceVideoInfo& info,
        std::uint64_t generation,
        std::uint64_t epoch);

    frame_engine::FrameEngineState& state_;
    LocalVideoReader& reader_;
    FrameNormalizer& normalizer_;
    frame_engine::ReadyFrameQueue& queue_;
    NormalizationTarget target_;
};

}  // namespace vcam::media_engine
