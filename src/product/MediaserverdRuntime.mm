#include "MediaserverdRuntime.h"

#include "ControlStateCache.h"
#include "InternalGalleryMediaSession.h"
#include "SharedControlStore.h"

#if defined(VCAM_REAL_CAMERA_CALLBACK_PASSTHROUGH_PROOF)
#include "RealCameraCallbackPassThroughProof.h"
#endif

#if defined(VCAM_LOCAL_PHOTO_PIPELINE_READY_PROOF)
#include "LocalPhotoPipelineReadyProof.h"
#include "SharedMediaStager.h"
#endif

#import <Foundation/Foundation.h>

#include <CoreVideo/CoreVideo.h>
#include <dispatch/dispatch.h>

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
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

#if defined(VCAM_REAL_CAMERA_CALLBACK_PASSTHROUGH_PROOF)
        proof::ResetRealCameraCallbackPassThroughProofState();
#endif
#if defined(VCAM_LOCAL_PHOTO_PIPELINE_READY_PROOF)
        proof::ResetLocalPhotoPipelineReadyProofState();
#endif

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
#if defined(VCAM_REAL_CAMERA_CALLBACK_PASSTHROUGH_PROOF)
        proofControlState_.store(
            (initial.enabled ? UINT32_C(0x01) : UINT32_C(0)) |
            (initial.hasMedia() ? UINT32_C(0x02) : UINT32_C(0)),
            std::memory_order_release);
#endif
#if defined(VCAM_LOCAL_PHOTO_PIPELINE_READY_PROOF)
        updateLocalPhotoProofControlSnapshot(
            initial,
            false);
