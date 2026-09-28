#include "MediaserverdRuntime.h"

#include "ControlStateCache.h"
#include "InternalGalleryMediaSession.h"
#include "SharedControlStore.h"
#include "VirtualBlackFrame.h"

#if defined(VCAM_REAL_CAMERA_CALLBACK_PASSTHROUGH_PROOF)
#include "RealCameraCallbackPassThroughProof.h"
#endif

#if defined(VCAM_LOCAL_PHOTO_PIPELINE_READY_PROOF)
#include "LocalPhotoPipelineReadyProof.h"
#include "SharedMediaStager.h"
#endif

#if defined(VCAM_FIRST_LOCAL_PHOTO_VIRTUAL_SUBSTITUTION_PROOF)
#include "FirstLocalPhotoVirtualSubstitutionProof.h"
#endif

#if defined(VCAM_IOS15_ACTIVATION_PARITY_PROOF)
#include "IOS15ActivationParityProof.h"
#endif

#if defined(VCAM_ACTIVATION_PARITY_DEVICE_REMEDIATION_PROOF)
#include "ActivationParityDeviceRemediationProof.h"
#include "SharedMediaStager.h"
#endif

#if defined(VCAM_FIRST_LOCAL_PHOTO_SUBSTITUTION_DIAGNOSTIC_PROOF)
#include "FirstLocalPhotoSubstitutionDiagnosticProof.h"
#include "FirstLocalPhotoSubstitutionDiagnosticProofState.h"
#include <notify.h>
#include <time.h>
#include <unistd.h>
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

