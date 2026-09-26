#pragma once

#include "PreparedFrame.h"

#include <cstdint>

namespace vcam::frame_engine {

enum class PlaybackState : std::uint8_t {
    Empty = 0,
    Ready,
    Playing,
    Paused,
    Ended,
    Failed,
};

enum class ReaderState : std::uint8_t {
    Uninitialized = 0,
    Ready,
    Reading,
    Completed,
    Failed,
    Cancelled,
};

enum class ReaderErrorCode : std::uint8_t {
    None = 0,
    InitializationFailed,
    ReadFailed,
    Unsupported,
    Cancelled,
    Unknown,
};

struct ReaderStatus {
    ReaderState state = ReaderState::Uninitialized;
    ReaderErrorCode error = ReaderErrorCode::None;
};

class FrameEngineState final {
public:
    FrameEngineState() = default;

    PlaybackState playbackState() const noexcept;
    ReaderStatus readerStatus() const noexcept;

    bool hasMedia() const noexcept;
    std::uint64_t mediaGeneration() const noexcept;
    std::uint64_t timelineEpoch() const noexcept;
    std::uint64_t nextSequence() const noexcept;
    std::uint64_t loopIteration() const noexcept;

    void selectOrReplaceMedia();
    void clearMedia() noexcept;

    bool start();
    bool pause();
    bool resume();
    bool seekOrReload();
    bool markEnded();
    void markPlaybackFailed() noexcept;

    bool markReaderReady() noexcept;
    bool beginReading() noexcept;
    bool markReaderCompleted() noexcept;
    void markReaderFailed(ReaderErrorCode error) noexcept;
    void cancelReader() noexcept;

    bool readerIsCompletedEOS() const noexcept;
    bool canLoopRestart() const noexcept;
    bool confirmLoopRestart() noexcept;

    FrameIdentity nextFrameIdentity() noexcept;

private:
    void beginNewTimelineEpoch() noexcept;

    PlaybackState playbackState_ = PlaybackState::Empty;
    ReaderStatus readerStatus_{};

    bool hasMedia_ = false;
    std::uint64_t mediaGeneration_ = 0;
    std::uint64_t timelineEpoch_ = 0;
    std::uint64_t nextSequence_ = 0;
    std::uint64_t loopIteration_ = 0;
};

}  // namespace vcam::frame_engine
