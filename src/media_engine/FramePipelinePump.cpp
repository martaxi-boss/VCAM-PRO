#include "FramePipelinePump.h"

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
    LocalVideoReader& reader,
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

FramePipelinePumpResult FramePipelinePump::processFrame(
    frame_engine::PreparedFrame frame,
    const SourceVideoInfo& info,
    std::uint64_t generation,
    std::uint64_t epoch) {
    FramePipelinePumpResult result;
    result.readResult = ReadResultKind::Frame;

    SourceGeometry geometry;
    geometry.naturalSize = info.naturalSize;
    geometry.preferredTransform = info.preferredTransform;

    NormalizationResult normalized = normalizer_.prepare(
        frame,
        geometry,
        target_,
        generation,
        epoch);

    result.normalizationStatus = normalized.status;
    result.transformRequirement = normalized.requirement;

    if (normalized.status == NormalizationStatus::TransformRequired) {
        result.status = FramePipelinePumpStatus::TransformRequired;
        return result;
    }

    if (normalized.status != NormalizationStatus::ReadyPassthrough ||
        !normalized.frame.has_value()) {
        result.status = FramePipelinePumpStatus::NormalizationRejected;
        return result;
    }

    result.frameIdentity = normalized.frame->identity();
    result.frameTiming = normalized.frame->timing();

    frame_engine::QueueContext queueContext;
    queueContext.currentMediaGeneration = generation;
    queueContext.currentTimelineEpoch = epoch;
    queueContext.minimumSequence = std::nullopt;

    result.publishResult =
        queue_.publish(std::move(*normalized.frame), queueContext);

    if (result.publishResult == frame_engine::PublishResult::Published) {
        result.status = FramePipelinePumpStatus::Published;
    } else {
        result.status = FramePipelinePumpStatus::QueueDropped;
    }

    return result;
}

const NormalizationTarget& FramePipelinePump::target() const noexcept {
    return target_;
}

}  // namespace vcam::media_engine