media_engine::PhotoTransformState
PhotoTransformForSnapshot(
    const ProductControlSnapshot& snapshot) noexcept {
    media_engine::PhotoTransformState result;
    result.translationX =
        snapshot.photoTransform.translationX;
    result.translationY =
        snapshot.photoTransform.translationY;
    result.scale =
        snapshot.photoTransform.scale;
    return
        media_engine::NormalizePhotoTransformState(
            result);
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
        : Impl(
              SharedControlStore::
                  kDefaultControlPath,
              SharedControlStore::
                  kDefaultNotification) {}

    Impl(
        std::string controlPath,
        std::string notificationName)
        : store_(
              std::move(controlPath),
              std::move(notificationName)) {}

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
#if defined(VCAM_FIRST_LOCAL_PHOTO_VIRTUAL_SUBSTITUTION_PROOF)
        proof::ResetFirstLocalPhotoVirtualSubstitutionProofState();
#endif
#if defined(VCAM_IOS15_ACTIVATION_PARITY_PROOF)
        proof::ResetIOS15ActivationParityProofState();
#endif
#if defined(VCAM_ACTIVATION_PARITY_DEVICE_REMEDIATION_PROOF)
        proof::ResetActivationParityDeviceRemediationProof();
#endif

        controlQueue_ =
            dispatch_queue_create(
                "com.vcampro.mediaserverd.control",
                DISPATCH_QUEUE_SERIAL);
        if (controlQueue_ == nullptr) {
            return false;
        }

#if defined(VCAM_FIRST_LOCAL_PHOTO_SUBSTITUTION_DIAGNOSTIC_PROOF)
        resetFirstPhotoSubstitutionDiagnosticTransport();
#endif

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
#if defined(VCAM_FIRST_LOCAL_PHOTO_VIRTUAL_SUBSTITUTION_PROOF)
        updateFirstPhotoSubstitutionControlSnapshot(
            initial);
#endif
#if defined(VCAM_FIRST_LOCAL_PHOTO_SUBSTITUTION_DIAGNOSTIC_PROOF)
        updateFirstPhotoSubstitutionDiagnosticControlSnapshot(
            initial);
#endif
#if defined(VCAM_IOS15_ACTIVATION_PARITY_PROOF)
        updateIOS15ActivationParityControlSnapshot(
            initial);
#endif
#if defined(VCAM_ACTIVATION_PARITY_DEVICE_REMEDIATION_PROOF)
        updateActivationParityRemediationControlSnapshot(
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
#if defined(VCAM_FIRST_LOCAL_PHOTO_VIRTUAL_SUBSTITUTION_PROOF)
                    updateFirstPhotoSubstitutionControlSnapshot(
                        snapshot);
#endif
#if defined(VCAM_FIRST_LOCAL_PHOTO_SUBSTITUTION_DIAGNOSTIC_PROOF)
                    updateFirstPhotoSubstitutionDiagnosticControlSnapshot(
                        snapshot);
#endif
#if defined(VCAM_IOS15_ACTIVATION_PARITY_PROOF)
                    updateIOS15ActivationParityControlSnapshot(
                        snapshot);
#endif
#if defined(VCAM_ACTIVATION_PARITY_DEVICE_REMEDIATION_PROOF)
                    updateActivationParityRemediationControlSnapshot(
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
#if defined(VCAM_FIRST_LOCAL_PHOTO_SUBSTITUTION_DIAGNOSTIC_PROOF)
                                this->beginOrStopFirstPhotoSubstitutionDiagnostic();
#endif
#if defined(VCAM_ACTIVATION_PARITY_DEVICE_REMEDIATION_PROOF)
                                this->beginOrRefreshActivationParityRemediationDiagnostic();
#endif
                                this->prepareBlackFallbackForObservedGeometry();
                                this->applyCachedState(
                                    false);
#if defined(VCAM_LOCAL_PHOTO_PIPELINE_READY_PROOF)
                                this->evaluateLocalPhotoDiagnostic(
                                    false);
#endif
#if defined(VCAM_FIRST_LOCAL_PHOTO_VIRTUAL_SUBSTITUTION_PROOF)
                                this->beginFirstPhotoSubstitutionReadyCheck();
#endif
                            });
                    }
                })) {
            return false;
        }

        dispatch_sync(
            controlQueue_,
            ^{
                this->prepareBlackFallbackForObservedGeometry();
#if defined(VCAM_LOCAL_PHOTO_PIPELINE_READY_PROOF)
                this->beginOrRefreshLocalPhotoDiagnostic();
#endif
#if defined(VCAM_FIRST_LOCAL_PHOTO_SUBSTITUTION_DIAGNOSTIC_PROOF)
                this->beginOrStopFirstPhotoSubstitutionDiagnostic();
#endif
#if defined(VCAM_ACTIVATION_PARITY_DEVICE_REMEDIATION_PROOF)
                this->beginOrRefreshActivationParityRemediationDiagnostic();
#endif
                this->applyCachedState(
                    true);
#if defined(VCAM_LOCAL_PHOTO_PIPELINE_READY_PROOF)
                this->evaluateLocalPhotoDiagnostic(
                    false);
#endif
#if defined(VCAM_FIRST_LOCAL_PHOTO_VIRTUAL_SUBSTITUTION_PROOF)
                this->beginFirstPhotoSubstitutionReadyCheck();
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

#if defined(VCAM_ACTIVATION_PARITY_DEVICE_REMEDIATION_PROOF)
        if (previous != 0 &&
            previous != key) {
            activationRemediationGeometryChangeCount_.
                fetch_add(
                    1,
                    std::memory_order_acq_rel);
        }
#endif

        if (previous == key) {
            return;
        }

        dispatch_async(
            controlQueue_,
            ^{
                this->prepareBlackFallbackForObservedGeometry();
                this->applyCachedState(
                    true);
#if defined(VCAM_LOCAL_PHOTO_PIPELINE_READY_PROOF)
                this->evaluateLocalPhotoDiagnostic(
                    false);
#endif
#if defined(VCAM_FIRST_LOCAL_PHOTO_VIRTUAL_SUBSTITUTION_PROOF)
                this->beginFirstPhotoSubstitutionReadyCheck();
#endif
            });
    }

    CameraDecision decide(
        CVPixelBufferRef original) noexcept {
#if defined(VCAM_ACTIVATION_PARITY_DEVICE_REMEDIATION_PROOF)
        const std::uint64_t activeGeneration =
            activationRemediationActiveGeneration_.load(
                std::memory_order_acquire);

        CameraDecision decision =
            adapter_.decide(
                original);

        if (activeGeneration != 0 &&
            activationRemediationActiveGeneration_.load(
                std::memory_order_acquire) ==
                activeGeneration) {
            proof::ObserveActivationParityCameraDecision(
                activeGeneration,
                decision,
                original);
        }

        return decision;
#elif defined(VCAM_IOS15_ACTIVATION_PARITY_PROOF)
        std::uint64_t generationBefore = 0;
        std::uint32_t flagsBefore = 0;
        const bool beforeValid =
            loadIOS15ActivationParityControlSnapshot(
                &generationBefore,
                &flagsBefore);

        CameraDecision decision =
            adapter_.decide(
                original);

        std::uint64_t generationAfter = 0;
        std::uint32_t flagsAfter = 0;
        const bool afterValid =
            loadIOS15ActivationParityControlSnapshot(
                &generationAfter,
                &flagsAfter);

        const bool stableControl =
            beforeValid &&
            afterValid &&
            generationBefore ==
                generationAfter &&
            flagsBefore ==
                flagsAfter;

        if (stableControl) {
            bool geometryMatch = false;

            if (original != nullptr &&
                decision.pixelBuffer !=
                    nullptr) {
                geometryMatch =
                    CVPixelBufferGetWidth(
                        original) ==
                        CVPixelBufferGetWidth(
                            decision.pixelBuffer) &&
                    CVPixelBufferGetHeight(
                        original) ==
                        CVPixelBufferGetHeight(
                            decision.pixelBuffer) &&
                    CVPixelBufferGetPixelFormatType(
                        original) ==
                        CVPixelBufferGetPixelFormatType(
                            decision.pixelBuffer);
            }

            const bool enabled =
                (flagsAfter &
                 kActivationControlEnabled) != 0;
            const bool photo =
                (flagsAfter &
                 kActivationControlPhoto) != 0;
            const bool hasMedia =
                (flagsAfter &
                 kActivationControlHasMedia) != 0;

            proof::IOS15ActivationParityFacts facts;
            facts.selectionGeneration =
                generationAfter;
            facts.callbackExercised = true;
            facts.vcamEnabled =
                enabled;
            facts.mediaPhoto =
                photo &&
                hasMedia;
            facts.decisionVirtual =
                decision.kind ==
                CameraDecisionKind::Virtual;
            facts.decisionOriginal =
                decision.kind ==
                CameraDecisionKind::Original;
            facts.decisionReasonNone =
                decision.reason ==
                CameraFailOpenReason::None;
            facts.virtualBufferNonNull =
                decision.pixelBuffer !=
                nullptr;
            facts.virtualBufferDifferentFromOriginal =
                decision.pixelBuffer !=
                    nullptr &&
                decision.pixelBuffer !=
                    original;
            facts.geometryMatch =
                geometryMatch;
            facts.sourceBlack =
                decision.source ==
                CameraDecisionSource::
                    BlackFallback;
            facts.sourcePreparedMedia =
                decision.source ==
                CameraDecisionSource::
                    PreparedMedia;

            if (!enabled &&
                facts.decisionOriginal &&
                decision.source ==
                    CameraDecisionSource::
                        Original) {
                facts.output =
                    IOS15ActivationOutput::
                        Original;
            } else if (
                enabled &&
                facts.decisionVirtual &&
                facts.sourceBlack) {
                facts.output =
                    IOS15ActivationOutput::
                        BlackVirtual;
            } else if (
                enabled &&
                facts.mediaPhoto &&
                facts.decisionVirtual &&
                facts.sourcePreparedMedia) {
                facts.output =
                    IOS15ActivationOutput::
                        PhotoVirtual;
            }

            proof::ObserveIOS15ActivationParity(
                facts);
        }

        return decision;
#elif defined(VCAM_FIRST_LOCAL_PHOTO_SUBSTITUTION_DIAGNOSTIC_PROOF)
        std::uint64_t generationBefore = 0;
        std::uint32_t flagsBefore = 0;
        const bool beforeConsistent =
            loadFirstPhotoSubstitutionDiagnosticControlSnapshot(
                &generationBefore,
                &flagsBefore);
        const std::uint64_t activeBefore =
            firstPhotoSubDiagnosticActiveGeneration_.load(
                std::memory_order_acquire);

        CameraDecision decision =
            adapter_.decide(
                original);

        const std::uint64_t decisionCountAfter =
            adapter_.decisionCount();
        const std::uint64_t virtualDecisionCountAfter =
            adapter_.virtualDecisionCount();

        std::uint64_t generationAfter = 0;
        std::uint32_t flagsAfter = 0;
        const bool afterConsistent =
            loadFirstPhotoSubstitutionDiagnosticControlSnapshot(
                &generationAfter,
                &flagsAfter);
        const std::uint64_t activeAfter =
            firstPhotoSubDiagnosticActiveGeneration_.load(
                std::memory_order_acquire);

        const bool activeStable =
            beforeConsistent &&
            afterConsistent &&
            activeBefore != 0 &&
            activeBefore == activeAfter &&
            activeAfter == generationBefore &&
            generationBefore == generationAfter &&
            flagsBefore == flagsAfter &&
            (flagsAfter &
             kFirstPhotoSubDiagControlEnabled) != 0 &&
            (flagsAfter &
             kFirstPhotoSubDiagControlPhoto) != 0 &&
            (flagsAfter &
             kFirstPhotoSubDiagControlHasMedia) != 0;

        if (activeStable) {
            const std::uint32_t callbackOrdinal =
                reserveFirstPhotoSubstitutionDiagnosticCallback();

            if (callbackOrdinal != 0) {
                firstPhotoSubDiagnosticDecisionCountFinal_.store(
                    decisionCountAfter,
                    std::memory_order_release);
                firstPhotoSubDiagnosticVirtualCountFinal_.store(
                    virtualDecisionCountAfter,
                    std::memory_order_release);

                if (decision.kind ==
                    CameraDecisionKind::Virtual) {
                    firstPhotoSubDiagnosticDecisionVirtualCount_.
                        fetch_add(
                            1,
                            std::memory_order_acq_rel);
                } else {
                    firstPhotoSubDiagnosticDecisionOriginalCount_.
                        fetch_add(
                            1,
                            std::memory_order_acq_rel);
                }

                switch (decision.reason) {
                    case CameraFailOpenReason::Disabled:
                        firstPhotoSubDiagnosticDisabledCount_.
                            fetch_add(
                                1,
                                std::memory_order_acq_rel);
                        break;
                    case CameraFailOpenReason::ReconfigurationContended:
                        firstPhotoSubDiagnosticReconfigurationCount_.
                            fetch_add(
                                1,
                                std::memory_order_acq_rel);
                        break;
                    case CameraFailOpenReason::ProducerUnavailable:
                        firstPhotoSubDiagnosticProducerUnavailableCount_.
                            fetch_add(
                                1,
                                std::memory_order_acq_rel);
                        break;
                    case CameraFailOpenReason::EmptyOrNoEligibleFrame:
                        firstPhotoSubDiagnosticEmptyCount_.
                            fetch_add(
                                1,
                                std::memory_order_acq_rel);
                        break;
                    case CameraFailOpenReason::InvalidLease:
                        firstPhotoSubDiagnosticInvalidLeaseCount_.
                            fetch_add(
                                1,
                                std::memory_order_acq_rel);
                        break;
                    case CameraFailOpenReason::GeometryMismatch:
                        firstPhotoSubDiagnosticGeometryMismatchCount_.
                            fetch_add(
                                1,
                                std::memory_order_acq_rel);
                        break;
                    case CameraFailOpenReason::None:
                    default:
                        break;
                }

                if (original != nullptr) {
                    const std::uint64_t geometryKey =
                        GeometryKey(
                            CVPixelBufferGetWidth(original),
                            CVPixelBufferGetHeight(original),
                            CVPixelBufferGetPixelFormatType(
                                original));
                    if (geometryKey != 0) {
                        const std::uint64_t previousGeometry =
                            firstPhotoSubDiagnosticLastGeometry_.exchange(
                                geometryKey,
                                std::memory_order_acq_rel);
                        if (previousGeometry != 0 &&
                            previousGeometry != geometryKey) {
                            firstPhotoSubDiagnosticGeometryChangeCount_.
                                fetch_add(
                                    1,
                                    std::memory_order_acq_rel);
                        }
                    }
                }

                firstPhotoSubDiagnosticLastDecision_.store(
                    decision.kind ==
                            CameraDecisionKind::Virtual
                        ? static_cast<std::uint32_t>(
                              FirstPhotoSubDiagnosticDecision::Virtual)
                        : static_cast<std::uint32_t>(
                              FirstPhotoSubDiagnosticDecision::Original),
                    std::memory_order_release);
                firstPhotoSubDiagnosticLastReason_.store(
                    firstPhotoSubDiagnosticReasonCode(
                        decision.reason),
                    std::memory_order_release);

                if (decision.kind ==
                        CameraDecisionKind::Virtual &&
                    decision.pixelBuffer != nullptr) {
                    const bool different =
                        decision.pixelBuffer !=
                        original;
                    const bool widthMatch =
                        original != nullptr &&
                        CVPixelBufferGetWidth(
                            decision.pixelBuffer) ==
                            CVPixelBufferGetWidth(
                                original);
                    const bool heightMatch =
                        original != nullptr &&
                        CVPixelBufferGetHeight(
                            decision.pixelBuffer) ==
                            CVPixelBufferGetHeight(
                                original);
                    const bool pixelFormatMatch =
                        original != nullptr &&
                        CVPixelBufferGetPixelFormatType(
                            decision.pixelBuffer) ==
                            CVPixelBufferGetPixelFormatType(
                                original);

                    firstPhotoSubDiagnosticLastVirtualFlags_.store(
                        (UINT32_C(0x01)) |
                        (different
                             ? UINT32_C(0x02)
                             : UINT32_C(0)) |
                        (widthMatch
                             ? UINT32_C(0x04)
                             : UINT32_C(0)) |
                        (heightMatch
                             ? UINT32_C(0x08)
                             : UINT32_C(0)) |
                        (pixelFormatMatch
                             ? UINT32_C(0x10)
                             : UINT32_C(0)) |
                        ((widthMatch &&
                          heightMatch &&
                          pixelFormatMatch)
                             ? UINT32_C(0x20)
                             : UINT32_C(0)),
                        std::memory_order_release);
                }

                if (callbackOrdinal >=
                        kFirstPhotoSubDiagnosticCallbackBudget &&
                    !firstPhotoSubDiagnosticThresholdScheduled_.
                        exchange(
                            true,
                            std::memory_order_acq_rel) &&
                    controlQueue_ != nullptr) {
                    dispatch_async(
                        controlQueue_,
                        ^{
                            this->
                                publishFirstPhotoSubstitutionDiagnosticIfActive(
                                    activeAfter);
                        });
                }
            }
        }

        return decision;
#elif defined(VCAM_FIRST_LOCAL_PHOTO_VIRTUAL_SUBSTITUTION_PROOF)
        std::uint64_t selectionGenerationBefore = 0;
        std::uint32_t controlFlagsBefore = 0;
        const bool controlBeforeConsistent =
            loadFirstPhotoSubstitutionControlSnapshot(
                &selectionGenerationBefore,
                &controlFlagsBefore);
        const std::uint64_t readyGenerationBefore =
            firstPhotoSubstitutionReadyGeneration_.load(
                std::memory_order_acquire);

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

        std::uint64_t selectionGenerationAfter = 0;
        std::uint32_t controlFlagsAfter = 0;
        const bool controlAfterConsistent =
            loadFirstPhotoSubstitutionControlSnapshot(
                &selectionGenerationAfter,
                &controlFlagsAfter);
        const std::uint64_t readyGenerationAfter =
            firstPhotoSubstitutionReadyGeneration_.load(
                std::memory_order_acquire);

        bool geometryMatch = false;
        if (original != nullptr &&
            decision.pixelBuffer != nullptr) {
            geometryMatch =
                CVPixelBufferGetWidth(original) ==
                    CVPixelBufferGetWidth(
                        decision.pixelBuffer) &&
                CVPixelBufferGetHeight(original) ==
                    CVPixelBufferGetHeight(
                        decision.pixelBuffer) &&
                CVPixelBufferGetPixelFormatType(original) ==
                    CVPixelBufferGetPixelFormatType(
                        decision.pixelBuffer);
        }

        const bool stableSelection =
            controlBeforeConsistent &&
            controlAfterConsistent &&
            selectionGenerationBefore != 0 &&
            selectionGenerationBefore ==
                selectionGenerationAfter &&
            controlFlagsBefore ==
                controlFlagsAfter;

        if (stableSelection) {
            proof::FirstLocalPhotoVirtualSubstitutionFacts facts;
            facts.selectionGeneration =
                selectionGenerationAfter;
            facts.originalNonNull =
                original != nullptr;
            facts.vcamEnabled =
                (controlFlagsAfter &
                 kFirstPhotoSubControlEnabled) != 0;
            facts.photoSelected =
                (controlFlagsAfter &
                 kFirstPhotoSubControlPhoto) != 0 &&
                (controlFlagsAfter &
                 kFirstPhotoSubControlHasMedia) != 0;
            facts.mediaReady =
                readyGenerationBefore ==
                    selectionGenerationAfter &&
                readyGenerationAfter ==
                    selectionGenerationAfter;
            facts.cameraGeometryObserved =
                observedGeometry_.load(
                    std::memory_order_acquire) != 0;
            facts.callbackExercised = true;
            facts.decisionVirtual =
                decision.kind ==
                CameraDecisionKind::Virtual;
            facts.decisionReasonNone =
                decision.reason ==
                CameraFailOpenReason::None;
            facts.virtualBufferNonNull =
                decision.pixelBuffer != nullptr;
            facts.virtualBufferDifferentFromOriginal =
                decision.pixelBuffer != nullptr &&
                decision.pixelBuffer != original;
            facts.geometryMatch =
                geometryMatch;
            facts.decisionCountIncremented =
                decisionCountBefore != UINT64_MAX &&
                decisionCountAfter ==
                    decisionCountBefore + 1U;
            facts.virtualDecisionCountIncremented =
                virtualDecisionCountBefore != UINT64_MAX &&
                virtualDecisionCountAfter ==
                    virtualDecisionCountBefore + 1U;
            facts.virtualDecisionCountAfter =
                virtualDecisionCountAfter;

            proof::ObserveFirstLocalPhotoVirtualSubstitution(
                facts);
        }

        return decision;
#elif defined(VCAM_LOCAL_PHOTO_PIPELINE_READY_PROOF)
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

    void prepareBlackFallbackForObservedGeometry() {
        const std::uint64_t geometry =
            observedGeometry_.load(
                std::memory_order_acquire);

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
            adapter_.clearBlackFallback();
            return;
        }

        CVPixelBufferRef black =
            virtualBlackFrame_.prepare(
                width,
                height,
                pixelFormat);

        if (black == nullptr ||
            !adapter_.bindBlackFallback(
                black)) {
            adapter_.clearBlackFallback();
        }
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

#if defined(VCAM_FIRST_LOCAL_PHOTO_SUBSTITUTION_DIAGNOSTIC_PROOF)
        firstPhotoSubDiagnosticTargetGeneration_ =
            snapshot.selectionGeneration;
        firstPhotoSubDiagnosticTargetGeometry_ =
            geometry;
#endif
#if defined(VCAM_ACTIVATION_PARITY_DEVICE_REMEDIATION_PROOF)
        if (activationRemediationActive_ &&
            activationRemediationGeneration_ ==
                snapshot.selectionGeneration) {
            activationRemediationTargetGeneration_ =
                snapshot.selectionGeneration;
            activationRemediationTargetGeometry_ =
                geometry;
        }
#endif

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
        config.producer.singlePublication =
            snapshot.mediaKind ==
                ProductMediaKind::Photo;

        auto candidate =
            std::make_unique<
                media_engine::
                    InternalGalleryMediaSession>(
                        config);

        bool selected = false;
#if defined(VCAM_ACTIVATION_PARITY_DEVICE_REMEDIATION_PROOF)
        if (activationRemediationActive_ &&
            activationRemediationGeneration_ ==
                snapshot.selectionGeneration &&
            snapshot.mediaKind ==
                ProductMediaKind::Photo) {
            activationRemediationSelectAttempted_ =
                true;
        }
#endif
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

#if defined(VCAM_ACTIVATION_PARITY_DEVICE_REMEDIATION_PROOF)
        if (activationRemediationActive_ &&
            activationRemediationGeneration_ ==
                snapshot.selectionGeneration &&
            snapshot.mediaKind ==
                ProductMediaKind::Photo) {
            activationRemediationSelectResult_ =
                selected;
        }
#endif

        if (selected &&
            snapshot.mediaKind ==
                ProductMediaKind::Photo) {
            selected =
                candidate->setPhotoTransform(
                    PhotoTransformForSnapshot(
                        snapshot));
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
#if defined(VCAM_ACTIVATION_PARITY_DEVICE_REMEDIATION_PROOF)
            if (activationRemediationActive_ &&
                activationRemediationGeneration_ ==
                    snapshot.selectionGeneration &&
                snapshot.mediaKind ==
                    ProductMediaKind::Photo) {
                activationRemediationStartAttempted_ =
                    true;
            }
#endif
            producerHealthy =
                candidate->start();
#if defined(VCAM_ACTIVATION_PARITY_DEVICE_REMEDIATION_PROOF)
            if (activationRemediationActive_ &&
                activationRemediationGeneration_ ==
                    snapshot.selectionGeneration &&
                snapshot.mediaKind ==
                    ProductMediaKind::Photo) {
                activationRemediationStartResult_ =
                    producerHealthy;
            }
#endif
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

#if defined(VCAM_ACTIVATION_PARITY_DEVICE_REMEDIATION_PROOF)
        if (activationRemediationActive_ &&
            activationRemediationGeneration_ ==
                snapshot.selectionGeneration &&
            snapshot.mediaKind ==
                ProductMediaKind::Photo) {
            activationRemediationSessionInstalled_ =
                session_ != nullptr;
            if (old != nullptr) {
                ++activationRemediationSessionReplacementCount_;
            }
        }
#endif

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
                ProductMediaKind::Photo &&
            snapshot.photoTransform.revision !=
                applied_.photoTransform.revision) {
            adapter_.unbindQueue();

            if (!session_->setPhotoTransform(
                    PhotoTransformForSnapshot(
                        snapshot))) {
                return;
            }
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
#if defined(VCAM_FIRST_LOCAL_PHOTO_SUBSTITUTION_DIAGNOSTIC_PROOF)
        const ProductControlSnapshot diagnosticSnapshot =
            cache_.snapshot();
        firstPhotoSubDiagnosticProducerGeneration_ =
            diagnosticSnapshot.selectionGeneration;
        firstPhotoSubDiagnosticProducerHealthy_ =
            producerHealthy;
#endif
#if defined(VCAM_FIRST_LOCAL_PHOTO_VIRTUAL_SUBSTITUTION_PROOF)
        const ProductControlSnapshot substitutionSnapshot =
            cache_.snapshot();
        firstPhotoSubstitutionProducerGeneration_ =
            substitutionSnapshot.selectionGeneration;
        firstPhotoSubstitutionProducerHealthy_ =
            producerHealthy;
#endif
#if defined(VCAM_LOCAL_PHOTO_PIPELINE_READY_PROOF)
        const ProductControlSnapshot proofSnapshot =
            cache_.snapshot();
        recordLocalPhotoProducerState(
            proofSnapshot.selectionGeneration,
            producerHealthy);
#endif

        if (session_ == nullptr) {
            adapter_.unbindQueue();
#if defined(VCAM_ACTIVATION_PARITY_DEVICE_REMEDIATION_PROOF)
            activationRemediationQueueBound_ = false;
#endif
            return;
        }

        const std::uint64_t queueGeneration =
            session_->state()
                .mediaGeneration();
        const std::uint64_t queueEpoch =
            session_->state()
                .timelineEpoch();

        const ProductControlSnapshot
            bindingSnapshot =
                cache_.snapshot();
        const bool reusableStaticMedia =
            bindingSnapshot.mediaKind ==
                ProductMediaKind::Photo &&
            bindingSnapshot.hasMedia();

        adapter_.bindQueue(
            &session_->readyQueue(),
            queueGeneration,
            queueEpoch,
            producerHealthy,
            reusableStaticMedia);

#if defined(VCAM_ACTIVATION_PARITY_DEVICE_REMEDIATION_PROOF)
        const ProductControlSnapshot
            remediationSnapshot =
                cache_.snapshot();
        if (activationRemediationActive_ &&
            activationRemediationGeneration_ ==
                remediationSnapshot.selectionGeneration &&
            remediationSnapshot.mediaKind ==
                ProductMediaKind::Photo) {
            activationRemediationQueueBound_ = true;
            activationRemediationQueueGeneration_ =
                queueGeneration;
            activationRemediationQueueEpoch_ =
                queueEpoch;
            activationRemediationAdapterGeneration_ =
                queueGeneration;
            activationRemediationAdapterEpoch_ =
                queueEpoch;
            activationRemediationProducerHealthy_ =
                producerHealthy;
        }
#endif
    }

#if defined(VCAM_ACTIVATION_PARITY_DEVICE_REMEDIATION_PROOF)
    static constexpr std::int64_t
        kActivationRemediationDiagnosticDelayNs =
            INT64_C(20000000000);

    static std::uint64_t
    activationRemediationPathHash(
        const std::string& path) noexcept {
        std::uint64_t hash =
            UINT64_C(1469598103934665603);
        for (const unsigned char byte : path) {
            hash ^= byte;
            hash *=
                UINT64_C(1099511628211);
        }
        return hash;
    }

    void updateActivationParityRemediationControlSnapshot(
        const ProductControlSnapshot& snapshot,
        bool observedByStore) noexcept {
        const bool activePhoto =
            snapshot.enabled &&
            snapshot.mediaKind ==
                ProductMediaKind::Photo &&
            snapshot.hasMedia() &&
            snapshot.selectionGeneration != 0;

        const std::uint64_t generation =
            activePhoto
                ? snapshot.selectionGeneration
                : 0;

        activationRemediationActiveGeneration_.store(
            generation,
            std::memory_order_release);

        if (observedByStore) {
            activationRemediationControlObservedGeneration_.store(
                generation,
                std::memory_order_release);
        }

        proof::BeginActivationParityPhotoGeneration(
            generation);
    }

    void beginOrRefreshActivationParityRemediationDiagnostic() {
        if (controlQueue_ == nullptr) {
            return;
        }

        const ProductControlSnapshot snapshot =
            cache_.snapshot();

        const bool activePhoto =
            snapshot.enabled &&
            snapshot.mediaKind ==
                ProductMediaKind::Photo &&
            snapshot.hasMedia() &&
            snapshot.selectionGeneration != 0;

        if (!activePhoto) {
            if (activationRemediationActive_) {
                activationRemediationActive_ = false;
                ++activationRemediationSerial_;
            }
            return;
        }

        if (activationRemediationActive_ &&
            activationRemediationGeneration_ ==
                snapshot.selectionGeneration &&
            activationRemediationPath_ ==
                snapshot.mediaPath) {
            return;
        }

        activationRemediationActive_ = true;
        ++activationRemediationSerial_;
        activationRemediationGeneration_ =
            snapshot.selectionGeneration;
        activationRemediationPath_ =
            snapshot.mediaPath;
        activationRemediationPathHash_ =
            activationRemediationPathHash(
                snapshot.mediaPath);
        activationRemediationMediaStaged_ =
            activationRemediationStager_.
                isExistingOwnedMediaPath(
                    snapshot.mediaPath);

        activationRemediationTargetGeneration_ = 0;
        activationRemediationTargetGeometry_ = 0;
        activationRemediationSelectAttempted_ = false;
        activationRemediationSelectResult_ = false;
        activationRemediationStartAttempted_ = false;
        activationRemediationStartResult_ = false;
        activationRemediationSessionInstalled_ = false;
        activationRemediationSessionReplacementCount_ = 0;
        activationRemediationProducerHealthy_ = false;
        activationRemediationQueueBound_ = false;
        activationRemediationQueueGeneration_ = 0;
        activationRemediationQueueEpoch_ = 0;
        activationRemediationAdapterGeneration_ = 0;
        activationRemediationAdapterEpoch_ = 0;
        activationRemediationGeometryChangeCount_.store(
            0,
            std::memory_order_release);

        proof::BeginActivationParityPhotoGeneration(
            snapshot.selectionGeneration);

        const std::uint64_t serial =
            activationRemediationSerial_;
        const std::uint64_t generation =
            activationRemediationGeneration_;

        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                kActivationRemediationDiagnosticDelayNs),
            controlQueue_,
            ^{
                if (!this->activationRemediationActive_ ||
                    this->activationRemediationSerial_ !=
                        serial ||
                    this->activationRemediationGeneration_ !=
                        generation) {
                    return;
                }

                this->publishActivationParityRemediationSnapshot();
                this->activationRemediationActive_ = false;
            });
    }

    proof::ActivationParityPhotoStage
    activationRemediationBaseStage(
        const proof::ActivationParityPhotoSnapshot&
            snapshot) const noexcept {
        if (!snapshot.controlObserved) {
            return proof::
                ActivationParityPhotoStage::
                    WaitingControl;
        }
        if (!snapshot.mediaStaged) {
            return proof::
                ActivationParityPhotoStage::
                    StagingMismatch;
        }
        if (snapshot.observedGeometry == 0) {
            return proof::
                ActivationParityPhotoStage::
                    WaitingGeometry;
        }
        if (snapshot.selectPhotoAttempted &&
            !snapshot.selectPhotoResult) {
            return proof::
                ActivationParityPhotoStage::
                    SelectPhotoFailed;
        }
        if (snapshot.startAttempted &&
            !snapshot.startResult) {
            return proof::
                ActivationParityPhotoStage::
                    ProducerStartFailed;
        }
        if (!snapshot.sessionExists) {
            return proof::
                ActivationParityPhotoStage::
                    SessionAbsent;
        }
        if (!snapshot.producerHealthy) {
            return proof::
                ActivationParityPhotoStage::
                    ProducerUnavailable;
        }
        if (snapshot.readyQueueSize == 0) {
            return proof::
                ActivationParityPhotoStage::
                    QueueEmpty;
        }

        return proof::
            ActivationParityPhotoStage::
                WaitingControl;
    }

    void publishActivationParityRemediationSnapshot() {
        if (!activationRemediationActive_ ||
            activationRemediationGeneration_ == 0) {
            return;
        }

        const ProductControlSnapshot snapshot =
            cache_.snapshot();

        if (snapshot.selectionGeneration !=
                activationRemediationGeneration_ ||
            snapshot.mediaPath !=
                activationRemediationPath_ ||
            snapshot.mediaKind !=
                ProductMediaKind::Photo) {
            return;
        }

        proof::ActivationParityPhotoSnapshot facts;
        facts.selectionGeneration =
            activationRemediationGeneration_;
        facts.mediaPathHash =
            activationRemediationPathHash_;
        facts.enabled =
            snapshot.enabled;
        facts.photoSelected =
            snapshot.mediaKind ==
                ProductMediaKind::Photo &&
            snapshot.hasMedia();
        facts.mediaStaged =
            activationRemediationMediaStaged_;
        facts.controlObserved =
            activationRemediationControlObservedGeneration_.load(
                std::memory_order_acquire) ==
            activationRemediationGeneration_;

        facts.observedGeometry =
            observedGeometry_.load(
                std::memory_order_acquire);
        facts.geometryChangeCount =
            activationRemediationGeometryChangeCount_.load(
                std::memory_order_acquire);
        facts.sessionTargetGeometry =
            activationRemediationTargetGeometry_;
        facts.targetSelectionGeneration =
            activationRemediationTargetGeneration_;

        facts.selectPhotoAttempted =
            activationRemediationSelectAttempted_;
        facts.selectPhotoResult =
            activationRemediationSelectResult_;
        facts.startAttempted =
            activationRemediationStartAttempted_;
        facts.startResult =
            activationRemediationStartResult_;
        facts.sessionInstalled =
            activationRemediationSessionInstalled_;
        facts.sessionReplacementCount =
            activationRemediationSessionReplacementCount_;

        facts.playbackIntent =
            static_cast<std::uint8_t>(
                snapshot.playbackIntent);
        facts.producerHealthy =
            activationRemediationProducerHealthy_;

        facts.queueBound =
            activationRemediationQueueBound_;
        facts.queueMediaGeneration =
            activationRemediationQueueGeneration_;
        facts.queueTimelineEpoch =
            activationRemediationQueueEpoch_;
        facts.adapterMediaGeneration =
            activationRemediationAdapterGeneration_;
        facts.adapterTimelineEpoch =
            activationRemediationAdapterEpoch_;

        if (session_ != nullptr) {
            facts.sessionExists = true;

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
                activationRemediationPath_;

            facts.playbackState =
                static_cast<std::uint8_t>(
                    session_->playbackState());

            const auto readerStatus =
                session_->state()
                    .readerStatus();
            facts.readerState =
                static_cast<std::uint8_t>(
                    readerStatus.state);
            facts.readerError =
                static_cast<std::uint8_t>(
                    readerStatus.error);

            facts.frameSequenceCount =
                session_->state()
                    .nextSequence();
            facts.producerDriverState =
                static_cast<std::uint8_t>(
                    session_->producerDriverState());
            const auto pumpStatus =
                session_->lastPumpStatus();
            facts.producerPumpStatusValid =
                pumpStatus.has_value();
            facts.producerPumpStatus =
                pumpStatus.has_value()
                    ? static_cast<std::uint8_t>(
                          *pumpStatus)
                    : 0;
            facts.publishedFrameCount =
                session_->publishedFrameCount();
            facts.photoDecodeCount =
                session_->photoDecodeCount();

            facts.readyQueueSize =
                static_cast<std::uint32_t>(
                    std::min<std::size_t>(
                        session_->readyQueue().size(),
                        UINT32_MAX));
        }

        facts.stage =
            activationRemediationBaseStage(
                facts);

        proof::PublishActivationParityPhotoSnapshot(
            facts);
    }
