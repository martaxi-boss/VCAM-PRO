#pragma once

#include "FrameEngineState.h"
#include "FrameNormalizer.h"
#include "FrameTransformer.h"
#include "LocalVideoReader.h"
#include "ReadyFrameQueue.h"

#include <cstdint>
#include <functional>
#include <optional>

namespace vcam::media_engine {


enum class FramePipelinePumpStatus : std::uint8_t {
    Published = 0,
    TransformRequired,
    TransformFailed,
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
    FrameTransformStatus transformStatus =
        FrameTransformStatus::TransformFailure;

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

    FramePipelinePump(
        frame_engine::FrameEngineState& state,
        LocalVideoReader& reader,
        FrameNormalizer& normalizer,
        FrameTransformer& transformer,
        frame_engine::ReadyFrameQueue& queue,
        const NormalizationTarget& target)
        : FramePipelinePump(state, reader, normalizer, queue, target) {
        transformCallback_ =
            [&transformer](
                const frame_engine::PreparedFrame& source,
                const SourceGeometry& geometry,
                const NormalizationTarget& transformTarget,
                std::uint64_t generation,
                std::uint64_t epoch) {
                return transformer.transform(
                    source,
                    geometry,
                    transformTarget,
                    generation,
                    epoch);
            };
    }

    FramePipelinePumpResult pumpOnce();

    const NormalizationTarget& target() const noexcept;

private:
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

    using TransformCallback = std::function<
        FrameTransformResult(
            const frame_engine::PreparedFrame&,
            const SourceGeometry&,
            const NormalizationTarget&,
            std::uint64_t,
            std::uint64_t)>;
    TransformCallback transformCallback_;
};

}  // namespace vcam::media_engine
