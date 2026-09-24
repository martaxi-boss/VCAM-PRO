#pragma once

#include "PreparedFrame.h"

#include <CoreGraphics/CoreGraphics.h>
#include <CoreVideo/CoreVideo.h>

#include <cstddef>
#include <cstdint>
#include <optional>

namespace vcam::media_engine {

enum class OrientationRequirement : std::uint8_t {
    UprightIdentityTransform = 0,
    PreserveSourceOrientation,
};

enum class ColorMetadataPolicy : std::uint8_t {
    PreserveSource = 0,
    RequirePresent,
};

struct NormalizationTarget {
    std::size_t width = 0;
    std::size_t height = 0;
    OSType pixelFormat = 0;
    OrientationRequirement orientation =
        OrientationRequirement::UprightIdentityTransform;
    ColorMetadataPolicy colorMetadata =
        ColorMetadataPolicy::PreserveSource;
};

struct SourceGeometry {
    CGSize naturalSize = CGSizeZero;
    CGAffineTransform preferredTransform =
        CGAffineTransformIdentity;
};

enum class TransformRequirement : std::uint8_t {
    None = 0,
    Orientation,
    Size,
    PixelFormat,
};

enum class NormalizationStatus : std::uint8_t {
    ReadyPassthrough = 0,
    TransformRequired,
    InvalidFrame,
    GenerationMismatch,
    TimelineMismatch,
    UnsupportedTarget,
    MissingRequiredColorMetadata,
};

struct NormalizationResult {
    NormalizationStatus status =
        NormalizationStatus::InvalidFrame;
    TransformRequirement requirement =
        TransformRequirement::None;
    std::optional<frame_engine::PreparedFrame> frame;
};

class FrameNormalizer final {
public:
    NormalizationResult prepare(
        const frame_engine::PreparedFrame& source,
        const SourceGeometry& geometry,
        const NormalizationTarget& target,
        std::uint64_t currentMediaGeneration,
        std::uint64_t currentTimelineEpoch) const;
};

}  // namespace vcam::media_engine