#endif

#if defined(VCAM_IOS15_ACTIVATION_PARITY_PROOF)
    static constexpr std::uint32_t
        kActivationControlEnabled =
            UINT32_C(0x01);
    static constexpr std::uint32_t
        kActivationControlPhoto =
            UINT32_C(0x02);
    static constexpr std::uint32_t
        kActivationControlHasMedia =
            UINT32_C(0x04);

    void updateIOS15ActivationParityControlSnapshot(
        const ProductControlSnapshot& snapshot) noexcept {
        ios15ActivationControlSequence_.fetch_add(
            1,
            std::memory_order_acq_rel);

        ios15ActivationSelectionGeneration_.store(
            snapshot.selectionGeneration,
            std::memory_order_relaxed);

        std::uint32_t flags = 0;
        if (snapshot.enabled) {
            flags |=
                kActivationControlEnabled;
        }
        if (snapshot.mediaKind ==
            ProductMediaKind::Photo) {
            flags |=
                kActivationControlPhoto;
        }
        if (snapshot.hasMedia()) {
            flags |=
                kActivationControlHasMedia;
        }

        ios15ActivationControlFlags_.store(
            flags,
            std::memory_order_relaxed);

        ios15ActivationControlSequence_.fetch_add(
            1,
            std::memory_order_release);
    }

    bool loadIOS15ActivationParityControlSnapshot(
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
                ios15ActivationControlSequence_.load(
                    std::memory_order_acquire);

            if ((before & UINT64_C(1)) != 0) {
                continue;
            }

            const std::uint64_t generation =
                ios15ActivationSelectionGeneration_.load(
                    std::memory_order_relaxed);
            const std::uint32_t loadedFlags =
                ios15ActivationControlFlags_.load(
                    std::memory_order_relaxed);

            const std::uint64_t after =
                ios15ActivationControlSequence_.load(
                    std::memory_order_acquire);

            if (before == after &&
                (after & UINT64_C(1)) == 0) {
                *selectionGeneration =
                    generation;
                *flags =
                    loadedFlags;
                return true;
            }
        }

        return false;
    }
