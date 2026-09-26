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
        const std::string message =
            reader->lastErrorMessage();
        clearFailedSelection(
            message.empty()
                ? "Unable to open selected local video."
                : message);
        return false;
    }

    videoReader_ = reader.get();
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
        setStatus(
            "Selected media source failed to start.");
        return false;
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

frame_engine::FrameEngineState&
InternalGalleryMediaSession::state() noexcept {
    return state_;
}

frame_engine::ReadyFrameQueue&
InternalGalleryMediaSession::
readyQueue() noexcept {
    return queue_;
}

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
