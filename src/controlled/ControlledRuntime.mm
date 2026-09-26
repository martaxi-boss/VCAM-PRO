#include "ControlledRuntime.h"

#include "InternalGalleryMediaSession.h"

#import <Foundation/Foundation.h>

#include <CoreVideo/CoreVideo.h>
#include <dispatch/dispatch.h>

#include <limits>
#include <memory>
#include <utility>

namespace vcam::controlled {

namespace {

bool SameMediaIdentity(
    const product::ProductControlSnapshot& a,
    const product::ProductControlSnapshot& b) {
    return
        a.mediaKind == b.mediaKind &&
        a.mediaPath == b.mediaPath &&
        a.selectionGeneration ==
            b.selectionGeneration;
}

media_engine::InternalGalleryMediaConfig
ControlledMediaConfig() {
    media_engine::InternalGalleryMediaConfig
        config;

    config.target.width = 1280;
    config.target.height = 720;
    config.target.pixelFormat =
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
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
        config.target.pixelFormat;

    config.videoPixelFormat =
        config.target.pixelFormat;

    return config;
}

}  // namespace

ControlledRuntime::ControlledRuntime()
    : store_(
          product::SharedControlStore::
              kDefaultControlPath,
          product::SharedControlStore::
              kDefaultNotification) {}

ControlledRuntime::~ControlledRuntime() {
    stop();
}

bool ControlledRuntime::start() {
    if (started_) {
        return true;
    }

    product::ProductControlSnapshot initial;
    if (!store_.load(&initial)) {
        initial =
            product::ProductControlSnapshot{};
    }

    applySnapshot(initial);

    if (!store_.startObserving(
            [this](
                const product::
                    ProductControlSnapshot&
                        snapshot) {
                dispatch_async(
                    dispatch_get_main_queue(),
                    ^{
                        this->applySnapshot(
                            snapshot);
                    });
            })) {
        consumer_.unbind();
        session_.reset();
        return false;
    }

    started_ = true;
    return true;
}

void ControlledRuntime::stop() {
    if (!started_ &&
        session_ == nullptr) {
        return;
    }

    store_.stopObserving();

    auto cleanup = ^{
        consumer_.setEnabled(false);
        consumer_.unbind();
        session_.reset();
        applied_ = {};
        bumpPresentationSerial();
        started_ = false;
    };

    if ([NSThread isMainThread]) {
        cleanup();
    } else {
        dispatch_sync(
            dispatch_get_main_queue(),
            cleanup);
    }
}

ControlledFrameConsumer&
ControlledRuntime::consumer() noexcept {
    return consumer_;
}

std::uint64_t
ControlledRuntime::
presentationSerial() const noexcept {
    return presentationSerial_.load(
        std::memory_order_acquire);
}

product::ProductControlSnapshot
ControlledRuntime::appliedSnapshot() const {
    return applied_;
}

void ControlledRuntime::applySnapshot(
    const product::
        ProductControlSnapshot& snapshot) {
    consumer_.setEnabled(
        snapshot.enabled);

    if (!snapshot.hasMedia()) {
        consumer_.unbind();
        session_.reset();
        applied_ = snapshot;
        bumpPresentationSerial();
        return;
    }

    if (session_ != nullptr &&
        SameMediaIdentity(
            snapshot,
            applied_)) {
        applyMutableControls(
            snapshot);
        applied_ = snapshot;
        bumpPresentationSerial();
        return;
    }

    auto candidate =
        std::make_unique<
            media_engine::
                InternalGalleryMediaSession>(
                    ControlledMediaConfig());

    bool selected = false;

    if (snapshot.mediaKind ==
        product::ProductMediaKind::Video) {
        selected =
            candidate->selectVideo(
                snapshot.mediaPath,
                snapshot.loopEnabled);
    } else if (
        snapshot.mediaKind ==
        product::ProductMediaKind::Photo) {
        selected =
            candidate->selectPhoto(
                snapshot.mediaPath);
    }

    if (!selected) {
        consumer_.unbind();
        session_.reset();
        applied_ = snapshot;
        bumpPresentationSerial();
        return;
    }

    if (snapshot.playbackIntent ==
        product::
            ProductPlaybackIntent::Playing) {
        if (!candidate->start()) {
            consumer_.unbind();
            session_.reset();
            applied_ = snapshot;
            bumpPresentationSerial();
            return;
        }
    }

    consumer_.unbind();

    auto old =
        std::move(session_);
    session_ =
        std::move(candidate);

    bindCurrentSession();
    applied_ = snapshot;
    bumpPresentationSerial();

    old.reset();
}

void ControlledRuntime::applyMutableControls(
    const product::
        ProductControlSnapshot& snapshot) {
    if (session_ == nullptr) {
        return;
    }

    if (snapshot.mediaKind ==
            product::ProductMediaKind::Video &&
        snapshot.loopEnabled !=
            applied_.loopEnabled) {
        (void)session_->
            setVideoLoopEnabled(
                snapshot.loopEnabled);
    }

    const auto state =
        session_->playbackState();

    if (snapshot.playbackIntent ==
        product::
            ProductPlaybackIntent::Playing) {
        if (state ==
            frame_engine::
                PlaybackState::Paused) {
            (void)session_->resume();
        } else if (
            state ==
                frame_engine::
                    PlaybackState::Ready ||
            state ==
                frame_engine::
                    PlaybackState::Ended) {
            (void)session_->start();
        }
    } else if (
        state ==
            frame_engine::
                PlaybackState::Playing) {
        (void)session_->pause();
    }

    bindCurrentSession();
}

void ControlledRuntime::bindCurrentSession() {
    if (session_ == nullptr) {
        consumer_.unbind();
        return;
    }

    consumer_.bind(
        &session_->readyQueue(),
        session_->state()
            .mediaGeneration(),
        session_->state()
            .timelineEpoch());

    consumer_.setPresentationActive(
        session_->playbackState() ==
            frame_engine::
                PlaybackState::Playing);
}

void ControlledRuntime::
bumpPresentationSerial() noexcept {
    const std::uint64_t previous =
        presentationSerial_.fetch_add(
            1,
            std::memory_order_acq_rel);

    if (previous ==
        std::numeric_limits<
            std::uint64_t>::max()) {
        presentationSerial_.store(
            1,
            std::memory_order_release);
    }
}

}  // namespace vcam::controlled