#endif

#if defined(VCAM_FIRST_LOCAL_PHOTO_SUBSTITUTION_DIAGNOSTIC_PROOF)
    static constexpr std::uint32_t
        kFirstPhotoSubDiagControlEnabled =
            UINT32_C(0x01);
    static constexpr std::uint32_t
        kFirstPhotoSubDiagControlPhoto =
            UINT32_C(0x02);
    static constexpr std::uint32_t
        kFirstPhotoSubDiagControlHasMedia =
            UINT32_C(0x04);

    static constexpr std::uint32_t
        kFirstPhotoSubDiagnosticCallbackBudget =
            240;
    static constexpr std::int64_t
        kFirstPhotoSubDiagnosticIntervalNanoseconds =
            INT64_C(10000000000);

    static std::uint32_t firstPhotoSubDiagnosticReasonCode(
        CameraFailOpenReason reason) noexcept {
        switch (reason) {
            case CameraFailOpenReason::Disabled:
                return static_cast<std::uint32_t>(
                    FirstPhotoSubDiagnosticReason::Disabled);
            case CameraFailOpenReason::ReconfigurationContended:
                return static_cast<std::uint32_t>(
                    FirstPhotoSubDiagnosticReason::
                        ReconfigurationContended);
            case CameraFailOpenReason::ProducerUnavailable:
                return static_cast<std::uint32_t>(
                    FirstPhotoSubDiagnosticReason::
                        ProducerUnavailable);
            case CameraFailOpenReason::EmptyOrNoEligibleFrame:
                return static_cast<std::uint32_t>(
                    FirstPhotoSubDiagnosticReason::
                        EmptyOrNoEligibleFrame);
            case CameraFailOpenReason::InvalidLease:
                return static_cast<std::uint32_t>(
                    FirstPhotoSubDiagnosticReason::
                        InvalidLease);
            case CameraFailOpenReason::GeometryMismatch:
                return static_cast<std::uint32_t>(
                    FirstPhotoSubDiagnosticReason::
                        GeometryMismatch);
            case CameraFailOpenReason::None:
            default:
                return static_cast<std::uint32_t>(
                    FirstPhotoSubDiagnosticReason::None);
        }
    }

    static FirstPhotoSubDiagnosticPlaybackState
    firstPhotoSubDiagnosticPlaybackState(
        frame_engine::PlaybackState state) noexcept {
        switch (state) {
            case frame_engine::PlaybackState::Empty:
                return FirstPhotoSubDiagnosticPlaybackState::Empty;
            case frame_engine::PlaybackState::Ready:
                return FirstPhotoSubDiagnosticPlaybackState::Ready;
            case frame_engine::PlaybackState::Playing:
                return FirstPhotoSubDiagnosticPlaybackState::Playing;
            case frame_engine::PlaybackState::Paused:
                return FirstPhotoSubDiagnosticPlaybackState::Paused;
            case frame_engine::PlaybackState::Ended:
                return FirstPhotoSubDiagnosticPlaybackState::Ended;
            case frame_engine::PlaybackState::Failed:
                return FirstPhotoSubDiagnosticPlaybackState::Failed;
            default:
                return FirstPhotoSubDiagnosticPlaybackState::Unknown;
        }
    }

    static FirstPhotoSubDiagnosticMediaKind
    firstPhotoSubDiagnosticSelectedMediaKind(
        media_engine::SelectedMediaKind kind) noexcept {
        switch (kind) {
            case media_engine::SelectedMediaKind::Photo:
                return FirstPhotoSubDiagnosticMediaKind::Photo;
            case media_engine::SelectedMediaKind::Video:
                return FirstPhotoSubDiagnosticMediaKind::Video;
            case media_engine::SelectedMediaKind::None:
            default:
                return FirstPhotoSubDiagnosticMediaKind::None;
        }
    }

    void resetFirstPhotoSubstitutionDiagnosticTransport() noexcept {
        cancelFirstPhotoSubstitutionDiagnosticToken(
            &firstPhotoSubDiagnosticPrimaryToken_);
        cancelFirstPhotoSubstitutionDiagnosticToken(
            &firstPhotoSubDiagnosticSelectionToken_);
        cancelFirstPhotoSubstitutionDiagnosticToken(
            &firstPhotoSubDiagnosticCountsToken_);
        cancelFirstPhotoSubstitutionDiagnosticToken(
            &firstPhotoSubDiagnosticFailCountsToken_);
        cancelFirstPhotoSubstitutionDiagnosticToken(
            &firstPhotoSubDiagnosticObservedGeometryToken_);
        cancelFirstPhotoSubstitutionDiagnosticToken(
            &firstPhotoSubDiagnosticTargetGeometryToken_);
        cancelFirstPhotoSubstitutionDiagnosticToken(
            &firstPhotoSubDiagnosticSessionToken_);
        cancelFirstPhotoSubstitutionDiagnosticToken(
            &firstPhotoSubDiagnosticLastToken_);

        (void)registerFirstPhotoSubstitutionDiagnosticToken(
            VCAM_FIRST_PHOTO_SUB_DIAGNOSTIC_NOTIFICATION,
            &firstPhotoSubDiagnosticPrimaryToken_);
        (void)registerFirstPhotoSubstitutionDiagnosticToken(
            VCAM_FIRST_PHOTO_SUB_DIAGNOSTIC_SELECTION_STATE,
            &firstPhotoSubDiagnosticSelectionToken_);
        (void)registerFirstPhotoSubstitutionDiagnosticToken(
            VCAM_FIRST_PHOTO_SUB_DIAGNOSTIC_COUNTS_STATE,
            &firstPhotoSubDiagnosticCountsToken_);
        (void)registerFirstPhotoSubstitutionDiagnosticToken(
            VCAM_FIRST_PHOTO_SUB_DIAGNOSTIC_FAIL_COUNTS_STATE,
            &firstPhotoSubDiagnosticFailCountsToken_);
        (void)registerFirstPhotoSubstitutionDiagnosticToken(
            VCAM_FIRST_PHOTO_SUB_DIAGNOSTIC_OBSERVED_GEOMETRY_STATE,
            &firstPhotoSubDiagnosticObservedGeometryToken_);
        (void)registerFirstPhotoSubstitutionDiagnosticToken(
            VCAM_FIRST_PHOTO_SUB_DIAGNOSTIC_TARGET_GEOMETRY_STATE,
            &firstPhotoSubDiagnosticTargetGeometryToken_);
        (void)registerFirstPhotoSubstitutionDiagnosticToken(
            VCAM_FIRST_PHOTO_SUB_DIAGNOSTIC_SESSION_STATE,
            &firstPhotoSubDiagnosticSessionToken_);
        (void)registerFirstPhotoSubstitutionDiagnosticToken(
            VCAM_FIRST_PHOTO_SUB_DIAGNOSTIC_LAST_STATE,
            &firstPhotoSubDiagnosticLastToken_);

        clearFirstPhotoSubstitutionDiagnosticTransport();
    }

    static bool registerFirstPhotoSubstitutionDiagnosticToken(
        const char* name,
        int* token) noexcept {
        if (name == nullptr ||
            token == nullptr) {
            return false;
        }

        int value = 0;
        if (notify_register_check(
                name,
                &value) != NOTIFY_STATUS_OK) {
            return false;
        }

        *token = value;
        return true;
    }

    static void cancelFirstPhotoSubstitutionDiagnosticToken(
        int* token) noexcept {
        if (token != nullptr &&
            *token >= 0) {
            (void)notify_cancel(*token);
            *token = -1;
        }
    }

    void clearFirstPhotoSubstitutionDiagnosticTransport() noexcept {
        const int tokens[] = {
            firstPhotoSubDiagnosticPrimaryToken_,
            firstPhotoSubDiagnosticSelectionToken_,
            firstPhotoSubDiagnosticCountsToken_,
            firstPhotoSubDiagnosticFailCountsToken_,
            firstPhotoSubDiagnosticObservedGeometryToken_,
            firstPhotoSubDiagnosticTargetGeometryToken_,
            firstPhotoSubDiagnosticSessionToken_,
            firstPhotoSubDiagnosticLastToken_,
        };

        for (const int token : tokens) {
            if (token >= 0) {
                (void)notify_set_state(
                    token,
                    UINT64_C(0));
            }
        }
    }

    void updateFirstPhotoSubstitutionDiagnosticControlSnapshot(
        const ProductControlSnapshot& snapshot) noexcept {
        firstPhotoSubDiagnosticControlSequence_.fetch_add(
            1,
            std::memory_order_acq_rel);

        firstPhotoSubDiagnosticControlGeneration_.store(
            snapshot.selectionGeneration,
            std::memory_order_relaxed);

        std::uint32_t flags = 0;
        if (snapshot.enabled) {
            flags |= kFirstPhotoSubDiagControlEnabled;
        }
        if (snapshot.mediaKind ==
            ProductMediaKind::Photo) {
            flags |= kFirstPhotoSubDiagControlPhoto;
        }
        if (snapshot.hasMedia()) {
            flags |= kFirstPhotoSubDiagControlHasMedia;
        }

        firstPhotoSubDiagnosticControlFlags_.store(
            flags,
            std::memory_order_relaxed);

        firstPhotoSubDiagnosticControlSequence_.fetch_add(
            1,
            std::memory_order_release);
    }

    bool loadFirstPhotoSubstitutionDiagnosticControlSnapshot(
        std::uint64_t* generation,
        std::uint32_t* flags) const noexcept {
        if (generation == nullptr ||
            flags == nullptr) {
            return false;
        }

        for (int attempt = 0;
             attempt < 2;
             ++attempt) {
            const std::uint64_t before =
                firstPhotoSubDiagnosticControlSequence_.load(
                    std::memory_order_acquire);
            if ((before & UINT64_C(1)) != 0) {
                continue;
            }

            const std::uint64_t loadedGeneration =
                firstPhotoSubDiagnosticControlGeneration_.load(
                    std::memory_order_relaxed);
            const std::uint32_t loadedFlags =
                firstPhotoSubDiagnosticControlFlags_.load(
                    std::memory_order_relaxed);

            const std::uint64_t after =
                firstPhotoSubDiagnosticControlSequence_.load(
                    std::memory_order_acquire);

            if (before == after &&
                (after & UINT64_C(1)) == 0) {
                *generation =
                    loadedGeneration;
                *flags =
                    loadedFlags;
                return true;
            }
        }

        return false;
    }

    void beginOrStopFirstPhotoSubstitutionDiagnostic() {
        const ProductControlSnapshot snapshot =
            cache_.snapshot();

        const bool active =
            snapshot.enabled &&
            snapshot.mediaKind ==
                ProductMediaKind::Photo &&
            snapshot.hasMedia() &&
            snapshot.selectionGeneration != 0;

        if (!active) {
            if (firstPhotoSubDiagnosticActive_) {
                firstPhotoSubDiagnosticActive_ = false;
                ++firstPhotoSubDiagnosticSerial_;
                firstPhotoSubDiagnosticActiveGeneration_.store(
                    0,
                    std::memory_order_release);
                clearFirstPhotoSubstitutionDiagnosticTransport();
            }
            return;
        }

        if (firstPhotoSubDiagnosticActive_ &&
            firstPhotoSubDiagnosticGeneration_ ==
                snapshot.selectionGeneration &&
            firstPhotoSubDiagnosticPath_ ==
                snapshot.mediaPath) {
            return;
        }

        ++firstPhotoSubDiagnosticSerial_;
        firstPhotoSubDiagnosticActive_ = true;
        firstPhotoSubDiagnosticPublished_ = false;
        firstPhotoSubDiagnosticGeneration_ =
            snapshot.selectionGeneration;
        firstPhotoSubDiagnosticPath_ =
            snapshot.mediaPath;

        firstPhotoSubDiagnosticDecisionBaseline_ =
            adapter_.decisionCount();
        firstPhotoSubDiagnosticVirtualBaseline_ =
            adapter_.virtualDecisionCount();

        firstPhotoSubDiagnosticCallbackCount_.store(
            0,
            std::memory_order_release);
        firstPhotoSubDiagnosticDecisionCountFinal_.store(
            firstPhotoSubDiagnosticDecisionBaseline_,
            std::memory_order_release);
        firstPhotoSubDiagnosticVirtualCountFinal_.store(
            firstPhotoSubDiagnosticVirtualBaseline_,
            std::memory_order_release);
        firstPhotoSubDiagnosticDecisionVirtualCount_.store(
            0,
            std::memory_order_release);
        firstPhotoSubDiagnosticDecisionOriginalCount_.store(
            0,
            std::memory_order_release);
        firstPhotoSubDiagnosticDisabledCount_.store(
            0,
            std::memory_order_release);
        firstPhotoSubDiagnosticReconfigurationCount_.store(
            0,
            std::memory_order_release);
        firstPhotoSubDiagnosticProducerUnavailableCount_.store(
            0,
            std::memory_order_release);
        firstPhotoSubDiagnosticEmptyCount_.store(
            0,
            std::memory_order_release);
        firstPhotoSubDiagnosticInvalidLeaseCount_.store(
            0,
            std::memory_order_release);
        firstPhotoSubDiagnosticGeometryMismatchCount_.store(
            0,
            std::memory_order_release);
        firstPhotoSubDiagnosticGeometryChangeCount_.store(
            0,
            std::memory_order_release);
        firstPhotoSubDiagnosticLastGeometry_.store(
            0,
            std::memory_order_release);
        firstPhotoSubDiagnosticLastDecision_.store(
            static_cast<std::uint32_t>(
                FirstPhotoSubDiagnosticDecision::None),
            std::memory_order_release);
        firstPhotoSubDiagnosticLastReason_.store(
            static_cast<std::uint32_t>(
                FirstPhotoSubDiagnosticReason::None),
            std::memory_order_release);
        firstPhotoSubDiagnosticLastVirtualFlags_.store(
            0,
            std::memory_order_release);
        firstPhotoSubDiagnosticThresholdScheduled_.store(
            false,
            std::memory_order_release);

        firstPhotoSubDiagnosticProducerGeneration_ = 0;
        firstPhotoSubDiagnosticProducerHealthy_ = false;

        firstPhotoSubDiagnosticActiveGeneration_.store(
            snapshot.selectionGeneration,
            std::memory_order_release);

        clearFirstPhotoSubstitutionDiagnosticTransport();

        const std::uint64_t serial =
            firstPhotoSubDiagnosticSerial_;
        const std::uint64_t generation =
            firstPhotoSubDiagnosticGeneration_;

        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                kFirstPhotoSubDiagnosticIntervalNanoseconds),
            controlQueue_,
            ^{
                if (this->firstPhotoSubDiagnosticActive_ &&
                    !this->firstPhotoSubDiagnosticPublished_ &&
                    this->firstPhotoSubDiagnosticSerial_ ==
                        serial &&
                    this->firstPhotoSubDiagnosticGeneration_ ==
                        generation) {
                    this->
                        publishFirstPhotoSubstitutionDiagnosticIfActive(
                            generation);
                }
            });
    }

    std::uint32_t reserveFirstPhotoSubstitutionDiagnosticCallback()
        noexcept {
        std::uint32_t current =
            firstPhotoSubDiagnosticCallbackCount_.load(
                std::memory_order_acquire);

        while (current <
               kFirstPhotoSubDiagnosticCallbackBudget) {
            if (firstPhotoSubDiagnosticCallbackCount_.
                    compare_exchange_weak(
                        current,
                        current + 1U,
                        std::memory_order_acq_rel,
                        std::memory_order_acquire)) {
                return current + 1U;
            }
        }

        return 0;
    }

    FirstPhotoSubDiagnosticClassification
    classifyFirstPhotoSubstitutionDiagnostic(
        const proof::
            FirstLocalPhotoSubstitutionDiagnosticSnapshot&
                snapshot) const noexcept {

        if (snapshot.decisionVirtualCount > 0 ||
            snapshot.virtualDecisionCountDelta > 0) {
            return
                FirstPhotoSubDiagnosticClassification::
                    VirtualDecisionObserved;
        }

        if (snapshot.cameraCallbackCount == 0) {
            return
                FirstPhotoSubDiagnosticClassification::
                    NoGenuineCallbackObserved;
        }

        const std::uint32_t originalCount =
            snapshot.decisionOriginalCount;

        if (originalCount > 0 &&
            snapshot.failOpenDisabledCount ==
                originalCount) {
            return
                FirstPhotoSubDiagnosticClassification::
                    OriginalDisabled;
        }
        if (originalCount > 0 &&
            snapshot.failOpenReconfigurationContendedCount ==
                originalCount) {
            return
                FirstPhotoSubDiagnosticClassification::
                    OriginalReconfigurationContended;
        }
        if (originalCount > 0 &&
            snapshot.failOpenProducerUnavailableCount ==
                originalCount) {
            return
                FirstPhotoSubDiagnosticClassification::
                    OriginalProducerUnavailable;
        }
        if (originalCount > 0 &&
            snapshot.failOpenEmptyOrNoEligibleCount ==
                originalCount) {
            return
                FirstPhotoSubDiagnosticClassification::
                    OriginalEmptyOrNoEligible;
        }
        if (originalCount > 0 &&
            snapshot.failOpenInvalidLeaseCount ==
                originalCount) {
            return
                FirstPhotoSubDiagnosticClassification::
                    OriginalInvalidLease;
        }
        if (originalCount > 0 &&
            snapshot.failOpenGeometryMismatchCount ==
                originalCount) {
            return
                FirstPhotoSubDiagnosticClassification::
                    OriginalGeometryMismatch;
        }

        return
            FirstPhotoSubDiagnosticClassification::
                OriginalMixedFailOpen;
    }

    proof::FirstLocalPhotoSubstitutionDiagnosticSnapshot
    currentFirstPhotoSubstitutionDiagnosticSnapshot() {
        proof::FirstLocalPhotoSubstitutionDiagnosticSnapshot
            snapshot;

        snapshot.selectionGeneration =
            firstPhotoSubDiagnosticGeneration_;

        snapshot.cameraCallbackCount =
            firstPhotoSubDiagnosticCallbackCount_.load(
                std::memory_order_acquire);

        const std::uint64_t decisionFinal =
            firstPhotoSubDiagnosticDecisionCountFinal_.load(
                std::memory_order_acquire);
        const std::uint64_t virtualFinal =
            firstPhotoSubDiagnosticVirtualCountFinal_.load(
                std::memory_order_acquire);

        snapshot.decisionCountDelta =
            decisionFinal >=
                    firstPhotoSubDiagnosticDecisionBaseline_
                ? static_cast<std::uint32_t>(
                      decisionFinal -
                      firstPhotoSubDiagnosticDecisionBaseline_)
                : 0;
        snapshot.virtualDecisionCountDelta =
            virtualFinal >=
                    firstPhotoSubDiagnosticVirtualBaseline_
                ? static_cast<std::uint32_t>(
                      virtualFinal -
                      firstPhotoSubDiagnosticVirtualBaseline_)
                : 0;

        snapshot.decisionVirtualCount =
            firstPhotoSubDiagnosticDecisionVirtualCount_.load(
                std::memory_order_acquire);
        snapshot.decisionOriginalCount =
            firstPhotoSubDiagnosticDecisionOriginalCount_.load(
                std::memory_order_acquire);

        snapshot.failOpenDisabledCount =
            firstPhotoSubDiagnosticDisabledCount_.load(
                std::memory_order_acquire);
        snapshot.failOpenReconfigurationContendedCount =
            firstPhotoSubDiagnosticReconfigurationCount_.load(
                std::memory_order_acquire);
        snapshot.failOpenProducerUnavailableCount =
            firstPhotoSubDiagnosticProducerUnavailableCount_.load(
                std::memory_order_acquire);
        snapshot.failOpenEmptyOrNoEligibleCount =
            firstPhotoSubDiagnosticEmptyCount_.load(
                std::memory_order_acquire);
        snapshot.failOpenInvalidLeaseCount =
            firstPhotoSubDiagnosticInvalidLeaseCount_.load(
                std::memory_order_acquire);
        snapshot.failOpenGeometryMismatchCount =
            firstPhotoSubDiagnosticGeometryMismatchCount_.load(
                std::memory_order_acquire);

        snapshot.geometryChangeCount =
            firstPhotoSubDiagnosticGeometryChangeCount_.load(
                std::memory_order_acquire);
        snapshot.observedCameraGeometry =
            firstPhotoSubDiagnosticLastGeometry_.load(
                std::memory_order_acquire);
        snapshot.sessionTargetGeometry =
            firstPhotoSubDiagnosticTargetGeneration_ ==
                    firstPhotoSubDiagnosticGeneration_
                ? firstPhotoSubDiagnosticTargetGeometry_
                : 0;

        const ProductControlSnapshot control =
            cache_.snapshot();

        snapshot.vcamEnabled =
            control.enabled;
        snapshot.photoSelected =
            control.mediaKind ==
                ProductMediaKind::Photo &&
            control.hasMedia() &&
            control.selectionGeneration ==
                firstPhotoSubDiagnosticGeneration_;

        snapshot.producerHealthy =
            firstPhotoSubDiagnosticProducerGeneration_ ==
                    firstPhotoSubDiagnosticGeneration_ &&
            firstPhotoSubDiagnosticProducerHealthy_;
        snapshot.sessionExists =
            session_ != nullptr;

        if (session_ != nullptr) {
            snapshot.playbackState =
                firstPhotoSubDiagnosticPlaybackState(
                    session_->playbackState());
            snapshot.readyFrameCount =
                static_cast<std::uint32_t>(
                    session_->readyQueue().size());

            const auto& selected =
                session_->selectedMedia();
            snapshot.selectedMediaValid =
                selected.valid;
            snapshot.selectedMediaKind =
                firstPhotoSubDiagnosticSelectedMediaKind(
                    selected.kind);
            snapshot.selectedMediaPathMatch =
                selected.localPath ==
                    firstPhotoSubDiagnosticPath_;
        }

        snapshot.lastDecision =
            static_cast<
                FirstPhotoSubDiagnosticDecision>(
                    firstPhotoSubDiagnosticLastDecision_.load(
                        std::memory_order_acquire));
        snapshot.lastFailOpenReason =
            static_cast<
                FirstPhotoSubDiagnosticReason>(
                    firstPhotoSubDiagnosticLastReason_.load(
                        std::memory_order_acquire));

        const std::uint32_t virtualFlags =
            firstPhotoSubDiagnosticLastVirtualFlags_.load(
                std::memory_order_acquire);
        snapshot.virtualBufferNonNull =
            (virtualFlags & UINT32_C(0x01)) != 0;
        snapshot.virtualBufferDifferentFromOriginal =
            (virtualFlags & UINT32_C(0x02)) != 0;
        snapshot.virtualWidthMatch =
            (virtualFlags & UINT32_C(0x04)) != 0;
        snapshot.virtualHeightMatch =
            (virtualFlags & UINT32_C(0x08)) != 0;
        snapshot.virtualPixelFormatMatch =
            (virtualFlags & UINT32_C(0x10)) != 0;
        snapshot.virtualGeometryMatch =
            (virtualFlags & UINT32_C(0x20)) != 0;

        return snapshot;
    }

    void publishFirstPhotoSubstitutionDiagnosticIfActive(
        std::uint64_t selectionGeneration) {
        if (!firstPhotoSubDiagnosticActive_ ||
            firstPhotoSubDiagnosticPublished_ ||
            firstPhotoSubDiagnosticGeneration_ !=
                selectionGeneration ||
            firstPhotoSubDiagnosticActiveGeneration_.load(
                std::memory_order_acquire) !=
                selectionGeneration) {
            return;
        }

        const ProductControlSnapshot current =
            cache_.snapshot();
        if (!current.enabled ||
            current.mediaKind !=
                ProductMediaKind::Photo ||
            !current.hasMedia() ||
            current.selectionGeneration !=
                selectionGeneration ||
            current.mediaPath !=
                firstPhotoSubDiagnosticPath_) {
            firstPhotoSubDiagnosticActive_ = false;
            ++firstPhotoSubDiagnosticSerial_;
            firstPhotoSubDiagnosticActiveGeneration_.store(
                0,
                std::memory_order_release);
            clearFirstPhotoSubstitutionDiagnosticTransport();
            return;
        }

        proof::FirstLocalPhotoSubstitutionDiagnosticSnapshot
            snapshot =
                currentFirstPhotoSubstitutionDiagnosticSnapshot();

        const pid_t pidValue = getpid();
        const time_t nowValue = time(nullptr);
        if (pidValue <= 0 ||
            static_cast<std::uint64_t>(pidValue) >
                UINT32_C(0x000fffff) ||
            nowValue < 0 ||
            static_cast<std::uint64_t>(nowValue) >
                UINT32_MAX) {
            return;
        }

        const auto classification =
            classifyFirstPhotoSubstitutionDiagnostic(
                snapshot);

        const std::uint64_t primaryState =
            vcam_first_photo_sub_diag_encode_primary(
                static_cast<std::uint32_t>(nowValue),
                static_cast<std::uint32_t>(pidValue),
                classification);
        const std::uint64_t countsState =
            vcam_first_photo_sub_diag_encode_counts(
                snapshot.cameraCallbackCount,
                snapshot.decisionCountDelta,
                snapshot.virtualDecisionCountDelta,
                snapshot.decisionVirtualCount,
                snapshot.decisionOriginalCount);
        const std::uint64_t failCountsState =
            vcam_first_photo_sub_diag_encode_fail_counts(
                snapshot.failOpenDisabledCount,
                snapshot.failOpenReconfigurationContendedCount,
                snapshot.failOpenProducerUnavailableCount,
                snapshot.failOpenEmptyOrNoEligibleCount,
                snapshot.failOpenInvalidLeaseCount,
                snapshot.failOpenGeometryMismatchCount,
                snapshot.geometryChangeCount);
        const std::uint64_t sessionState =
            vcam_first_photo_sub_diag_encode_session(
                snapshot.readyFrameCount,
                snapshot.vcamEnabled,
                snapshot.photoSelected,
                snapshot.producerHealthy,
                snapshot.sessionExists,
                snapshot.selectedMediaValid,
                snapshot.selectedMediaPathMatch,
                snapshot.playbackState,
                snapshot.selectedMediaKind);
        const std::uint64_t lastState =
            vcam_first_photo_sub_diag_encode_last(
                snapshot.lastDecision,
                snapshot.lastFailOpenReason,
                snapshot.virtualBufferNonNull,
                snapshot.virtualBufferDifferentFromOriginal,
                snapshot.virtualWidthMatch,
                snapshot.virtualHeightMatch,
                snapshot.virtualPixelFormatMatch,
                snapshot.virtualGeometryMatch);

        if (firstPhotoSubDiagnosticPrimaryToken_ < 0 ||
            firstPhotoSubDiagnosticSelectionToken_ < 0 ||
            firstPhotoSubDiagnosticCountsToken_ < 0 ||
            firstPhotoSubDiagnosticFailCountsToken_ < 0 ||
            firstPhotoSubDiagnosticObservedGeometryToken_ < 0 ||
            firstPhotoSubDiagnosticTargetGeometryToken_ < 0 ||
            firstPhotoSubDiagnosticSessionToken_ < 0 ||
            firstPhotoSubDiagnosticLastToken_ < 0 ||
            notify_set_state(
                firstPhotoSubDiagnosticSelectionToken_,
                snapshot.selectionGeneration) !=
                NOTIFY_STATUS_OK ||
            notify_set_state(
                firstPhotoSubDiagnosticCountsToken_,
                countsState) !=
                NOTIFY_STATUS_OK ||
            notify_set_state(
                firstPhotoSubDiagnosticFailCountsToken_,
                failCountsState) !=
                NOTIFY_STATUS_OK ||
            notify_set_state(
                firstPhotoSubDiagnosticObservedGeometryToken_,
                snapshot.observedCameraGeometry) !=
                NOTIFY_STATUS_OK ||
            notify_set_state(
                firstPhotoSubDiagnosticTargetGeometryToken_,
                snapshot.sessionTargetGeometry) !=
                NOTIFY_STATUS_OK ||
            notify_set_state(
                firstPhotoSubDiagnosticSessionToken_,
                sessionState) !=
                NOTIFY_STATUS_OK ||
            notify_set_state(
                firstPhotoSubDiagnosticLastToken_,
                lastState) !=
                NOTIFY_STATUS_OK ||
            notify_set_state(
                firstPhotoSubDiagnosticPrimaryToken_,
                primaryState) !=
                NOTIFY_STATUS_OK ||
            notify_post(
                VCAM_FIRST_PHOTO_SUB_DIAGNOSTIC_NOTIFICATION) !=
                NOTIFY_STATUS_OK) {
            return;
        }

        firstPhotoSubDiagnosticPublished_ = true;
        firstPhotoSubDiagnosticActive_ = false;
        firstPhotoSubDiagnosticActiveGeneration_.store(
            0,
            std::memory_order_release);
    }
