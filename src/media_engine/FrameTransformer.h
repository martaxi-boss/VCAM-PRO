#pragma once

#include "FrameNormalizer.h"
#include "PreparedFrame.h"

#include <cstdint>
#include <memory>
#include <optional>

namespace vcam::media_engine {

enum class FrameTransformStatus : std::uint8_t {
    Transformed = 0,
    InvalidFrame,
    GenerationMismatch,
    TimelineMismatch,
    UnsupportedTarget,
    UnsupportedGeometry,
    UnsupportedColorConversion,
    PoolFailure,
    AllocationFailure,
    TransformFailure,
};

struct FrameTransformResult {
    FrameTransformStatus status = FrameTransformStatus::TransformFailure;
    std::optional<frame_engine::PreparedFrame> frame;
};

struct FrameTransformerStats {
    std::uint64_t outputPoolBuilds = 0;
    std::uint64_t rotationPoolBuilds = 0;
    std::uint64_t conversionInputPoolBuilds = 0;
    std::uint64_t scaleScratchBuilds = 0;
    std::uint64_t argbScratchBuilds = 0;
    std::uint64_t conversionDescriptorBuilds = 0;
};

class FrameTransformer final {
public:
    FrameTransformer();
    ~FrameTransformer();

    FrameTransformer(const FrameTransformer&) = delete;
    FrameTransformer& operator=(const FrameTransformer&) = delete;
    FrameTransformer(FrameTransformer&&) = delete;
    FrameTransformer& operator=(FrameTransformer&&) = delete;

    FrameTransformResult transform(
        const frame_engine::PreparedFrame& source,
        const SourceGeometry& geometry,
        const NormalizationTarget& target,
        std::uint64_t currentMediaGeneration,
        std::uint64_t currentTimelineEpoch);

    FrameTransformerStats stats() const noexcept;

private:
    FrameTransformResult transformImpl(
        const frame_engine::PreparedFrame& source,
        const SourceGeometry& geometry,
        const NormalizationTarget& target,
        std::uint64_t currentMediaGeneration,
        std::uint64_t currentTimelineEpoch);

    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace vcam::media_engine
