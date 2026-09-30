#include "FramePipelinePump.h"

#include <new>
#include <utility>

namespace vcam::media_engine {

namespace {

FramePipelinePumpResult MakeReaderResult(
    FramePipelinePumpStatus status,
    const ReadResult& read) {
    FramePipelinePumpResult result;
    result.status = status;
    result.readResult = read.kind;
    result.readerError = read.error;
    return result;
}

}  // namespace

FramePipelinePump::FramePipelinePump(
    frame_engine::FrameEngineState& state,
    LocalFrameSource& reader,
    FrameNormalizer& normalizer,
    frame_engine::ReadyFrameQueue& queue,
    const NormalizationTarget& target)
    : state_(state),
      reader_(reader),
      normalizer_(normalizer),
      queue_(queue),
      target_(target) {}

FramePipelinePumpResult FramePipelinePump::pumpOnce() {
    // Producer-side only. A future camera/injector callback must never call
    // this method because readNext() may perform AVAssetReader file I/O and
    // decode work. The future consumer fast path is ReadyFrameQueue::tryAcquire.
    ReadResult read = reader_.readNext();

    switch (read.kind) {
        case ReadResultKind::EndOfStream:
            return MakeReaderResult(
                FramePipelinePumpStatus::EndOfStream,
                read);
        case ReadResultKind::LoopRestarted:
            return MakeReaderResult(
                FramePipelinePumpStatus::LoopRestarted,
                read);
        case ReadResultKind::NotReady:
            return MakeReaderResult(
                FramePipelinePumpStatus::NotReady,
                read);
        case ReadResultKind::Failed:
            return MakeReaderResult(
                FramePipelinePumpStatus::ReaderFailed,
                read);
        case ReadResultKind::Cancelled:
            return MakeReaderResult(
                FramePipelinePumpStatus::Cancelled,
                read);
        case ReadResultKind::Frame:
            break;
    }

    FramePipelinePumpResult result;
    result.readResult = read.kind;
    result.readerError = read.error;

    if (!read.frame.has_value()) {
        result.status = FramePipelinePumpStatus::ReaderFailed;
        result.readerError = frame_engine::ReaderErrorCode::Unknown;
        return result;
    }

    const std::optional<SourceVideoInfo> info = reader_.sourceInfo();
    if (!info.has_value()) {
        result.status = FramePipelinePumpStatus::NormalizationRejected;
        result.normalizationStatus = NormalizationStatus::UnsupportedTarget;
        return result;
    }

    return processFrame(
        std::move(*read.frame),
        *info,
        state_.mediaGeneration(),
        state_.timelineEpoch());
}

FramePipelinePump::PreparedPipelineResult
FramePipelinePump::prepareFrame(
    frame_engine::PreparedFrame frame,
    const SourceVideoInfo& info,
    std::uint64_t generation,
    std::uint64_t epoch) {
    PreparedPipelineResult prepared;
    prepared.result.readResult = ReadResultKind::Frame;

    try {
        SourceGeometry geometry;
        geometry.naturalSize = info.naturalSize;
        geometry.preferredTransform = info.preferredTransform;

        NormalizationResult normalized = normalizer_.prepare(
            frame,
            geometry,
            target_,
            generation,
            epoch);

        prepared.result.normalizationStatus = normalized.status;
        prepared.result.transformRequirement = normalized.requirement;

        const bool transformRequiredByNormalizer =
            normalized.status ==
                NormalizationStatus::TransformRequired;
        const bool forcePreparedPhotoTransform =
            forceTransform_.load(
                std::memory_order_acquire) &&
            normalized.status ==
                NormalizationStatus::ReadyPassthrough &&
            normalized.frame.has_value();

        if (transformRequiredByNormalizer ||
            forcePreparedPhotoTransform) {
            if (!transformCallback_) {
                prepared.result.status =
                    FramePipelinePumpStatus::TransformRequired;
                return prepared;
            }

            const frame_engine::PreparedFrame&
                transformSource =
                    forcePreparedPhotoTransform
                        ? *normalized.frame
                        : frame;

            FrameTransformResult transformed = transformCallback_(
                transformSource,
                geometry,
                target_,
                generation,
                epoch);
            prepared.result.transformStatus = transformed.status;

            if (transformed.status != FrameTransformStatus::Transformed ||
                !transformed.frame.has_value()) {
                prepared.result.status =
                    FramePipelinePumpStatus::TransformFailed;
                return prepared;
            }

            const frame_engine::PreparedFrame& validated =
                *transformed.frame;

            const bool exactTarget =
                validated.validity() ==
                    frame_engine::FrameValidity::Ready &&
                validated.isInternallyConsistent() &&
                validated.identity().mediaGeneration == generation &&
                validated.identity().timelineEpoch == epoch &&
                validated.width() == target_.width &&
                validated.height() == target_.height &&
                validated.pixelFormat() == target_.pixelFormat &&
                validated.orientation() ==
                    frame_engine::OrientationState::Normalized;

            if (!exactTarget) {
                prepared.result.status =
                    FramePipelinePumpStatus::TransformFailed;
                return prepared;
            }

            prepared.result.normalizationStatus =
                NormalizationStatus::ReadyPassthrough;
            normalized.status =
                NormalizationStatus::ReadyPassthrough;
            normalized.requirement =
                TransformRequirement::None;
            normalized.frame.emplace(
                std::move(*transformed.frame));
        }

        if (normalized.status != NormalizationStatus::ReadyPassthrough ||
            !normalized.frame.has_value()) {
            prepared.result.status =
                FramePipelinePumpStatus::NormalizationRejected;
            return prepared;
        }

        prepared.result.frameIdentity = normalized.frame->identity();
        prepared.result.frameTiming = normalized.frame->timing();
        prepared.frame.emplace(std::move(*normalized.frame));
        return prepared;
    } catch (const std::bad_alloc&) {
        prepared.result.status =
            FramePipelinePumpStatus::AllocationFailed;
        prepared.frame.reset();
        return prepared;
    }
}

FramePipelinePumpResult FramePipelinePump::processFrame(
    frame_engine::PreparedFrame frame,
    const SourceVideoInfo& info,
    std::uint64_t generation,
    std::uint64_t epoch) {
    PreparedPipelineResult prepared = prepareFrame(
        std::move(frame),
        info,
        generation,
        epoch);

    if (!prepared.frame.has_value()) {
        return prepared.result;
    }

    frame_engine::QueueContext queueContext;
    queueContext.currentMediaGeneration = generation;
    queueContext.currentTimelineEpoch = epoch;
    queueContext.minimumSequence = std::nullopt;

    prepared.result.publishResult =
        queue_.publish(std::move(*prepared.frame), queueContext);

    if (prepared.result.publishResult ==
        frame_engine::PublishResult::Published) {
        prepared.result.status = FramePipelinePumpStatus::Published;
    } else {
        prepared.result.status = FramePipelinePumpStatus::QueueDropped;
    }

    return prepared.result;
}

const NormalizationTarget& FramePipelinePump::target() const noexcept {
    return target_;
}

void FramePipelinePump::setTarget(
    const NormalizationTarget& target) noexcept {
    target_ = target;
    pendingTimedFrame_.reset();
    pendingPreparedResult_ = {};
    timedContextInitialized_ = false;
    timedMediaGeneration_ = 0;
    timedTimelineEpoch_ = 0;
}

void FramePipelinePump::setTargetPreservingTimeline(
    const NormalizationTarget& target) noexcept {
    // A geometry-only retarget must not discard a frame that has already
    // advanced the source reader and scheduler. The pending frame remains a
    // valid prepared VIDEO variant for its original destination and is
    // published at its existing due host time. Subsequent source frames use
    // the new target. Transform-revision changes use the separate explicit
    // discardPendingTimedFrameForTransformUpdate() path.
    target_ = target;
}

}  // namespace vcam::media_engine