#endif

#if defined(VCAM_FIRST_LOCAL_PHOTO_VIRTUAL_SUBSTITUTION_PROOF)
    static constexpr std::uint32_t
        kFirstPhotoSubControlEnabled =
            UINT32_C(0x01);
    static constexpr std::uint32_t
        kFirstPhotoSubControlPhoto =
            UINT32_C(0x02);
    static constexpr std::uint32_t
        kFirstPhotoSubControlHasMedia =
            UINT32_C(0x04);

    static constexpr std::uint32_t
        kFirstPhotoSubReadyMaxChecks =
            120;
    static constexpr std::int64_t
        kFirstPhotoSubReadyRetryNanoseconds =
            INT64_C(250000000);

    void updateFirstPhotoSubstitutionControlSnapshot(
        const ProductControlSnapshot& snapshot) noexcept {
        firstPhotoSubstitutionControlSequence_.fetch_add(
            1,
            std::memory_order_acq_rel);

        firstPhotoSubstitutionSelectionGeneration_.store(
            snapshot.selectionGeneration,
            std::memory_order_relaxed);

        std::uint32_t flags = 0;
        if (snapshot.enabled) {
            flags |= kFirstPhotoSubControlEnabled;
        }
        if (snapshot.mediaKind ==
            ProductMediaKind::Photo) {
            flags |= kFirstPhotoSubControlPhoto;
        }
        if (snapshot.hasMedia()) {
            flags |= kFirstPhotoSubControlHasMedia;
        }

        firstPhotoSubstitutionControlFlags_.store(
            flags,
            std::memory_order_relaxed);

        firstPhotoSubstitutionControlSequence_.fetch_add(
            1,
            std::memory_order_release);

        firstPhotoSubstitutionReadyGeneration_.store(
            0,
            std::memory_order_release);

        const bool activePhoto =
            snapshot.mediaKind ==
                ProductMediaKind::Photo &&
            snapshot.hasMedia() &&
            snapshot.selectionGeneration != 0;

        proof::BeginFirstLocalPhotoVirtualSubstitutionSelection(
            activePhoto
                ? snapshot.selectionGeneration
                : 0);
    }

    bool loadFirstPhotoSubstitutionControlSnapshot(
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
                firstPhotoSubstitutionControlSequence_.load(
                    std::memory_order_acquire);
            if ((before & UINT64_C(1)) != 0) {
                continue;
            }

            const std::uint64_t generation =
                firstPhotoSubstitutionSelectionGeneration_.load(
                    std::memory_order_relaxed);
            const std::uint32_t loadedFlags =
                firstPhotoSubstitutionControlFlags_.load(
                    std::memory_order_relaxed);

            const std::uint64_t after =
                firstPhotoSubstitutionControlSequence_.load(
                    std::memory_order_acquire);

            if (before == after &&
                (after & UINT64_C(1)) == 0) {
                *selectionGeneration =
                    generation;
                *flags =
                    loadedFlags;
                return true;
            }
        }

        return false;
    }

    void beginFirstPhotoSubstitutionReadyCheck() {
        if (controlQueue_ == nullptr) {
            return;
        }

        const ProductControlSnapshot snapshot =
            cache_.snapshot();

        if (!snapshot.enabled ||
            snapshot.mediaKind !=
                ProductMediaKind::Photo ||
            !snapshot.hasMedia() ||
            snapshot.selectionGeneration == 0) {
            firstPhotoSubstitutionReadyGeneration_.store(
                0,
                std::memory_order_release);
            return;
        }

        ++firstPhotoSubstitutionReadySerial_;
        const std::uint64_t serial =
            firstPhotoSubstitutionReadySerial_;
        const std::uint64_t generation =
            snapshot.selectionGeneration;

        checkFirstPhotoSubstitutionReady(
            generation,
            serial,
            0);
    }

    void checkFirstPhotoSubstitutionReady(
        std::uint64_t selectionGeneration,
        std::uint64_t serial,
        std::uint32_t attempt) {
        if (serial !=
            firstPhotoSubstitutionReadySerial_) {
            return;
        }

        const ProductControlSnapshot snapshot =
            cache_.snapshot();

        if (!snapshot.enabled ||
            snapshot.mediaKind !=
                ProductMediaKind::Photo ||
            !snapshot.hasMedia() ||
            snapshot.selectionGeneration !=
                selectionGeneration) {
            firstPhotoSubstitutionReadyGeneration_.store(
                0,
                std::memory_order_release);
            return;
        }

        bool ready = false;

        const bool geometryObserved =
            observedGeometry_.load(
                std::memory_order_acquire) != 0;

        if (geometryObserved &&
            session_ != nullptr &&
            firstPhotoSubstitutionProducerGeneration_ ==
                selectionGeneration &&
            firstPhotoSubstitutionProducerHealthy_) {
            const auto& selected =
                session_->selectedMedia();

            ready =
                selected.valid &&
                selected.kind ==
                    media_engine::
                        SelectedMediaKind::Photo &&
                selected.localPath ==
                    snapshot.mediaPath &&
                session_->playbackState() ==
                    frame_engine::
                        PlaybackState::Playing &&
                session_->readyQueue().size() > 0;
        }

        if (ready) {
            firstPhotoSubstitutionReadyGeneration_.store(
                selectionGeneration,
                std::memory_order_release);
            return;
        }

        firstPhotoSubstitutionReadyGeneration_.store(
            0,
            std::memory_order_release);

        if (attempt + 1 >=
            kFirstPhotoSubReadyMaxChecks) {
            return;
        }

        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                kFirstPhotoSubReadyRetryNanoseconds),
            controlQueue_,
            ^{
                this->checkFirstPhotoSubstitutionReady(
                    selectionGeneration,
                    serial,
                    attempt + 1);
            });
    }
