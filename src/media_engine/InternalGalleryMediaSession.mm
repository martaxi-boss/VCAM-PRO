#include "InternalGalleryMediaSession.h"

#include <utility>

namespace vcam::media_engine {

InternalGalleryMediaSession::
InternalGalleryMediaSession(
    const InternalGalleryMediaConfig& config)
    : config_(config),
      queue_(
          config.queueCapacity == 0
              ? 1
              : config.queueCapacity),
      scheduler_(config.maxLatenessNs) {}

InternalGalleryMediaSession::
~InternalGalleryMediaSession() {
    if (driver_) {
        driver_->stop();
    }
    if (source_) {
        source_->stop();
    }
}

bool InternalGalleryMediaSession::selectVideo(
    const std::string& localPath,
    bool loopEnabled) {
    stopActiveSourceForReplacement();

    auto reader =
        std::make_unique<LocalVideoReader>(
            state_);

    LocalVideoReaderConfig readerConfig;
    readerConfig.loopEnabled =
        loopEnabled;
    readerConfig.outputPixelFormat =
        config_.videoPixelFormat;

    if (!reader->open(
            localPath,
            readerConfig)) {
        lastVideoReaderErrorCode_ =
            reader->lastErrorCode();
        const std::string message =
            reader->lastErrorMessage();
        clearFailedSelection(
            message.empty()
                ? "Unable to open selected local video."
                : message);
        return false;
    }

    videoReader_ = reader.get();
    lastVideoReaderErrorCode_ =
        videoReader_->lastErrorCode();
    source_ = std::move(reader);

    selected_ = {
        SelectedMediaKind::Video,
        localPath,
        state_.mediaGeneration(),
        true,
    };

    queue_.purgeGeneration(
        state_.mediaGeneration());
    scheduler_.reset();
    installPipelineForActiveSource();

    setStatus("Video selected.");
    return pump_ != nullptr &&
           driver_ != nullptr &&
           driver_->valid();
}

bool InternalGalleryMediaSession::selectPhoto(
    const std::string& localPath) {
    stopActiveSourceForReplacement();

    auto reader =
        std::make_unique<LocalPhotoReader>(
            state_);

    if (!reader->open(
            localPath,
            config_.photo)) {
        const std::string message =
            reader->lastErrorMessage();
        clearFailedSelection(
            message.empty()
                ? "Unable to open selected local photo."
                : message);
        return false;
    }

    photoReader_ = reader.get();
    source_ = std::move(reader);

    selected_ = {
        SelectedMediaKind::Photo,
        localPath,
        state_.mediaGeneration(),
        true,
    };

    queue_.purgeGeneration(
        state_.mediaGeneration());
    scheduler_.reset();
    installPipelineForActiveSource();

    setStatus("Photo selected.");
    return pump_ != nullptr &&
           driver_ != nullptr &&
           driver_->valid();
}

bool InternalGalleryMediaSession::start() {
    if (!source_ ||
        !driver_ ||
        !selected_.valid) {
        setStatus(
            "Select local media before starting playback.");
        return false;
    }

    if (!source_->start()) {
        if (videoReader_ != nullptr) {
            lastVideoReaderErrorCode_ =
                videoReader_->lastErrorCode();
        }
        setStatus(
            "Selected media source failed to start.");
        return false;
    }

    if (videoReader_ != nullptr) {
        lastVideoReaderErrorCode_ =
            videoReader_->lastErrorCode();
    }

    if (!driver_->start()) {
        state_.markPlaybackFailed();
        setStatus(
            "Frame producer failed to start.");
        return false;
    }

    setStatus(
        selected_.kind ==
                SelectedMediaKind::Photo
            ? "Photo playback active."
            : "Video playback active.");
    return true;
}

bool InternalGalleryMediaSession::pause() {
    if (state_.playbackState() !=
        frame_engine::PlaybackState::Playing) {
        setStatus(
            "Playback is not currently playing.");
        return false;
    }

    if (driver_) {
        driver_->stop();
    }

    if (!state_.pause()) {
        setStatus(
            "Playback state rejected pause.");
        return false;
    }

    setStatus("Playback paused.");
    return true;
}

bool InternalGalleryMediaSession::resume() {
    if (!driver_ ||
        state_.playbackState() !=
            frame_engine::PlaybackState::Paused) {
        setStatus(
            "Playback is not paused.");
        return false;
    }

    if (!state_.resume() ||
        !driver_->start()) {
        state_.markPlaybackFailed();
        setStatus(
            "Playback failed to resume.");
        return false;
    }

    setStatus("Playback resumed.");
    return true;
}

bool InternalGalleryMediaSession::
setMediaTransform(
    const PhotoTransformState& transform) {
    const bool photoSelected =
        selected_.kind ==
            SelectedMediaKind::Photo;
    const bool videoSelected =
        selected_.kind ==
            SelectedMediaKind::Video;

    if (!selected_.valid ||
        (!photoSelected && !videoSelected) ||
        (photoSelected && photoReader_ == nullptr) ||
        (videoSelected && videoReader_ == nullptr) ||
        pump_ == nullptr ||
        driver_ == nullptr) {
        setStatus(
            "Media transform requires selected local media.");
        return false;
    }

    const PhotoTransformState normalized =
        NormalizePhotoTransformState(
            transform);
    const PhotoTransformState current =
        transformer_.photoTransform();

    if (current.translationX ==
            normalized.translationX &&
        current.translationY ==
            normalized.translationY &&
        current.scale ==
            normalized.scale) {
        return true;
    }

    const auto playback =
        state_.playbackState();

    // Quiesce only F2 for live VIDEO. AVAssetReader, selection generation,
    // source PTS and the F1 timeline remain intact.
    if (videoSelected &&
        playback ==
            frame_engine::PlaybackState::Playing) {
        driver_->stop();
        pump_->
            discardPendingTimedFrameForTransformUpdate();
    }

    transformer_.setPhotoTransform(
        normalized);
    pump_->setForceTransform(
        transformer_.
            hasNonDefaultPhotoTransform());

    queue_.clear();

    if (photoSelected) {
        // Preserve the already-certified PHOTO republish semantics.
        scheduler_.reset();
    }

    if (playback ==
        frame_engine::PlaybackState::Playing) {
        if (!driver_->start()) {
            setStatus(
                photoSelected
                    ? "Unable to republish transformed photo."
                    : "Unable to continue transformed video.");
            return false;
        }
    } else if (
        playback ==
        frame_engine::PlaybackState::Paused &&
        photoSelected) {
        const auto result =
            pump_->pumpOnce();
        if (result.status !=
            FramePipelinePumpStatus::Published) {
            setStatus(
                "Unable to refresh paused photo transform.");
            return false;
        }
    }

    setStatus(
        videoSelected &&
                playback ==
                    frame_engine::PlaybackState::Paused
            ? "Video position / zoom queued for resume."
            : "Media position / zoom updated.");
    return true;
}

bool InternalGalleryMediaSession::
setPhotoTransform(
    const PhotoTransformState& transform) {
    return setMediaTransform(
        transform);
}

bool InternalGalleryMediaSession::
preparePhotoVariant(
    const NormalizationTarget& target) {
    if (selected_.kind !=
            SelectedMediaKind::Photo ||
        photoReader_ == nullptr ||
        pump_ == nullptr ||
        driver_ == nullptr) {
        setStatus(
            "Photo variant requires a selected photo.");
        return false;
    }

    frame_engine::QueueContext context;
    context.currentMediaGeneration =
        state_.mediaGeneration();
    context.currentTimelineEpoch =
        state_.timelineEpoch();

    if (queue_.hasEligibleMatching(
            context,
            target.width,
            target.height,
            target.pixelFormat)) {
        return true;
    }

    // Static PHOTO preparation is producer/control-side only. Stop the
    // single-publication wakeup driver before retargeting the shared pump so
    // there is never concurrent producer work.
    driver_->stop();

    config_.target = target;
    pump_->setTarget(target);
    pump_->setForceTransform(
        transformer_.
            hasNonDefaultPhotoTransform());
    scheduler_.reset();

    const auto result =
        pump_->pumpOnce();
    if (result.status !=
        FramePipelinePumpStatus::Published) {
        setStatus(
            "Unable to prepare requested photo geometry.");
        return false;
    }

    if (photoVariantPreparationCount_ !=
        UINT64_MAX) {
        ++photoVariantPreparationCount_;
    }

    setStatus(
        "Photo geometry variant prepared.");
    return true;
}

bool InternalGalleryMediaSession::
invalidatePhotoPreparedOutputs() {
    if (selected_.kind !=
            SelectedMediaKind::Photo ||
        photoReader_ == nullptr ||
        pump_ == nullptr ||
        driver_ == nullptr) {
        return false;
    }

    driver_->stop();
    queue_.clear();
    scheduler_.reset();
    return true;
}

bool InternalGalleryMediaSession::
hasQueuedPhotoVariant(
    const NormalizationTarget& target) const {
    if (selected_.kind !=
            SelectedMediaKind::Photo) {
        return false;
    }

    frame_engine::QueueContext context;
    context.currentMediaGeneration =
        state_.mediaGeneration();
    context.currentTimelineEpoch =
        state_.timelineEpoch();

    return queue_.hasEligibleMatching(
        context,
        target.width,
        target.height,
        target.pixelFormat);
}

bool InternalGalleryMediaSession::
retargetVideoOutput(
    const NormalizationTarget& target) {
    if (selected_.kind !=
            SelectedMediaKind::Video ||
        videoReader_ == nullptr ||
        pump_ == nullptr ||
        driver_ == nullptr) {
        setStatus(
            "Video output retarget requires a selected video.");
        return false;
    }

    if (target.width == 0 ||
        target.height == 0 ||
        target.pixelFormat == 0) {
        setStatus(
            "Video output retarget rejected an invalid target.");
        return false;
    }

    const NormalizationTarget current =
        pump_->target();
    if (current.width == target.width &&
        current.height == target.height &&
        current.pixelFormat ==
            target.pixelFormat &&
        current.orientation ==
            target.orientation &&
        current.colorMetadata ==
            target.colorMetadata) {
        return true;
    }

    const auto playback =
        state_.playbackState();

    // Producer-side retarget only. Stopping the wakeup driver does not stop
    // or recreate LocalVideoReader/AVAssetReader and does not change the
    // FrameEngine media generation or timeline epoch.
    driver_->stop();
    queue_.clear();

    config_.target = target;
    pump_->setTargetPreservingTimeline(
        target);

    if (playback ==
        frame_engine::PlaybackState::Playing) {
        if (!driver_->start()) {
            setStatus(
                "Unable to resume video producer after output retarget.");
            return false;
        }
    }

    setStatus(
        "Video output target updated without reopening source.");
    return true;
}

bool InternalGalleryMediaSession::
setVideoLoopEnabled(bool enabled) {
    if (videoReader_ == nullptr ||
        selected_.kind !=
            SelectedMediaKind::Video) {
        setStatus(
            "Loop applies only to the selected video.");
        return false;
    }

    videoReader_->setLoopEnabled(
        enabled);
    setStatus(
        enabled
            ? "Video loop enabled."
            : "Video loop disabled.");
    return true;
}

void InternalGalleryMediaSession::clearMedia() {
    if (driver_) {
        driver_->stop();
    }
    if (source_) {
        source_->stop();
    }

    driver_.reset();
    pump_.reset();
    source_.reset();
    videoReader_ = nullptr;
    photoReader_ = nullptr;
    lastVideoReaderErrorCode_ =
        frame_engine::ReaderErrorCode::None;

    state_.clearMedia();
    scheduler_.reset();
    queue_.purgeGeneration(
        state_.mediaGeneration());

    selected_ = {};
    setStatus("No media selected.");
}

const SelectedMediaRecord&
InternalGalleryMediaSession::
selectedMedia() const noexcept {
    return selected_;
}

const std::string&
InternalGalleryMediaSession::
statusMessage() const noexcept {
    return statusMessage_;
}

frame_engine::PlaybackState
InternalGalleryMediaSession::
playbackState() const noexcept {
    return state_.playbackState();
}

NormalizationTarget
InternalGalleryMediaSession::
currentTarget() const noexcept {
    return config_.target;
}

frame_engine::FrameEngineState&
InternalGalleryMediaSession::state() noexcept {
    return state_;
}

frame_engine::ReadyFrameQueue&
InternalGalleryMediaSession::
readyQueue() noexcept {
    return queue_;
}

const frame_engine::ReadyFrameQueue&
InternalGalleryMediaSession::
readyQueue() const noexcept {
    return queue_;
}

ProducerWakeupDriverState InternalGalleryMediaSession::
producerDriverState() const {
    return driver_
        ? driver_->state()
        : ProducerWakeupDriverState::Stopped;
}

std::optional<FramePipelinePumpStatus>
InternalGalleryMediaSession::lastPumpStatus() const {
    return driver_
        ? driver_->lastPumpStatus()
        : std::nullopt;
}

std::uint64_t InternalGalleryMediaSession::
publishedFrameCount() const {
    return driver_
        ? driver_->publishedFrameCount()
        : 0;
}

bool InternalGalleryMediaSession::
videoReaderOpen() const noexcept {
    return videoReader_ != nullptr &&
           videoReader_->isOpen();
}

bool InternalGalleryMediaSession::
videoReaderStarted() const noexcept {
    return videoReader_ != nullptr &&
           videoReader_->isStarted();
}

frame_engine::ReaderErrorCode
InternalGalleryMediaSession::
videoReaderErrorCode() const noexcept {
    return videoReader_ != nullptr
        ? videoReader_->lastErrorCode()
        : lastVideoReaderErrorCode_;
}

ProducerRuntimeDiagnosticsSnapshot
InternalGalleryMediaSession::
producerRuntimeDiagnostics() const {
    return driver_
        ? driver_->runtimeDiagnostics()
        : ProducerRuntimeDiagnosticsSnapshot{};
}

std::uint64_t InternalGalleryMediaSession::
photoDecodeCount() const noexcept {
    return photoReader_
        ? photoReader_->decodeCount()
        : 0;
}

std::uint64_t InternalGalleryMediaSession::
photoVariantPreparationCount() const noexcept {
    return photoVariantPreparationCount_;
}

#if defined(VCAM_TESTING)
void InternalGalleryMediaSession::
stopProducerForTesting() {
    if (driver_) {
        driver_->stop();
    }
}
#endif

void InternalGalleryMediaSession::
stopActiveSourceForReplacement() {
    if (driver_) {
        driver_->stop();
    }
    if (source_) {
        source_->stop();
    }

    driver_.reset();
    pump_.reset();
    source_.reset();
    videoReader_ = nullptr;
    photoReader_ = nullptr;
    lastVideoReaderErrorCode_ =
        frame_engine::ReaderErrorCode::None;
    selected_ = {};
}

void InternalGalleryMediaSession::
clearFailedSelection(
    const std::string& message) {
    source_.reset();
    videoReader_ = nullptr;
    photoReader_ = nullptr;
    pump_.reset();
    driver_.reset();

    state_.clearMedia();
    scheduler_.reset();
    queue_.purgeGeneration(
        state_.mediaGeneration());

    selected_ = {};
    setStatus(message);
}

void InternalGalleryMediaSession::
installPipelineForActiveSource() {
    if (!source_) {
        return;
    }

    pump_ =
        std::make_unique<FramePipelinePump>(
            state_,
            *source_,
            normalizer_,
            transformer_,
            scheduler_,
            queue_,
            config_.target);
    pump_->setForceTransform(
        selected_.kind !=
                SelectedMediaKind::None &&
        transformer_.
            hasNonDefaultPhotoTransform());

    driver_ =
        std::make_unique<ProducerWakeupDriver>(
            state_,
            *pump_,
            config_.producer);
}

void InternalGalleryMediaSession::setStatus(
    const std::string& message) {
    statusMessage_ = message;
}

}  // namespace vcam::media_engine