#endif
        adapter_.setEnabled(
            initial.enabled);

        if (!store_.startObserving(
                [this](
                    const ProductControlSnapshot&
                        snapshot) {
                    cache_.replace(snapshot);
#if defined(VCAM_REAL_CAMERA_CALLBACK_PASSTHROUGH_PROOF)
                    proofControlState_.store(
                        (snapshot.enabled ? UINT32_C(0x01) : UINT32_C(0)) |
                        (snapshot.hasMedia() ? UINT32_C(0x02) : UINT32_C(0)),
                        std::memory_order_release);
#endif
#if defined(VCAM_LOCAL_PHOTO_PIPELINE_READY_PROOF)
                    updateLocalPhotoProofControlSnapshot(
                        snapshot,
                        true);
#endif
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
#if defined(VCAM_LOCAL_PHOTO_PIPELINE_READY_PROOF)
        std::uint64_t selectionGeneration = 0;
        std::uint32_t controlFlags = 0;
        const bool controlFactsConsistent =
            loadLocalPhotoProofControlSnapshot(
                &selectionGeneration,
                &controlFlags);

        const std::uint64_t decisionCountBefore =
            adapter_.decisionCount();
        const std::uint64_t virtualDecisionCountBefore =
            adapter_.virtualDecisionCount();

        CameraDecision decision =
            adapter_.decide(
                original);

        const std::uint64_t decisionCountAfter =
            adapter_.decisionCount();
        const std::uint64_t virtualDecisionCountAfter =
            adapter_.virtualDecisionCount();

        if (controlFactsConsistent) {
            proof::LocalPhotoCallbackFacts facts;
            facts.selectionGeneration =
                selectionGeneration;
            facts.originalNonNull =
                original != nullptr;
            facts.vcamDisabled =
                (controlFlags &
                 kPhotoProofControlEnabled) == 0;
            facts.photoSelected =
                (controlFlags &
                 kPhotoProofControlPhoto) != 0;
            facts.hasMedia =
                (controlFlags &
                 kPhotoProofControlHasMedia) != 0;
            facts.decisionOriginal =
                decision.kind ==
                CameraDecisionKind::Original;
            facts.disabledReason =
                decision.reason ==
                CameraFailOpenReason::Disabled;
            facts.originalBufferReturned =
                decision.pixelBuffer == original;
            facts.decisionCountBefore =
                decisionCountBefore;
            facts.decisionCountAfter =
                decisionCountAfter;
            facts.virtualDecisionCountBefore =
                virtualDecisionCountBefore;
            facts.virtualDecisionCountAfter =
                virtualDecisionCountAfter;

            proof::ObserveLocalPhotoCallbackPhase(
                facts);
        }

        return decision;
#elif defined(VCAM_REAL_CAMERA_CALLBACK_PASSTHROUGH_PROOF)
        const std::uint32_t proofControlState =
            proofControlState_.load(
                std::memory_order_acquire);
        const bool controlEnabled =
            (proofControlState & UINT32_C(0x01)) != 0;
        const bool controlHasMedia =
            (proofControlState & UINT32_C(0x02)) != 0;
        const std::uint64_t decisionCountBefore =
            adapter_.decisionCount();
        const std::uint64_t virtualDecisionCountBefore =
            adapter_.virtualDecisionCount();

        CameraDecision decision =
            adapter_.decide(
                original);

        const std::uint64_t decisionCountAfter =
            adapter_.decisionCount();
        const std::uint64_t virtualDecisionCountAfter =
            adapter_.virtualDecisionCount();

        proof::RealCameraCallbackPassThroughFacts facts;
        facts.originalNonNull =
            original != nullptr;
        facts.controlEnabled =
            controlEnabled;
        facts.controlHasMedia =
            controlHasMedia;
        facts.decisionOriginal =
            decision.kind ==
            CameraDecisionKind::Original;
        facts.disabledReason =
            decision.reason ==
            CameraFailOpenReason::Disabled;
        facts.originalBufferReturned =
            decision.pixelBuffer == original;
        facts.decisionCountBefore =
            decisionCountBefore;
        facts.decisionCountAfter =
            decisionCountAfter;
        facts.virtualDecisionCountBefore =
            virtualDecisionCountBefore;
        facts.virtualDecisionCountAfter =
            virtualDecisionCountAfter;

        proof::ObserveRealCameraCallbackPassThroughDecision(
            facts);

        return decision;
#else
        return adapter_.decide(
            original);
#endif
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
#if defined(VCAM_LOCAL_PHOTO_PIPELINE_READY_PROOF)
            beginLocalPhotoReadyCheck(
                snapshot);
#endif
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
#if defined(VCAM_LOCAL_PHOTO_PIPELINE_READY_PROOF)
        beginLocalPhotoReadyCheck(
            snapshot);
#endif
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

#if defined(VCAM_LOCAL_PHOTO_PIPELINE_READY_PROOF)
    static constexpr std::uint32_t
        kPhotoProofControlEnabled =
            UINT32_C(0x01);
    static constexpr std::uint32_t
        kPhotoProofControlPhoto =
            UINT32_C(0x02);
    static constexpr std::uint32_t
        kPhotoProofControlHasMedia =
            UINT32_C(0x04);

    static constexpr std::uint32_t
        kPhotoReadyMaxAttempts = 40;
    static constexpr std::int64_t
        kPhotoReadyRetryNanoseconds =
            INT64_C(100000000);

    void updateLocalPhotoProofControlSnapshot(
        const ProductControlSnapshot& snapshot,
        bool observedByStore) noexcept {
        proofControlSequence_.fetch_add(
            1,
            std::memory_order_acq_rel);

        proofSelectionGeneration_.store(
            snapshot.selectionGeneration,
            std::memory_order_relaxed);

        std::uint32_t flags = 0;
        if (snapshot.enabled) {
            flags |= kPhotoProofControlEnabled;
        }
        if (snapshot.mediaKind ==
            ProductMediaKind::Photo) {
            flags |= kPhotoProofControlPhoto;
        }
        if (snapshot.hasMedia()) {
            flags |= kPhotoProofControlHasMedia;
        }

        proofControlFlags_.store(
            flags,
            std::memory_order_relaxed);

        proofControlSequence_.fetch_add(
            1,
            std::memory_order_release);

        const bool activePhoto =
            snapshot.mediaKind ==
                ProductMediaKind::Photo &&
            snapshot.hasMedia() &&
            snapshot.selectionGeneration != 0;

        if (observedByStore) {
            proofObservedControlGeneration_.store(
                activePhoto
                    ? snapshot.selectionGeneration
                    : 0,
                std::memory_order_release);
        }

        proof::BeginLocalPhotoPipelineSelection(
            activePhoto
                ? snapshot.selectionGeneration
                : 0);

    }

    bool loadLocalPhotoProofControlSnapshot(
        std::uint64_t* selectionGeneration,
        std::uint32_t* flags) const noexcept {
        if (selectionGeneration == nullptr ||
            flags == nullptr) {
            return false;
        }

        for (int attempt = 0;
             attempt < 2;
             ++attempt) {
            const std::uint64_t before =
                proofControlSequence_.load(
                    std::memory_order_acquire);
            if ((before & UINT64_C(1)) != 0) {
                continue;
            }

            const std::uint64_t generation =
                proofSelectionGeneration_.load(
                    std::memory_order_relaxed);
            const std::uint32_t loadedFlags =
                proofControlFlags_.load(
                    std::memory_order_relaxed);

            const std::uint64_t after =
                proofControlSequence_.load(
                    std::memory_order_acquire);

            if (before == after &&
                (after & UINT64_C(1)) == 0) {
                *selectionGeneration =
                    generation;
                *flags = loadedFlags;
                return true;
            }
        }

        return false;
    }

    void beginLocalPhotoReadyCheck(
        const ProductControlSnapshot& snapshot) {
        if (controlQueue_ == nullptr ||
            snapshot.enabled ||
            snapshot.mediaKind !=
                ProductMediaKind::Photo ||
            !snapshot.hasMedia() ||
            snapshot.selectionGeneration == 0 ||
            snapshot.playbackIntent !=
                ProductPlaybackIntent::Playing ||
            session_ == nullptr) {
            return;
        }

        if (proofReadyActive_ &&
            proofReadyGeneration_ ==
                snapshot.selectionGeneration &&
            proofReadyPath_ ==
                snapshot.mediaPath) {
            return;
        }

        const bool mediaStaged =
            proofStager_.
                isExistingOwnedMediaPath(
                    snapshot.mediaPath);
        if (!mediaStaged) {
            return;
        }

        proofReadyActive_ = true;
        proofReadyGeneration_ =
            snapshot.selectionGeneration;
        proofReadyPath_ =
            snapshot.mediaPath;

        checkLocalPhotoReady(
            snapshot.selectionGeneration,
            0);
    }

    void checkLocalPhotoReady(
        std::uint64_t selectionGeneration,
        std::uint32_t attempt) {
        if (!proofReadyActive_ ||
            proofReadyGeneration_ !=
                selectionGeneration) {
            return;
        }

        const ProductControlSnapshot snapshot =
            cache_.snapshot();

        if (snapshot.selectionGeneration !=
                selectionGeneration ||
            snapshot.mediaKind !=
                ProductMediaKind::Photo ||
            !snapshot.hasMedia() ||
            snapshot.mediaPath !=
                proofReadyPath_ ||
            snapshot.enabled ||
            snapshot.playbackIntent !=
                ProductPlaybackIntent::Playing) {
            proofReadyActive_ = false;
            return;
        }

        proof::LocalPhotoReadyFacts facts;
        facts.selectionGeneration =
            selectionGeneration;
        facts.vcamDisabled =
            !snapshot.enabled;
        facts.photoSelected =
            snapshot.mediaKind ==
            ProductMediaKind::Photo;
        facts.mediaPathNonEmpty =
            !snapshot.mediaPath.empty();
        facts.playbackIntentPlaying =
            snapshot.playbackIntent ==
            ProductPlaybackIntent::Playing;
        facts.controlObserved =
            proofObservedControlGeneration_.load(
                std::memory_order_acquire) ==
            selectionGeneration;
        facts.cameraGeometryObserved =
            observedGeometry_.load(
                std::memory_order_acquire) != 0;
        facts.mediaStaged = true;
        facts.sessionExists =
            session_ != nullptr;

        if (session_ != nullptr) {
            const auto& selected =
                session_->selectedMedia();

            facts.selectedMediaValid =
                selected.valid;
            facts.selectedMediaPhoto =
                selected.kind ==
                media_engine::
                    SelectedMediaKind::Photo;
            facts.selectedMediaPathMatches =
                selected.localPath ==
                snapshot.mediaPath;
            facts.producerPlaying =
                session_->playbackState() ==
                frame_engine::
                    PlaybackState::Playing;
            facts.readyFrameCount =
                session_->readyQueue().size();
        }

        facts.virtualDecisionCount =
            adapter_.virtualDecisionCount();

        const bool complete =
            facts.vcamDisabled &&
            facts.photoSelected &&
            facts.mediaPathNonEmpty &&
            facts.playbackIntentPlaying &&
            facts.controlObserved &&
            facts.cameraGeometryObserved &&
            facts.mediaStaged &&
            facts.sessionExists &&
            facts.selectedMediaValid &&
            facts.selectedMediaPhoto &&
            facts.selectedMediaPathMatches &&
            facts.producerPlaying &&
            facts.readyFrameCount > 0 &&
            facts.virtualDecisionCount == 0;

        if (complete) {
            proof::ObserveLocalPhotoReadyPhase(
                facts);
            proofReadyActive_ = false;
            return;
        }

        if (facts.virtualDecisionCount != 0 ||
            attempt + 1 >=
                kPhotoReadyMaxAttempts) {
            proofReadyActive_ = false;
            return;
        }

        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                kPhotoReadyRetryNanoseconds),
            controlQueue_,
            ^{
                this->checkLocalPhotoReady(
                    selectionGeneration,
                    attempt + 1);
            });
    }
#endif

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

#if defined(VCAM_REAL_CAMERA_CALLBACK_PASSTHROUGH_PROOF)
    std::atomic<std::uint32_t>
        proofControlState_{0};
#endif

#if defined(VCAM_LOCAL_PHOTO_PIPELINE_READY_PROOF)
    SharedMediaStager proofStager_;

    std::atomic<std::uint64_t>
        proofControlSequence_{0};
    std::atomic<std::uint64_t>
        proofSelectionGeneration_{0};
    std::atomic<std::uint32_t>
        proofControlFlags_{0};
    std::atomic<std::uint64_t>
        proofObservedControlGeneration_{0};

    bool proofReadyActive_ = false;
    std::uint64_t
        proofReadyGeneration_ = 0;
    std::string proofReadyPath_;
#endif

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