#endif

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
    VirtualBlackFrame virtualBlackFrame_;
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

#if defined(VCAM_ACTIVATION_PARITY_DEVICE_REMEDIATION_PROOF)
    SharedMediaStager activationRemediationStager_;

    std::atomic<std::uint64_t>
        activationRemediationActiveGeneration_{0};
    std::atomic<std::uint64_t>
        activationRemediationControlObservedGeneration_{0};
    std::atomic<std::uint32_t>
        activationRemediationGeometryChangeCount_{0};

    bool activationRemediationActive_ = false;
    std::uint64_t activationRemediationSerial_ = 0;
    std::uint64_t activationRemediationGeneration_ = 0;
    std::string activationRemediationPath_;
    std::uint64_t activationRemediationPathHash_ = 0;
    bool activationRemediationMediaStaged_ = false;

    std::uint64_t activationRemediationTargetGeneration_ = 0;
    std::uint64_t activationRemediationTargetGeometry_ = 0;
    bool activationRemediationSelectAttempted_ = false;
    bool activationRemediationSelectResult_ = false;
    bool activationRemediationStartAttempted_ = false;
    bool activationRemediationStartResult_ = false;
    bool activationRemediationSessionInstalled_ = false;
    std::uint32_t activationRemediationSessionReplacementCount_ = 0;

    bool activationRemediationProducerHealthy_ = false;
    bool activationRemediationQueueBound_ = false;
    std::uint64_t activationRemediationQueueGeneration_ = 0;
    std::uint64_t activationRemediationQueueEpoch_ = 0;
    std::uint64_t activationRemediationAdapterGeneration_ = 0;
    std::uint64_t activationRemediationAdapterEpoch_ = 0;
