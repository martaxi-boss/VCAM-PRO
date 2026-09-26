#include "MediaserverdRuntime.h"

#include "ControlStateCache.h"
#include "InternalGalleryMediaSession.h"
#include "SharedControlStore.h"

#import <Foundation/Foundation.h>

#include <CoreVideo/CoreVideo.h>
#include <dispatch/dispatch.h>

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <utility>

namespace vcam::product {

namespace {

std::uint64_t GeometryKey(
    std::size_t width,
    std::size_t height,
    OSType pixelFormat) noexcept {
    if (width > 0xffffU ||
        height > 0xffffU) {
        return 0;
    }

    return
        static_cast<std::uint64_t>(
            width) |
        (static_cast<std::uint64_t>(
             height) << 16U) |
        (static_cast<std::uint64_t>(
             pixelFormat) << 32U);
}

void DecodeGeometryKey(
    std::uint64_t key,
    std::size_t* width,
    std::size_t* height,
    OSType* pixelFormat) noexcept {
    if (width != nullptr) {
        *width =
            static_cast<std::size_t>(
                key & 0xffffU);
    }
    if (height != nullptr) {
        *height =
            static_cast<std::size_t>(
                (key >> 16U) &
                0xffffU);
    }
    if (pixelFormat != nullptr) {
        *pixelFormat =
            static_cast<OSType>(
                key >> 32U);
    }
}

bool SupportedCameraFormat(
    OSType pixelFormat) noexcept {
    return
        pixelFormat ==
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        pixelFormat ==
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
}

bool SameMediaIdentity(
    const ProductControlSnapshot& a,
    const ProductControlSnapshot& b) {
    return
        a.mediaKind == b.mediaKind &&
        a.mediaPath == b.mediaPath &&
        a.selectionGeneration ==
            b.selectionGeneration;
}

}  // namespace

struct MediaserverdRuntime::Impl {
    Impl()
        : store_(
              SharedControlStore::
                  kDefaultControlPath,
              SharedControlStore::
                  kDefaultNotification) {}

    ~Impl() {
        store_.stopObserving();

        if (controlQueue_ != nullptr) {
            dispatch_sync(
                controlQueue_,
                ^{
                    adapter_.unbindQueue();
                    session_.reset();
                });
        }
    }

    bool start() {
        if (started_) {
            return true;
        }

        controlQueue_ =
            dispatch_queue_create(
                "com.vcampro.mediaserverd.control",
                DISPATCH_QUEUE_SERIAL);
        if (controlQueue_ == nullptr) {
            return false;
        }

        ProductControlSnapshot initial;
        if (!store_.load(&initial)) {
            initial =
                ProductControlSnapshot{};
        }

        cache_.replace(initial);
        adapter_.setEnabled(
            initial.enabled);

        if (!store_.startObserving(
                [this](
                    const ProductControlSnapshot&
                        snapshot) {
                    cache_.replace(snapshot);
                    adapter_.setEnabled(
                        snapshot.enabled);

                    if (controlQueue_ !=
                        nullptr) {
                        dispatch_async(
                            controlQueue_,
                            ^{
                                this->applyCachedState(
                                    false);
                            });
                    }
                })) {
            return false;
        }

        dispatch_sync(
            controlQueue_,
            ^{
                this->applyCachedState(
                    true);
            });

        started_ = true;
        return true;
    }

    void observeRealCameraBuffer(
        CVPixelBufferRef buffer) noexcept {
        if (buffer == nullptr ||
            controlQueue_ == nullptr) {
            return;
        }

        const std::size_t width =
            CVPixelBufferGetWidth(buffer);
        const std::size_t height =
            CVPixelBufferGetHeight(buffer);
        const OSType pixelFormat =
            CVPixelBufferGetPixelFormatType(
                buffer);

        if (width == 0 ||
            height == 0 ||
            !SupportedCameraFormat(
                pixelFormat)) {
            return;
        }

        const std::uint64_t key =
            GeometryKey(
                width,
                height,
                pixelFormat);
        if (key == 0) {
            return;
        }

        const std::uint64_t previous =
            observedGeometry_.exchange(
                key,
                std::memory_order_acq_rel);

        if (previous == key) {
            return;
        }

        dispatch_async(
            controlQueue_,
            ^{
                this->applyCachedState(
                    true);
            });
    }

    CameraDecision decide(
        CVPixelBufferRef original) noexcept {
        return adapter_.decide(
            original);
    }

