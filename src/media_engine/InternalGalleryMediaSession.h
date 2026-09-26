#pragma once

#include "FrameEngineState.h"
#include "FrameNormalizer.h"
#include "FramePipelinePump.h"
#include "FrameTimelineScheduler.h"
#include "FrameTransformer.h"
#include "LocalFrameSource.h"
#include "LocalPhotoReader.h"
#include "LocalVideoReader.h"
#include "ProducerWakeupDriver.h"
#include "ReadyFrameQueue.h"

#include <CoreVideo/CoreVideo.h>

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

namespace vcam::media_engine {

enum class SelectedMediaKind : std::uint8_t {
    None = 0,
    Photo,
    Video,
};

struct SelectedMediaRecord {
    SelectedMediaKind kind =
        SelectedMediaKind::None;
    std::string localPath;
    std::uint64_t selectionGeneration = 0;
    bool valid = false;
};

struct InternalGalleryMediaConfig {
    NormalizationTarget target{};
    std::size_t queueCapacity = 3;
    frame_engine::MonotonicHostTimeNs
        maxLatenessNs = 5'000'000ULL;
    ProducerWakeupDriverConfig producer{};
    LocalPhotoReaderConfig photo{};
    OSType videoPixelFormat =
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
};

class InternalGalleryMediaSession final {
public:
    explicit InternalGalleryMediaSession(
        const InternalGalleryMediaConfig& config);
    ~InternalGalleryMediaSession();

    InternalGalleryMediaSession(
        const InternalGalleryMediaSession&) = delete;
    InternalGalleryMediaSession& operator=(
        const InternalGalleryMediaSession&) = delete;

    bool selectVideo(
        const std::string& localPath,
        bool loopEnabled);
    bool selectPhoto(
        const std::string& localPath);

    bool start();
    bool pause();
    bool resume();
    bool setVideoLoopEnabled(bool enabled);
    void clearMedia();

    const SelectedMediaRecord&
    selectedMedia() const noexcept;
    const std::string&
    statusMessage() const noexcept;

    frame_engine::PlaybackState
    playbackState() const noexcept;

    frame_engine::FrameEngineState&
    state() noexcept;
    frame_engine::ReadyFrameQueue&
    readyQueue() noexcept;

private:
    void stopActiveSourceForReplacement();
    void clearFailedSelection(
        const std::string& message);
    void installPipelineForActiveSource();
    void setStatus(
        const std::string& message);

    InternalGalleryMediaConfig config_{};
    frame_engine::FrameEngineState state_;
    frame_engine::ReadyFrameQueue queue_;
    FrameNormalizer normalizer_;
    FrameTransformer transformer_;
    frame_engine::FrameTimelineScheduler
        scheduler_;

    std::unique_ptr<LocalFrameSource>
        source_;
    LocalVideoReader* videoReader_ = nullptr;
    LocalPhotoReader* photoReader_ = nullptr;
    std::unique_ptr<FramePipelinePump>
        pump_;
    std::unique_ptr<ProducerWakeupDriver>
        driver_;

    SelectedMediaRecord selected_{};
    std::string statusMessage_ =
        "No media selected.";
};

}  // namespace vcam::media_engine