#endif

#if defined(VCAM_IOS15_ACTIVATION_PARITY_PROOF)
    std::atomic<std::uint64_t>
        ios15ActivationControlSequence_{0};
    std::atomic<std::uint64_t>
        ios15ActivationSelectionGeneration_{0};
    std::atomic<std::uint32_t>
        ios15ActivationControlFlags_{0};
#endif

#if defined(VCAM_FIRST_LOCAL_PHOTO_SUBSTITUTION_DIAGNOSTIC_PROOF)
    std::atomic<std::uint64_t>
        firstPhotoSubDiagnosticControlSequence_{0};
    std::atomic<std::uint64_t>
        firstPhotoSubDiagnosticControlGeneration_{0};
    std::atomic<std::uint32_t>
        firstPhotoSubDiagnosticControlFlags_{0};
    std::atomic<std::uint64_t>
        firstPhotoSubDiagnosticActiveGeneration_{0};

    std::atomic<std::uint32_t>
        firstPhotoSubDiagnosticCallbackCount_{0};
    std::atomic<std::uint64_t>
        firstPhotoSubDiagnosticDecisionCountFinal_{0};
    std::atomic<std::uint64_t>
        firstPhotoSubDiagnosticVirtualCountFinal_{0};
    std::atomic<std::uint32_t>
        firstPhotoSubDiagnosticDecisionVirtualCount_{0};
    std::atomic<std::uint32_t>
        firstPhotoSubDiagnosticDecisionOriginalCount_{0};

    std::atomic<std::uint32_t>
        firstPhotoSubDiagnosticDisabledCount_{0};
    std::atomic<std::uint32_t>
        firstPhotoSubDiagnosticReconfigurationCount_{0};
    std::atomic<std::uint32_t>
        firstPhotoSubDiagnosticProducerUnavailableCount_{0};
    std::atomic<std::uint32_t>
        firstPhotoSubDiagnosticEmptyCount_{0};
    std::atomic<std::uint32_t>
        firstPhotoSubDiagnosticInvalidLeaseCount_{0};
    std::atomic<std::uint32_t>
        firstPhotoSubDiagnosticGeometryMismatchCount_{0};

    std::atomic<std::uint32_t>
        firstPhotoSubDiagnosticGeometryChangeCount_{0};
    std::atomic<std::uint64_t>
        firstPhotoSubDiagnosticLastGeometry_{0};
    std::atomic<std::uint32_t>
        firstPhotoSubDiagnosticLastDecision_{0};
    std::atomic<std::uint32_t>
        firstPhotoSubDiagnosticLastReason_{0};
    std::atomic<std::uint32_t>
        firstPhotoSubDiagnosticLastVirtualFlags_{0};
    std::atomic<bool>
        firstPhotoSubDiagnosticThresholdScheduled_{false};

    bool firstPhotoSubDiagnosticActive_ = false;
    bool firstPhotoSubDiagnosticPublished_ = false;
    std::uint64_t firstPhotoSubDiagnosticSerial_ = 0;
    std::uint64_t firstPhotoSubDiagnosticGeneration_ = 0;
    std::string firstPhotoSubDiagnosticPath_;

    std::uint64_t firstPhotoSubDiagnosticDecisionBaseline_ = 0;
    std::uint64_t firstPhotoSubDiagnosticVirtualBaseline_ = 0;

    std::uint64_t firstPhotoSubDiagnosticTargetGeneration_ = 0;
    std::uint64_t firstPhotoSubDiagnosticTargetGeometry_ = 0;
    std::uint64_t firstPhotoSubDiagnosticProducerGeneration_ = 0;
    bool firstPhotoSubDiagnosticProducerHealthy_ = false;

    int firstPhotoSubDiagnosticPrimaryToken_ = -1;
    int firstPhotoSubDiagnosticSelectionToken_ = -1;
    int firstPhotoSubDiagnosticCountsToken_ = -1;
    int firstPhotoSubDiagnosticFailCountsToken_ = -1;
    int firstPhotoSubDiagnosticObservedGeometryToken_ = -1;
    int firstPhotoSubDiagnosticTargetGeometryToken_ = -1;
    int firstPhotoSubDiagnosticSessionToken_ = -1;
    int firstPhotoSubDiagnosticLastToken_ = -1;
