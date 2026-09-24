#include "FrameNormalizer.h"

#include <CoreFoundation/CoreFoundation.h>

namespace vcam::media_engine {

namespace {

bool IsAllowedTargetPixelFormat(OSType pixelFormat) noexcept {
    return pixelFormat ==
               kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
           pixelFormat ==
               kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
}

bool HasRequiredColorMetadata(
    const frame_engine::PreparedFrame& frame) noexcept {
    return frame.colorPrimaries() != nullptr &&
           frame.transferFunction() != nullptr &&
           frame.yCbCrMatrix() != nullptr;
}

NormalizationResult TransformRequired(
    TransformRequirement requirement) {
    NormalizationResult result;
    result.status = NormalizationStatus::TransformRequired;
    result.requirement = requirement;
    return result;
}

}  // namespace

NormalizationResult FrameNormalizer::prepare(
    const frame_engine::PreparedFrame& source,
    const SourceGeometry& geometry,
    const NormalizationTarget& target,
    std::uint64_t currentMediaGeneration,
    std::uint64_t currentTimelineEpoch) const {
    using frame_engine::FrameValidity;
    using frame_engine::OrientationState;
    using frame_engine::PreparedFrame;

    if (target.width == 0 ||
        target.height == 0 ||
        !IsAllowedTargetPixelFormat(target.pixelFormat) ||
        target.orientation !=
            OrientationRequirement::UprightIdentityTransform) {
        NormalizationResult result;
        result.status = NormalizationStatus::UnsupportedTarget;
        return result;
    }

    if (source.validity() != FrameValidity::Ready ||
        !source.isInternallyConsistent()) {
        NormalizationResult result;
        result.status = NormalizationStatus::InvalidFrame;
        return result;
    }

    if (source.identity().mediaGeneration !=
        currentMediaGeneration) {
        NormalizationResult result;
        result.status = NormalizationStatus::GenerationMismatch;
        return result;
    }

    if (source.identity().timelineEpoch !=
        currentTimelineEpoch) {
        NormalizationResult result;
        result.status = NormalizationStatus::TimelineMismatch;
        return result;
    }

    if (!CGAffineTransformIsIdentity(
            geometry.preferredTransform)) {
        return TransformRequired(TransformRequirement::Orientation);
    }

    if (source.width() != target.width ||
        source.height() != target.height) {
        return TransformRequired(TransformRequirement::Size);
    }

    if (source.pixelFormat() != target.pixelFormat) {
        return TransformRequired(TransformRequirement::PixelFormat);
    }

    if (target.colorMetadata ==
            ColorMetadataPolicy::RequirePresent &&
        !HasRequiredColorMetadata(source)) {
        NormalizationResult result;
        result.status =
            NormalizationStatus::MissingRequiredColorMetadata;
        return result;
    }

    PreparedFrame passthrough(
        source.pixelBuffer(),
        source.identity(),
        source.timing(),
        OrientationState::Normalized,
        FrameValidity::Ready,
        source.colorPrimaries(),
        source.transferFunction(),
        source.yCbCrMatrix(),
        source.attachments());

    if (!passthrough.isInternallyConsistent()) {
        NormalizationResult result;
        result.status = NormalizationStatus::InvalidFrame;
        return result;
    }

    NormalizationResult result;
    result.status = NormalizationStatus::ReadyPassthrough;
    result.requirement = TransformRequirement::None;
    result.frame.emplace(std::move(passthrough));
    return result;
}

}  // namespace vcam::media_engine
