#include "FrameEngineState.h"

namespace vcam::frame_engine {

PlaybackState FrameEngineState::playbackState() const noexcept {
    return playbackState_;
}

ReaderStatus FrameEngineState::readerStatus() const noexcept {
    return readerStatus_;
}

bool FrameEngineState::hasMedia() const noexcept {
    return hasMedia_;
}

std::uint64_t FrameEngineState::mediaGeneration() const noexcept {
    return mediaGeneration_;
}

std::uint64_t FrameEngineState::timelineEpoch() const noexcept {
    return timelineEpoch_;
}

std::uint64_t FrameEngineState::nextSequence() const noexcept {
    return nextSequence_;
}

std::uint64_t FrameEngineState::loopIteration() const noexcept {
    return loopIteration_;
}

void FrameEngineState::selectOrReplaceMedia() {
    hasMedia_ = true;
    ++mediaGeneration_;
    loopIteration_ = 0;
    playbackState_ = PlaybackState::Ready;
    readerStatus_ = {};
    beginNewTimelineEpoch();
}

bool FrameEngineState::start() {
    if (!hasMedia_ ||
        (playbackState_ != PlaybackState::Ready &&
         playbackState_ != PlaybackState::Ended)) {
        return false;
    }

    playbackState_ = PlaybackState::Playing;
    beginNewTimelineEpoch();
    return true;
}

bool FrameEngineState::pause() {
    if (playbackState_ != PlaybackState::Playing) {
        return false;
    }

    playbackState_ = PlaybackState::Paused;
    return true;
}

bool FrameEngineState::resume() {
    if (playbackState_ != PlaybackState::Paused) {
        return false;
    }

    playbackState_ = PlaybackState::Playing;
    beginNewTimelineEpoch();
    return true;
}

bool FrameEngineState::seekOrReload() {
    if (!hasMedia_ ||
        playbackState_ == PlaybackState::Empty ||
        playbackState_ == PlaybackState::Failed) {
        return false;
    }

    if (playbackState_ == PlaybackState::Ended) {
        playbackState_ = PlaybackState::Ready;
    }

    readerStatus_ = {};
    beginNewTimelineEpoch();
    return true;
}

bool FrameEngineState::markEnded() {
    if (playbackState_ != PlaybackState::Playing &&
        playbackState_ != PlaybackState::Paused) {
        return false;
    }

    playbackState_ = PlaybackState::Ended;
    return true;
}

void FrameEngineState::markPlaybackFailed() noexcept {
    playbackState_ = PlaybackState::Failed;
}

bool FrameEngineState::markReaderReady() noexcept {
    if (readerStatus_.state != ReaderState::Uninitialized) {
        return false;
    }

    readerStatus_ = {ReaderState::Ready, ReaderErrorCode::None};
    return true;
}

bool FrameEngineState::beginReading() noexcept {
    if (readerStatus_.state != ReaderState::Ready) {
        return false;
    }

    readerStatus_ = {ReaderState::Reading, ReaderErrorCode::None};
    return true;
}

bool FrameEngineState::markReaderCompleted() noexcept {
    if (readerStatus_.state != ReaderState::Reading) {
        return false;
    }

    readerStatus_ = {ReaderState::Completed, ReaderErrorCode::None};
    return true;
}

void FrameEngineState::markReaderFailed(ReaderErrorCode error) noexcept {
    if (error == ReaderErrorCode::None) {
        error = ReaderErrorCode::Unknown;
    }
    readerStatus_ = {ReaderState::Failed, error};
}

void FrameEngineState::cancelReader() noexcept {
    readerStatus_ = {ReaderState::Cancelled, ReaderErrorCode::Cancelled};
}

bool FrameEngineState::readerIsCompletedEOS() const noexcept {
    return readerStatus_.state == ReaderState::Completed;
}

bool FrameEngineState::canLoopRestart() const noexcept {
    return hasMedia_ && readerIsCompletedEOS();
}

bool FrameEngineState::confirmLoopRestart() noexcept {
    if (!canLoopRestart()) {
        return false;
    }

    ++loopIteration_;
    readerStatus_ = {ReaderState::Ready, ReaderErrorCode::None};
    return true;
}

FrameIdentity FrameEngineState::nextFrameIdentity() noexcept {
    const FrameIdentity identity{
        nextSequence_,
        mediaGeneration_,
        timelineEpoch_,
        loopIteration_,
    };
    ++nextSequence_;
    return identity;
}

void FrameEngineState::beginNewTimelineEpoch() noexcept {
    ++timelineEpoch_;
    nextSequence_ = 0;
}

}  // namespace vcam::frame_engine