#endif

#if defined(VCAM_FIRST_LOCAL_PHOTO_VIRTUAL_SUBSTITUTION_PROOF)
    std::atomic<std::uint64_t>
        firstPhotoSubstitutionControlSequence_{0};
    std::atomic<std::uint64_t>
        firstPhotoSubstitutionSelectionGeneration_{0};
    std::atomic<std::uint32_t>
        firstPhotoSubstitutionControlFlags_{0};
    std::atomic<std::uint64_t>
        firstPhotoSubstitutionReadyGeneration_{0};

    std::uint64_t
        firstPhotoSubstitutionReadySerial_ = 0;
    std::uint64_t
        firstPhotoSubstitutionProducerGeneration_ = 0;
    bool
        firstPhotoSubstitutionProducerHealthy_ = false;
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

#if defined(VCAM_TESTING)
MediaserverdRuntime::MediaserverdRuntime(
    std::string controlPath,
    std::string notificationName)
    : impl_(
          std::make_unique<Impl>(
              std::move(controlPath),
              std::move(notificationName))) {}

bool MediaserverdRuntime::
drainControlQueueForTesting() {
    if (!impl_ ||
        impl_->controlQueue_ == nullptr) {
        return false;
    }

    dispatch_sync(
        impl_->controlQueue_,
        ^{});
    return true;
}

MediaserverdRuntimeTestSnapshot
MediaserverdRuntime::snapshotForTesting() {
    __block MediaserverdRuntimeTestSnapshot result;
    if (!impl_) {
        return result;
    }

    if (impl_->controlQueue_ == nullptr) {
        const ProductControlSnapshot control =
            impl_->cache_.snapshot();
        result.enabled = control.enabled;
        result.photoSelected =
            control.mediaKind ==
                ProductMediaKind::Photo;
        result.videoSelected =
            control.mediaKind ==
                ProductMediaKind::Video;
        result.hasMedia = control.hasMedia();
        result.selectionGeneration =
            control.selectionGeneration;
        result.controlRefreshCount =
            impl_->cache_.refreshCount();
        return result;
    }

    dispatch_sync(
        impl_->controlQueue_,
        ^{
            const ProductControlSnapshot control =
                impl_->cache_.snapshot();
            result.enabled = control.enabled;
            result.photoSelected =
                control.mediaKind ==
                    ProductMediaKind::Photo;
            result.videoSelected =
                control.mediaKind ==
                    ProductMediaKind::Video;
            result.hasMedia =
                control.hasMedia();
            result.selectionGeneration =
                control.selectionGeneration;
            result.controlRefreshCount =
                impl_->cache_.refreshCount();

            if (impl_->session_ != nullptr) {
                result.sessionExists = true;
                result.producerHealthy =
                    impl_->session_->playbackState() ==
                    frame_engine::
                        PlaybackState::Playing;
                result.readyQueueSize =
                    impl_->session_->readyQueue().size();
                result.queueGeneration =
                    impl_->session_->state().
                        mediaGeneration();
                result.queueEpoch =
                    impl_->session_->state().
                        timelineEpoch();
                result.publishedFrameCount =
                    impl_->session_->
                        publishedFrameCount();
                result.photoDecodeCount =
                    impl_->session_->
                        photoDecodeCount();
                result.loopIteration =
                    impl_->session_->state().
                        loopIteration();
            }
        });

    return result;
}
#endif

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