    void applyCachedState(
        bool forceRebuild) {
        const ProductControlSnapshot snapshot =
            cache_.snapshot();

        adapter_.setEnabled(
            snapshot.enabled);

        if (!snapshot.hasMedia()) {
            adapter_.unbindQueue();
            session_.reset();
            applied_ = snapshot;
            return;
        }

        const std::uint64_t geometry =
            observedGeometry_.load(
                std::memory_order_acquire);
        if (geometry == 0) {
            adapter_.unbindQueue();
            applied_ = snapshot;
            return;
        }

        if (!forceRebuild &&
            session_ != nullptr &&
            SameMediaIdentity(
                snapshot,
                applied_)) {
            applyMutableControls(
                snapshot);
            applied_ = snapshot;
            return;
        }

        std::size_t width = 0;
        std::size_t height = 0;
        OSType pixelFormat = 0;
        DecodeGeometryKey(
            geometry,
            &width,
            &height,
            &pixelFormat);

        if (width == 0 ||
            height == 0 ||
            !SupportedCameraFormat(
                pixelFormat)) {
            adapter_.unbindQueue();
            return;
        }

        media_engine::
            InternalGalleryMediaConfig
                config;
        config.target.width = width;
        config.target.height = height;
        config.target.pixelFormat =
            pixelFormat;
        config.target.orientation =
            media_engine::
                OrientationRequirement::
                    UprightIdentityTransform;
        config.target.colorMetadata =
            media_engine::
                ColorMetadataPolicy::
                    PreserveSource;
        config.queueCapacity = 4;
        config.maxLatenessNs =
            5'000'000ULL;
        config.photo.cadenceNumerator =
            30;
        config.photo.cadenceDenominator =
            1;
        config.photo.outputPixelFormat =
            pixelFormat;
        config.videoPixelFormat =
            pixelFormat;

        auto candidate =
            std::make_unique<
                media_engine::
                    InternalGalleryMediaSession>(
                        config);

        bool selected = false;
        if (snapshot.mediaKind ==
            ProductMediaKind::Video) {
            selected =
                candidate->selectVideo(
                    snapshot.mediaPath,
                    snapshot.loopEnabled);
        } else if (
            snapshot.mediaKind ==
            ProductMediaKind::Photo) {
            selected =
                candidate->selectPhoto(
                    snapshot.mediaPath);
        }

        if (!selected) {
            adapter_.unbindQueue();
            return;
        }

        bool producerHealthy = false;

        if (snapshot.playbackIntent ==
            ProductPlaybackIntent::Playing) {
            producerHealthy =
                candidate->start();
            if (!producerHealthy) {
                adapter_.unbindQueue();
                return;
            }
        }

        auto old =
            std::move(session_);
        session_ =
            std::move(candidate);

        bindCurrentSession(
            producerHealthy);

        old.reset();
        applied_ = snapshot;
    }

    void applyMutableControls(
        const ProductControlSnapshot&
            snapshot) {
        if (session_ == nullptr) {
            return;
        }

        if (snapshot.mediaKind ==
                ProductMediaKind::Video &&
            snapshot.loopEnabled !=
                applied_.loopEnabled) {
            (void)session_
                ->setVideoLoopEnabled(
                    snapshot.loopEnabled);
        }

        bool producerHealthy =
            session_->playbackState() ==
            frame_engine::
                PlaybackState::Playing;

        if (snapshot.playbackIntent ==
            ProductPlaybackIntent::Playing) {
            const auto state =
                session_->playbackState();

            if (state ==
                frame_engine::
                    PlaybackState::Paused) {
                producerHealthy =
                    session_->resume();
            } else if (
                state ==
                    frame_engine::
                        PlaybackState::Ready ||
                state ==
                    frame_engine::
                        PlaybackState::Ended) {
                producerHealthy =
                    session_->start();
            }
        } else if (
            session_->playbackState() ==
            frame_engine::
                PlaybackState::Playing) {
            (void)session_->pause();
            producerHealthy = false;
        }

        bindCurrentSession(
            producerHealthy);
    }

    void bindCurrentSession(
        bool producerHealthy) {
        if (session_ == nullptr) {
            adapter_.unbindQueue();
            return;
        }

        adapter_.bindQueue(
            &session_->readyQueue(),
            session_->state()
                .mediaGeneration(),
            session_->state()
                .timelineEpoch(),
            producerHealthy);
    }

    SharedControlStore store_;
    ControlStateCache cache_;
    CameraConsumerAdapter adapter_;

    dispatch_queue_t controlQueue_ =
        nullptr;

    std::unique_ptr<
        media_engine::
            InternalGalleryMediaSession>
        session_;

    ProductControlSnapshot applied_{};

    std::atomic<std::uint64_t>
        observedGeometry_{0};

    bool started_ = false;
};

MediaserverdRuntime::MediaserverdRuntime()
    : impl_(
          std::make_unique<Impl>()) {}

MediaserverdRuntime::~MediaserverdRuntime() =
    default;

MediaserverdRuntime&
MediaserverdRuntime::shared() {
    static MediaserverdRuntime instance;
    return instance;
}

bool MediaserverdRuntime::start() {
    return impl_ &&
           impl_->start();
}

void MediaserverdRuntime::
observeRealCameraBuffer(
    CVPixelBufferRef buffer) noexcept {
    if (impl_) {
        impl_->observeRealCameraBuffer(
            buffer);
    }
}

CameraDecision MediaserverdRuntime::
decideCameraBuffer(
    CVPixelBufferRef original) noexcept {
    if (!impl_) {
        CameraDecision decision;
        decision.pixelBuffer =
            original;
        return decision;
    }

    return impl_->decide(
        original);
}

CameraConsumerAdapter&
MediaserverdRuntime::
cameraAdapter() noexcept {
    return impl_->adapter_;
}

}  // namespace vcam::product
