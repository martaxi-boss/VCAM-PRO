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
            true);
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
#if defined(VCAM_LOCAL_PHOTO_PIPELINE_READY_PROOF)
                                this->beginOrRefreshLocalPhotoDiagnostic();
#endif
                                this->applyCachedState(
                                    false);
#if defined(VCAM_LOCAL_PHOTO_PIPELINE_READY_PROOF)
                                this->evaluateLocalPhotoDiagnostic(
                                    false);
#endif
                            });
                    }
                })) {
            return false;
        }

        dispatch_sync(
            controlQueue_,
            ^{
#if defined(VCAM_LOCAL_PHOTO_PIPELINE_READY_PROOF)
                this->beginOrRefreshLocalPhotoDiagnostic();
#endif
                this->applyCachedState(
                    true);
#if defined(VCAM_LOCAL_PHOTO_PIPELINE_READY_PROOF)
                this->evaluateLocalPhotoDiagnostic(
                    false);
#endif
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
#if defined(VCAM_LOCAL_PHOTO_PIPELINE_READY_PROOF)
                this->evaluateLocalPhotoDiagnostic(
                    false);
#endif
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
            facts.callbackExercised = true;
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
            facts.virtualDecisionCount =
                virtualDecisionCountAfter;

            proof::ObserveLocalPhotoCallbackPhase(
                facts);

            if (controlQueue_ != nullptr) {
                dispatch_async(
                    controlQueue_,
                    ^{
                        this->evaluateLocalPhotoDiagnostic(
                            false);
                    });
            }
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
#if defined(VCAM_LOCAL_PHOTO_PIPELINE_READY_PROOF)
            recordLocalPhotoFailureStage(
                snapshot.selectionGeneration,
                proof::LocalPhotoProofPipelineStage::
                    PhotoSelectFailed);
            evaluateLocalPhotoDiagnostic(
                false);
#endif
            return;
        }

        bool producerHealthy = false;

        if (snapshot.playbackIntent ==
            ProductPlaybackIntent::Playing) {
            producerHealthy =
                candidate->start();
            if (!producerHealthy) {
                adapter_.unbindQueue();
#if defined(VCAM_LOCAL_PHOTO_PIPELINE_READY_PROOF)
                recordLocalPhotoFailureStage(
                    snapshot.selectionGeneration,
                    proof::LocalPhotoProofPipelineStage::
                        ProducerStartFailed);
                recordLocalPhotoProducerState(
                    snapshot.selectionGeneration,
                    false);
                evaluateLocalPhotoDiagnostic(
                    false);
#endif
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
#if defined(VCAM_LOCAL_PHOTO_PIPELINE_READY_PROOF)
        const ProductControlSnapshot proofSnapshot =
            cache_.snapshot();
        recordLocalPhotoProducerState(
            proofSnapshot.selectionGeneration,
            producerHealthy);
#endif

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
        kPhotoDiagnosticMaxPeriodicChecks =
            120;
    static constexpr std::int64_t
        kPhotoDiagnosticRetryNanoseconds =
            INT64_C(250000000);
    static constexpr std::uint32_t
        kPhotoDiagnosticWindowSeconds =
            30;

    static proof::LocalPhotoProofMediaKind
    proofMediaKind(
        ProductMediaKind value) noexcept {
        switch (value) {
            case ProductMediaKind::Photo:
                return proof::
                    LocalPhotoProofMediaKind::Photo;
            case ProductMediaKind::Video:
                return proof::
                    LocalPhotoProofMediaKind::Video;
            case ProductMediaKind::None:
            default:
                return proof::
                    LocalPhotoProofMediaKind::None;
        }
    }

    static proof::LocalPhotoProofMediaKind
    proofSelectedMediaKind(
        media_engine::SelectedMediaKind value) noexcept {
        switch (value) {
            case media_engine::SelectedMediaKind::Photo:
                return proof::
                    LocalPhotoProofMediaKind::Photo;
            case media_engine::SelectedMediaKind::Video:
                return proof::
                    LocalPhotoProofMediaKind::Video;
            case media_engine::SelectedMediaKind::None:
            default:
                return proof::
                    LocalPhotoProofMediaKind::None;
        }
    }

    static proof::LocalPhotoProofPlaybackIntent
    proofPlaybackIntent(
        ProductPlaybackIntent value) noexcept {
        switch (value) {
            case ProductPlaybackIntent::Playing:
                return proof::
                    LocalPhotoProofPlaybackIntent::Playing;
            case ProductPlaybackIntent::Paused:
                return proof::
                    LocalPhotoProofPlaybackIntent::Paused;
            case ProductPlaybackIntent::Stopped:
            default:
                return proof::
                    LocalPhotoProofPlaybackIntent::Stopped;
        }
    }

    static proof::LocalPhotoProofPlaybackState
    proofPlaybackState(
        frame_engine::PlaybackState value) noexcept {
        switch (value) {
            case frame_engine::PlaybackState::Empty:
                return proof::
                    LocalPhotoProofPlaybackState::Empty;
            case frame_engine::PlaybackState::Ready:
                return proof::
                    LocalPhotoProofPlaybackState::Ready;
            case frame_engine::PlaybackState::Playing:
                return proof::
                    LocalPhotoProofPlaybackState::Playing;
            case frame_engine::PlaybackState::Paused:
                return proof::
                    LocalPhotoProofPlaybackState::Paused;
            case frame_engine::PlaybackState::Ended:
                return proof::
                    LocalPhotoProofPlaybackState::Ended;
            case frame_engine::PlaybackState::Failed:
                return proof::
                    LocalPhotoProofPlaybackState::Failed;
            default:
                return proof::
                    LocalPhotoProofPlaybackState::Unknown;
        }
    }

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

    void beginOrRefreshLocalPhotoDiagnostic() {
        if (controlQueue_ == nullptr) {
            return;
        }

        const ProductControlSnapshot snapshot =
            cache_.snapshot();
        const bool activePhoto =
            snapshot.mediaKind ==
                ProductMediaKind::Photo &&
            snapshot.hasMedia() &&
            snapshot.selectionGeneration != 0;

        if (!activePhoto) {
            if (proofDiagnosticActive_) {
                proofDiagnosticActive_ = false;
                ++proofDiagnosticSerial_;
                proofPipelineStage_ =
                    proof::
                        LocalPhotoProofPipelineStage::
                            ControlSuperseded;
            }
            return;
        }

        if (proofDiagnosticActive_ &&
            proofDiagnosticGeneration_ ==
                snapshot.selectionGeneration &&
            proofDiagnosticPath_ ==
                snapshot.mediaPath) {
            return;
        }

        ++proofDiagnosticSerial_;
        proofDiagnosticActive_ = true;
        proofDiagnosticGeneration_ =
            snapshot.selectionGeneration;
        proofDiagnosticPath_ =
            snapshot.mediaPath;
        proofDiagnosticPeriodicChecks_ = 0;
        proofMediaStaged_ =
            proofStager_.
                isExistingOwnedMediaPath(
                    snapshot.mediaPath);
        proofProducerGeneration_ = 0;
        proofProducerHealthy_ = false;
        proofPipelineStage_ =
            proof::
                LocalPhotoProofPipelineStage::
                    WaitingControl;

        const std::uint64_t serial =
            proofDiagnosticSerial_;
        const std::uint64_t generation =
            proofDiagnosticGeneration_;

        evaluateLocalPhotoDiagnostic(
            false);
        scheduleLocalPhotoDiagnosticFallback(
            generation,
            serial);
    }

    void scheduleLocalPhotoDiagnosticFallback(
        std::uint64_t selectionGeneration,
        std::uint64_t serial) {
        if (!proofDiagnosticActive_ ||
            proofDiagnosticGeneration_ !=
                selectionGeneration ||
            proofDiagnosticSerial_ != serial) {
            return;
        }

        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                kPhotoDiagnosticRetryNanoseconds),
            controlQueue_,
            ^{
                if (!this->proofDiagnosticActive_ ||
                    this->proofDiagnosticGeneration_ !=
                        selectionGeneration ||
                    this->proofDiagnosticSerial_ !=
                        serial) {
                    return;
                }

                ++this->proofDiagnosticPeriodicChecks_;

                const bool timeout =
                    this->proofDiagnosticPeriodicChecks_ >=
                    kPhotoDiagnosticMaxPeriodicChecks;

                this->evaluateLocalPhotoDiagnostic(
                    timeout);

                if (this->proofDiagnosticActive_ &&
                    !timeout) {
                    this->
                        scheduleLocalPhotoDiagnosticFallback(
                            selectionGeneration,
                            serial);
                }
            });
    }

    void recordLocalPhotoFailureStage(
        std::uint64_t selectionGeneration,
        proof::LocalPhotoProofPipelineStage
            stage) noexcept {
        if (proofDiagnosticActive_ &&
            proofDiagnosticGeneration_ ==
                selectionGeneration) {
            proofPipelineStage_ = stage;
        }
    }

    void recordLocalPhotoProducerState(
        std::uint64_t selectionGeneration,
        bool producerHealthy) noexcept {
        proofProducerGeneration_ =
            selectionGeneration;
        proofProducerHealthy_ =
            producerHealthy;
    }

    proof::LocalPhotoDiagnosticSnapshot
    currentLocalPhotoDiagnosticSnapshot() {
        proof::LocalPhotoDiagnosticSnapshot facts;

        const ProductControlSnapshot snapshot =
            cache_.snapshot();

        facts.selectionGeneration =
            proofDiagnosticGeneration_;
        facts.vcamEnabled =
            snapshot.enabled;
        facts.mediaKind =
            proofMediaKind(
                snapshot.mediaKind);
        facts.hasMedia =
            snapshot.hasMedia();
        facts.mediaStaged =
            proofMediaStaged_;
        facts.controlObserved =
            proofObservedControlGeneration_.load(
                std::memory_order_acquire) ==
            proofDiagnosticGeneration_;
        facts.cameraGeometryObserved =
            observedGeometry_.load(
                std::memory_order_acquire) != 0;
        facts.sessionExists =
            session_ != nullptr;
        facts.playbackIntent =
            proofPlaybackIntent(
                snapshot.playbackIntent);
        facts.producerReady =
            proofProducerGeneration_ ==
                proofDiagnosticGeneration_ &&
            proofProducerHealthy_;

        if (session_ != nullptr) {
            const auto& selected =
                session_->selectedMedia();

            facts.selectedMediaValid =
                selected.valid;
            facts.selectedMediaKind =
                proofSelectedMediaKind(
                    selected.kind);
            facts.selectedMediaPathMatches =
                selected.localPath ==
                proofDiagnosticPath_;
            facts.playbackState =
                proofPlaybackState(
                    session_->playbackState());
            facts.readyFrameCount =
                session_->readyQueue().size();
        }

        proof::LocalPhotoCallbackSnapshot callback;
        if (proof::ReadLocalPhotoCallbackSnapshot(
                proofDiagnosticGeneration_,
                &callback)) {
            facts.callbackExercised =
                callback.callbackExercised;
            facts.originalNonNull =
                callback.originalNonNull;
            facts.decisionOriginal =
                callback.decisionOriginal;
            facts.disabledReason =
                callback.disabledReason;
            facts.originalBufferReturned =
                callback.originalBufferReturned;
        }

        facts.virtualDecisionCount =
            adapter_.virtualDecisionCount();

        if (snapshot.selectionGeneration !=
                proofDiagnosticGeneration_ ||
            snapshot.mediaKind !=
                ProductMediaKind::Photo ||
            !snapshot.hasMedia() ||
            snapshot.mediaPath !=
                proofDiagnosticPath_) {
            facts.pipelineStage =
                proof::
                    LocalPhotoProofPipelineStage::
                        ControlSuperseded;
        } else if (snapshot.enabled) {
            facts.pipelineStage =
                proof::
                    LocalPhotoProofPipelineStage::
                        VcamUnexpectedlyEnabled;
        } else if (!facts.controlObserved) {
            facts.pipelineStage =
                proof::
                    LocalPhotoProofPipelineStage::
                        WaitingControl;
        } else if (!facts.mediaStaged) {
            facts.pipelineStage =
                proof::
                    LocalPhotoProofPipelineStage::
                        MediaStagingMismatch;
        } else if (!facts.cameraGeometryObserved) {
            facts.pipelineStage =
                proof::
                    LocalPhotoProofPipelineStage::
                        WaitingGeometry;
        } else if (
            proofPipelineStage_ ==
                proof::
                    LocalPhotoProofPipelineStage::
                        PhotoSelectFailed ||
            proofPipelineStage_ ==
                proof::
                    LocalPhotoProofPipelineStage::
                        ProducerStartFailed) {
            facts.pipelineStage =
                proofPipelineStage_;
        } else if (!facts.sessionExists) {
            facts.pipelineStage =
                proof::
                    LocalPhotoProofPipelineStage::
                        SessionAbsent;
        } else if (
            !facts.selectedMediaValid ||
            facts.selectedMediaKind !=
                proof::
                    LocalPhotoProofMediaKind::Photo ||
            !facts.selectedMediaPathMatches) {
            facts.pipelineStage =
                proof::
                    LocalPhotoProofPipelineStage::
                        SelectedMediaMismatch;
        } else if (
            facts.playbackIntent !=
                proof::
                    LocalPhotoProofPlaybackIntent::
                        Playing ||
            facts.playbackState !=
                proof::
                    LocalPhotoProofPlaybackState::
                        Playing ||
            !facts.producerReady) {
            facts.pipelineStage =
                proof::
                    LocalPhotoProofPipelineStage::
                        WaitingProducer;
        } else if (
            facts.readyFrameCount == 0) {
            facts.pipelineStage =
                proof::
                    LocalPhotoProofPipelineStage::
                        WaitingReadyFrame;
        } else if (
            !facts.callbackExercised ||
            !facts.originalNonNull ||
            !facts.decisionOriginal ||
            !facts.disabledReason ||
            !facts.originalBufferReturned) {
            facts.pipelineStage =
                proof::
                    LocalPhotoProofPipelineStage::
                        WaitingCallback;
        } else {
            facts.pipelineStage =
                proof::
                    LocalPhotoProofPipelineStage::
                        Ready;
        }

        return facts;
    }

    void evaluateLocalPhotoDiagnostic(
        bool timeout) {
        if (!proofDiagnosticActive_) {
            return;
        }

        proof::LocalPhotoDiagnosticSnapshot facts =
            currentLocalPhotoDiagnosticSnapshot();

        if (facts.pipelineStage ==
            proof::
                LocalPhotoProofPipelineStage::
                    ControlSuperseded) {
            proofDiagnosticActive_ = false;
            ++proofDiagnosticSerial_;
            return;
        }

        const bool pass =
            facts.pipelineStage ==
                proof::
                    LocalPhotoProofPipelineStage::
                        Ready &&
            !facts.vcamEnabled &&
            facts.mediaKind ==
                proof::
                    LocalPhotoProofMediaKind::Photo &&
            facts.mediaStaged &&
            facts.controlObserved &&
            facts.cameraGeometryObserved &&
            facts.sessionExists &&
            facts.selectedMediaValid &&
            facts.selectedMediaKind ==
                proof::
                    LocalPhotoProofMediaKind::Photo &&
            facts.selectedMediaPathMatches &&
            facts.playbackIntent ==
                proof::
                    LocalPhotoProofPlaybackIntent::
                        Playing &&
            facts.playbackState ==
                proof::
                    LocalPhotoProofPlaybackState::
                        Playing &&
            facts.producerReady &&
            facts.readyFrameCount > 0 &&
            facts.callbackExercised &&
            facts.originalNonNull &&
            facts.decisionOriginal &&
            facts.disabledReason &&
            facts.originalBufferReturned &&
            facts.virtualDecisionCount == 0;

        if (pass) {
            if (proof::PublishLocalPhotoPipelineSnapshot(
                    facts,
                    proof::LocalPhotoProofResult::Pass)) {
                proofDiagnosticActive_ = false;
            }
            return;
        }

        if (timeout) {
            if (proof::PublishLocalPhotoPipelineSnapshot(
                    facts,
                    proof::LocalPhotoProofResult::
                        Diagnostic)) {
                proofDiagnosticActive_ = false;
            }
        }
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

    bool proofDiagnosticActive_ = false;
    std::uint64_t
        proofDiagnosticSerial_ = 0;
    std::uint64_t
        proofDiagnosticGeneration_ = 0;
    std::string proofDiagnosticPath_;
    std::uint32_t
        proofDiagnosticPeriodicChecks_ = 0;
    bool proofMediaStaged_ = false;
    std::uint64_t
        proofProducerGeneration_ = 0;
    bool proofProducerHealthy_ = false;
    proof::LocalPhotoProofPipelineStage
        proofPipelineStage_ =
            proof::
                LocalPhotoProofPipelineStage::
                    WaitingControl;
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
