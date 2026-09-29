#include "CameraConsumerAdapter.h"

#include <limits>
#include <utility>

namespace vcam::product {

namespace {

bool SupportsInPlaceBlackOwnership(
    CVPixelBufferRef original) noexcept {
    if (original == nullptr ||
        !CVPixelBufferIsPlanar(original) ||
        CVPixelBufferGetPlaneCount(original) != 2) {
        return false;
    }

    const OSType format =
        CVPixelBufferGetPixelFormatType(
            original);
    return
        format ==
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        format ==
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
}

std::size_t PixelBufferFootprint(
    CVPixelBufferRef pixelBuffer) noexcept {
    if (pixelBuffer == nullptr) {
        return 0;
    }

    const std::size_t dataSize =
        CVPixelBufferGetDataSize(pixelBuffer);
    if (dataSize != 0) {
        return dataSize;
    }

    if (!CVPixelBufferIsPlanar(pixelBuffer)) {
        const std::size_t stride =
            CVPixelBufferGetBytesPerRow(pixelBuffer);
        const std::size_t height =
            CVPixelBufferGetHeight(pixelBuffer);
        if (height != 0 &&
            stride <=
                std::numeric_limits<std::size_t>::max() /
                    height) {
            return stride * height;
        }
        return 0;
    }

    std::size_t total = 0;
    const std::size_t planeCount =
        CVPixelBufferGetPlaneCount(pixelBuffer);
    for (std::size_t plane = 0;
         plane < planeCount;
         ++plane) {
        const std::size_t stride =
            CVPixelBufferGetBytesPerRowOfPlane(
                pixelBuffer,
                plane);
        const std::size_t height =
            CVPixelBufferGetHeightOfPlane(
                pixelBuffer,
                plane);
        if (height != 0 &&
            stride >
                (std::numeric_limits<std::size_t>::max() -
                 total) /
                    height) {
            return 0;
        }
        total += stride * height;
    }
    return total;
}

}  // namespace

CameraConsumerAdapter::~CameraConsumerAdapter() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        clearPhotoVariantsLocked();
    }

    blackFallback_.store(
        nullptr,
        std::memory_order_release);

    std::lock_guard<std::mutex> lock(
        blackMutex_);

    for (std::size_t index = 0;
         index < blackFallbackHistoryCount_;
         ++index) {
        if (blackFallbackHistory_[index] !=
            nullptr) {
            CVPixelBufferRelease(
                blackFallbackHistory_[index]);
            blackFallbackHistory_[index] =
                nullptr;
        }
    }
}

void CameraConsumerAdapter::setEnabled(
    bool enabled) noexcept {
    enabled_.store(
        enabled,
        std::memory_order_release);

    if (!enabled) {
        std::lock_guard<std::mutex> lock(mutex_);
        clearPhotoVariantsLocked();
    }
}

void CameraConsumerAdapter::bindQueue(
    frame_engine::ReadyFrameQueue* queue,
    std::uint64_t mediaGeneration,
    std::uint64_t timelineEpoch,
    bool producerHealthy,
    bool reusableStaticMedia,
    std::uint64_t reusableStaticRevision) {
    std::lock_guard<std::mutex> lock(mutex_);

    const bool logicalIdentityChanged =
        context_.currentMediaGeneration !=
            mediaGeneration ||
        context_.currentTimelineEpoch !=
            timelineEpoch ||
        reusableStaticMedia_ !=
            reusableStaticMedia ||
        reusableStaticRevision_ !=
            reusableStaticRevision;

    if (logicalIdentityChanged) {
        clearPhotoVariantsLocked();
    }

    // Queue replacement alone is not logical PHOTO invalidation. Geometry
    // variants belong to generation/epoch/transform revision, not a queue
    // object's address.
    queue_ = queue;
    context_.currentMediaGeneration =
        mediaGeneration;
    context_.currentTimelineEpoch =
        timelineEpoch;
    context_.minimumSequence =
        std::nullopt;
    producerHealthy_ = producerHealthy;
    reusableStaticMedia_ =
        reusableStaticMedia;
    reusableStaticRevision_ =
        reusableStaticMedia
            ? reusableStaticRevision
            : 0;
}

void CameraConsumerAdapter::updateContext(
    std::uint64_t mediaGeneration,
    std::uint64_t timelineEpoch,
    bool producerHealthy,
    bool reusableStaticMedia,
    std::uint64_t reusableStaticRevision) {
    std::lock_guard<std::mutex> lock(mutex_);

    if (context_.currentMediaGeneration !=
            mediaGeneration ||
        context_.currentTimelineEpoch !=
            timelineEpoch ||
        reusableStaticMedia_ !=
            reusableStaticMedia ||
        reusableStaticRevision_ !=
            reusableStaticRevision) {
        clearPhotoVariantsLocked();
    }

    context_.currentMediaGeneration =
        mediaGeneration;
    context_.currentTimelineEpoch =
        timelineEpoch;
    context_.minimumSequence =
        std::nullopt;
    producerHealthy_ = producerHealthy;
    reusableStaticMedia_ =
        reusableStaticMedia;
    reusableStaticRevision_ =
        reusableStaticMedia
            ? reusableStaticRevision
            : 0;
}

void CameraConsumerAdapter::unbindQueue() {
    std::lock_guard<std::mutex> lock(mutex_);
    clearPhotoVariantsLocked();
    queue_ = nullptr;
    producerHealthy_ = false;
    reusableStaticMedia_ = false;
    reusableStaticRevision_ = 0;
    context_ = {};
}

void CameraConsumerAdapter::notePhotoGeometryObserved(
    std::size_t width,
    std::size_t height,
    OSType pixelFormat,
    std::uint64_t mediaGeneration,
    std::uint64_t timelineEpoch,
    std::uint64_t transformRevision) {
    if (width == 0 ||
        height == 0 ||
        pixelFormat == 0 ||
        mediaGeneration == 0 ||
        timelineEpoch == 0) {
        return;
    }

    std::lock_guard<std::mutex> lock(mutex_);

    if (!reusableStaticMedia_ ||
        context_.currentMediaGeneration !=
            mediaGeneration ||
        context_.currentTimelineEpoch !=
            timelineEpoch ||
        reusableStaticRevision_ !=
            transformRevision) {
        return;
    }

    if (photoGeometryObservationSerial_ ==
        UINT64_MAX) {
        std::uint64_t serial = 1;
        for (auto& entry : photoWorkingSet_) {
            if (entry.valid) {
                entry.lastObservedSerial =
                    serial++;
            }
        }
        photoGeometryObservationSerial_ =
            serial;
    } else {
        ++photoGeometryObservationSerial_;
    }

    PhotoWorkingSetEntry* entry =
        findPhotoWorkingSetEntryLocked(
            width,
            height,
            pixelFormat,
            mediaGeneration,
            timelineEpoch,
            transformRevision);

    if (entry == nullptr) {
        for (auto& candidate : photoWorkingSet_) {
            if (!candidate.valid ||
                candidate.mediaGeneration !=
                    mediaGeneration ||
                candidate.timelineEpoch !=
                    timelineEpoch ||
                candidate.transformRevision !=
                    transformRevision) {
                entry = &candidate;
                break;
            }
        }
    }

    if (entry == nullptr) {
        entry = &photoWorkingSet_[0];
        for (auto& candidate : photoWorkingSet_) {
            if (candidate.lastObservedSerial <
                entry->lastObservedSerial) {
                entry = &candidate;
            }
        }
    }

    const bool sameGeometry =
        entry->valid &&
        entry->mediaGeneration ==
            mediaGeneration &&
        entry->timelineEpoch ==
            timelineEpoch &&
        entry->transformRevision ==
            transformRevision &&
        entry->width == width &&
        entry->height == height &&
        entry->pixelFormat == pixelFormat;

    if (!sameGeometry) {
        *entry = {};
        entry->valid = true;
        entry->mediaGeneration =
            mediaGeneration;
        entry->timelineEpoch =
            timelineEpoch;
        entry->transformRevision =
            transformRevision;
        entry->width = width;
        entry->height = height;
        entry->pixelFormat =
            pixelFormat;
    } else if (
        entry->preparedOnce &&
        !entry->repreparePending &&
        findPhotoVariantLocked(
            width,
            height,
            pixelFormat,
            mediaGeneration,
            timelineEpoch,
            transformRevision) == nullptr) {
        ++photoVariantReprepareCount_;
        entry->repreparePending = true;
    }

    entry->lastObservedSerial =
        photoGeometryObservationSerial_;
    if (entry->observationCount !=
        UINT64_MAX) {
        ++entry->observationCount;
    }
}

bool CameraConsumerAdapter::bindBlackFallback(
    CVPixelBufferRef pixelBuffer) {
    if (pixelBuffer == nullptr) {
        return false;
    }

    std::lock_guard<std::mutex> lock(
        blackMutex_);

    for (std::size_t index = 0;
         index < blackFallbackHistoryCount_;
         ++index) {
        CVPixelBufferRef cached =
            blackFallbackHistory_[index];

        if (cached == pixelBuffer ||
            (cached != nullptr &&
             CVPixelBufferGetWidth(cached) ==
                 CVPixelBufferGetWidth(pixelBuffer) &&
             CVPixelBufferGetHeight(cached) ==
                 CVPixelBufferGetHeight(pixelBuffer) &&
             CVPixelBufferGetPixelFormatType(cached) ==
                 CVPixelBufferGetPixelFormatType(
                     pixelBuffer))) {
            blackFallback_.store(
                cached,
                std::memory_order_release);
            return true;
        }
    }

    if (blackFallbackHistoryCount_ >=
        kBlackFallbackCapacity) {
        return false;
    }

    CVPixelBufferRetain(pixelBuffer);

    blackFallbackHistory_[
        blackFallbackHistoryCount_++] =
            pixelBuffer;

    blackFallback_.store(
        pixelBuffer,
        std::memory_order_release);

    return true;
}

void CameraConsumerAdapter::
clearBlackFallback() noexcept {
    blackFallback_.store(
        nullptr,
        std::memory_order_release);
}

CameraDecision CameraConsumerAdapter::decide(
    CVPixelBufferRef original) noexcept {
    decisionCount_.fetch_add(
        1,
        std::memory_order_relaxed);

    CameraDecision decision;
    decision.source =
        CameraDecisionSource::Original;
    decision.pixelBuffer = original;

    if (!enabled_.load(
            std::memory_order_acquire)) {
        decision.reason =
            CameraFailOpenReason::Disabled;
        return decision;
    }

    CameraFailOpenReason mediaFailure =
        CameraFailOpenReason::None;

    std::unique_lock<std::mutex> lock(
        mutex_,
        std::try_to_lock);

    if (!lock.owns_lock()) {
        mediaFailure =
            CameraFailOpenReason::
                ReconfigurationContended;
    } else {
        if (reusableStaticMedia_) {
            PhotoVariantSlot* retained =
                findPhotoVariantLocked(
                    original);
            if (retained != nullptr &&
                retained->pixelBuffer !=
                    nullptr) {
                retained->lastUseSerial =
                    nextPhotoVariantUseSerialLocked();

                virtualDecisionCount_.
                    fetch_add(
                        1,
                        std::memory_order_relaxed);
                mediaVirtualDecisionCount_.
                    fetch_add(
                        1,
                        std::memory_order_relaxed);

                decision.kind =
                    CameraDecisionKind::Virtual;
                decision.source =
                    CameraDecisionSource::
                        PreparedMedia;
                decision.pixelBuffer =
                    retained->pixelBuffer;
                return decision;
            }
        }

        if (queue_ == nullptr) {
            mediaFailure =
                CameraFailOpenReason::
                    ProducerUnavailable;
        } else if (
            !producerHealthy_ &&
            !reusableStaticMedia_) {
            mediaFailure =
                CameraFailOpenReason::
                    ProducerUnavailable;
        } else {
            auto acquired =
                reusableStaticMedia_ &&
                        original != nullptr
                    ? queue_->tryAcquireMatching(
                          context_,
                          CVPixelBufferGetWidth(
                              original),
                          CVPixelBufferGetHeight(
                              original),
                          CVPixelBufferGetPixelFormatType(
                              original))
                    : queue_->tryAcquire(
                          context_);

            if (acquired.kind !=
                    frame_engine::
                        AcquireResultKind::Acquired ||
                !acquired.lease.has_value()) {
                mediaFailure =
                    CameraFailOpenReason::
                        EmptyOrNoEligibleFrame;
            } else {
                const frame_engine::FrameLease*
                    lease =
                        acquired.lease->
                            frameLease();

                if (!acquired.lease->valid() ||
                    lease == nullptr ||
                    lease->pixelBuffer() ==
                        nullptr) {
                    mediaFailure =
                        CameraFailOpenReason::
                            InvalidLease;
                } else if (!matchesOriginalGeometry(
                               original,
                               *lease)) {
                    mediaFailure =
                        CameraFailOpenReason::
                            GeometryMismatch;
                } else {
                    CVPixelBufferRef selected =
                        lease->pixelBuffer();

                    if (reusableStaticMedia_) {
                        selected =
                            retainPhotoVariantLocked(
                                selected,
                                context_.
                                    currentMediaGeneration,
                                context_.
                                    currentTimelineEpoch,
                                reusableStaticRevision_);
                    } else {
                        pin(
                            std::move(
                                *acquired.lease));
                    }

                    virtualDecisionCount_.
                        fetch_add(
                            1,
                            std::memory_order_relaxed);
                    mediaVirtualDecisionCount_.
                        fetch_add(
                            1,
                            std::memory_order_relaxed);

                    decision.kind =
                        CameraDecisionKind::Virtual;
                    decision.source =
                        CameraDecisionSource::
                            PreparedMedia;
                    decision.reason =
                        CameraFailOpenReason::None;
                    decision.pixelBuffer =
                        selected;
                    return decision;
                }
            }
        }
    }

    if (lock.owns_lock()) {
        lock.unlock();
    }

    return blackOrEmergencyOriginal(
        original,
        mediaFailure);
}

CameraDecision
CameraConsumerAdapter::
blackOrEmergencyOriginal(
    CVPixelBufferRef original,
    CameraFailOpenReason
        mediaFailureReason) noexcept {
    CameraDecision decision;
    decision.source =
        CameraDecisionSource::Original;
    decision.pixelBuffer = original;
    decision.mediaFailureReason =
        mediaFailureReason;

    CVPixelBufferRef black =
        blackFallback_.load(
            std::memory_order_acquire);

    if (matchesOriginalGeometry(
            original,
            black)) {
        virtualDecisionCount_.fetch_add(
            1,
            std::memory_order_relaxed);
        blackVirtualDecisionCount_.
            fetch_add(
                1,
                std::memory_order_relaxed);

        decision.kind =
            CameraDecisionKind::Virtual;
        decision.source =
            CameraDecisionSource::
                BlackFallback;
        decision.reason =
            CameraFailOpenReason::None;
        decision.pixelBuffer =
            black;
        return decision;
    }

    if (SupportsInPlaceBlackOwnership(
            original)) {
        virtualDecisionCount_.fetch_add(
            1,
            std::memory_order_relaxed);
        inPlaceBlackGuardDecisionCount_.
            fetch_add(
                1,
                std::memory_order_relaxed);

        decision.kind =
            CameraDecisionKind::Virtual;
        decision.source =
            CameraDecisionSource::
                InPlaceBlackOwnershipGuard;
        decision.reason =
            CameraFailOpenReason::None;
        decision.pixelBuffer =
            original;
        return decision;
    }

    emergencyOriginalDecisionCount_.
        fetch_add(
            1,
            std::memory_order_relaxed);
    unsupportedFormatDecisionCount_.
        fetch_add(
            1,
            std::memory_order_relaxed);

    decision.reason =
        CameraFailOpenReason::
            UnsupportedPixelFormat;
    return decision;
}

std::size_t
CameraConsumerAdapter::pinnedLeaseCount() const {
    std::lock_guard<std::mutex> lock(mutex_);
    std::size_t count = 0;
    for (const auto& entry : pinned_) {
        if (entry.has_value() &&
            entry->valid()) {
            ++count;
        }
    }
    return count;
}

std::size_t
CameraConsumerAdapter::photoVariantCount() const {
    std::lock_guard<std::mutex> lock(mutex_);

    std::size_t count = 0;
    for (const auto& slot : photoVariants_) {
        if (slot.pixelBuffer != nullptr) {
            ++count;
        }
    }
    return count;
}

std::size_t
CameraConsumerAdapter::
photoVariantRetainedBytes() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return photoVariantRetainedBytes_;
}

std::size_t
CameraConsumerAdapter::
photoVariantWorkingSetCount() const {
    std::lock_guard<std::mutex> lock(mutex_);

    std::size_t count = 0;
    for (const auto& entry : photoWorkingSet_) {
        if (!entry.valid ||
            entry.mediaGeneration !=
                context_.currentMediaGeneration ||
            entry.timelineEpoch !=
                context_.currentTimelineEpoch ||
            entry.transformRevision !=
                reusableStaticRevision_) {
            continue;
        }

        const std::uint64_t age =
            photoGeometryObservationSerial_ >=
                    entry.lastObservedSerial
                ? photoGeometryObservationSerial_ -
                      entry.lastObservedSerial
                : UINT64_MAX;
        if (age <=
            kPhotoWorkingSetActiveObservationWindow) {
            ++count;
        }
    }
    return count;
}

std::uint64_t
CameraConsumerAdapter::
photoVariantEvictionCount() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return photoVariantEvictionCount_;
}

std::uint64_t
CameraConsumerAdapter::
photoVariantReprepareCount() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return photoVariantReprepareCount_;
}

bool CameraConsumerAdapter::
hasReusablePhotoVariant(
    std::size_t width,
    std::size_t height,
    OSType pixelFormat,
    std::uint64_t mediaGeneration,
    std::uint64_t timelineEpoch,
    std::uint64_t transformRevision) const {
    std::lock_guard<std::mutex> lock(mutex_);
    return findPhotoVariantLocked(
               width,
               height,
               pixelFormat,
               mediaGeneration,
               timelineEpoch,
               transformRevision) != nullptr;
}

std::size_t
CameraConsumerAdapter::
blackFallbackCacheCount() const {
    std::lock_guard<std::mutex> lock(
        blackMutex_);
    return blackFallbackHistoryCount_;
}

bool CameraConsumerAdapter::
hasCompatibleBlackFallback(
    CVPixelBufferRef original) const noexcept {
    return matchesOriginalGeometry(
        original,
        blackFallback_.load(
            std::memory_order_acquire));
}

std::uint64_t
CameraConsumerAdapter::decisionCount() const noexcept {
    return decisionCount_.load(
        std::memory_order_relaxed);
}

std::uint64_t
CameraConsumerAdapter::virtualDecisionCount() const noexcept {
    return virtualDecisionCount_.load(
        std::memory_order_relaxed);
}

std::uint64_t
CameraConsumerAdapter::
mediaVirtualDecisionCount() const noexcept {
    return mediaVirtualDecisionCount_.load(
        std::memory_order_relaxed);
}

std::uint64_t
CameraConsumerAdapter::
blackVirtualDecisionCount() const noexcept {
    return blackVirtualDecisionCount_.load(
        std::memory_order_relaxed);
}

std::uint64_t
CameraConsumerAdapter::
emergencyOriginalDecisionCount() const noexcept {
    return emergencyOriginalDecisionCount_.
        load(
            std::memory_order_relaxed);
}

std::uint64_t
CameraConsumerAdapter::
inPlaceBlackGuardDecisionCount() const noexcept {
    return inPlaceBlackGuardDecisionCount_.
        load(
            std::memory_order_relaxed);
}

std::uint64_t
CameraConsumerAdapter::
unsupportedFormatDecisionCount() const noexcept {
    return unsupportedFormatDecisionCount_.
        load(
            std::memory_order_relaxed);
}

std::uint64_t
CameraConsumerAdapter::
enabledSupportedOriginalDecisionCount() const noexcept {
    return enabledSupportedOriginalDecisionCount_.
        load(
            std::memory_order_relaxed);
}

bool CameraConsumerAdapter::
matchesOriginalGeometry(
    CVPixelBufferRef original,
    const frame_engine::FrameLease& lease)
    const noexcept {
    if (original == nullptr) {
        return false;
    }

    return
        CVPixelBufferGetWidth(original) ==
            lease.width() &&
        CVPixelBufferGetHeight(original) ==
            lease.height() &&
        CVPixelBufferGetPixelFormatType(
            original) ==
            lease.pixelFormat();
}

bool CameraConsumerAdapter::
matchesOriginalGeometry(
    CVPixelBufferRef original,
    CVPixelBufferRef candidate)
    const noexcept {
    if (original == nullptr ||
        candidate == nullptr) {
        return false;
    }

    return
        CVPixelBufferGetWidth(original) ==
            CVPixelBufferGetWidth(
                candidate) &&
        CVPixelBufferGetHeight(original) ==
            CVPixelBufferGetHeight(
                candidate) &&
        CVPixelBufferGetPixelFormatType(
            original) ==
            CVPixelBufferGetPixelFormatType(
                candidate);
}

void CameraConsumerAdapter::
clearPhotoVariantsLocked() noexcept {
    for (auto& slot : photoVariants_) {
        if (slot.pixelBuffer != nullptr) {
            CVPixelBufferRelease(
                slot.pixelBuffer);
        }
        slot = {};
    }
    photoVariantRetainedBytes_ = 0;
    for (auto& entry : photoWorkingSet_) {
        entry = {};
    }
    photoGeometryObservationSerial_ = 0;
    photoVariantUseSerial_ = 0;
    photoVariantEvictionCount_ = 0;
    photoVariantReprepareCount_ = 0;
}

CameraConsumerAdapter::PhotoVariantSlot*
CameraConsumerAdapter::findPhotoVariantLocked(
    CVPixelBufferRef original) noexcept {
    if (original == nullptr) {
        return nullptr;
    }

    return const_cast<PhotoVariantSlot*>(
        static_cast<const CameraConsumerAdapter*>(
            this)->findPhotoVariantLocked(
                CVPixelBufferGetWidth(
                    original),
                CVPixelBufferGetHeight(
                    original),
                CVPixelBufferGetPixelFormatType(
                    original),
                context_.
                    currentMediaGeneration,
                context_.
                    currentTimelineEpoch,
                reusableStaticRevision_));
}

const CameraConsumerAdapter::PhotoVariantSlot*
CameraConsumerAdapter::findPhotoVariantLocked(
    std::size_t width,
    std::size_t height,
    OSType pixelFormat,
    std::uint64_t mediaGeneration,
    std::uint64_t timelineEpoch,
    std::uint64_t transformRevision) const noexcept {
    for (const auto& slot : photoVariants_) {
        if (slot.pixelBuffer != nullptr &&
            slot.mediaGeneration ==
                mediaGeneration &&
            slot.timelineEpoch ==
                timelineEpoch &&
            slot.transformRevision ==
                transformRevision &&
            slot.width == width &&
            slot.height == height &&
            slot.pixelFormat ==
                pixelFormat) {
            return &slot;
        }
    }

    return nullptr;
}

PhotoWorkingSetEntry*
CameraConsumerAdapter::
findPhotoWorkingSetEntryLocked(
    std::size_t width,
    std::size_t height,
    OSType pixelFormat,
    std::uint64_t mediaGeneration,
    std::uint64_t timelineEpoch,
    std::uint64_t transformRevision) noexcept {
    return const_cast<PhotoWorkingSetEntry*>(
        static_cast<const CameraConsumerAdapter*>(
            this)->findPhotoWorkingSetEntryLocked(
                width,
                height,
                pixelFormat,
                mediaGeneration,
                timelineEpoch,
                transformRevision));
}

const CameraConsumerAdapter::PhotoWorkingSetEntry*
CameraConsumerAdapter::
findPhotoWorkingSetEntryLocked(
    std::size_t width,
    std::size_t height,
    OSType pixelFormat,
    std::uint64_t mediaGeneration,
    std::uint64_t timelineEpoch,
    std::uint64_t transformRevision) const noexcept {
    for (const auto& entry : photoWorkingSet_) {
        if (entry.valid &&
            entry.mediaGeneration ==
                mediaGeneration &&
            entry.timelineEpoch ==
                timelineEpoch &&
            entry.transformRevision ==
                transformRevision &&
            entry.width == width &&
            entry.height == height &&
            entry.pixelFormat ==
                pixelFormat) {
            return &entry;
        }
    }
    return nullptr;
}

bool CameraConsumerAdapter::
photoGeometryActiveLocked(
    const PhotoVariantSlot& slot) const noexcept {
    const PhotoWorkingSetEntry* entry =
        findPhotoWorkingSetEntryLocked(
            slot.width,
            slot.height,
            slot.pixelFormat,
            slot.mediaGeneration,
            slot.timelineEpoch,
            slot.transformRevision);
    if (entry == nullptr ||
        photoGeometryObservationSerial_ <
            entry->lastObservedSerial) {
        return false;
    }

    return
        photoGeometryObservationSerial_ -
            entry->lastObservedSerial <=
        kPhotoWorkingSetActiveObservationWindow;
}

CVPixelBufferRef
CameraConsumerAdapter::
retainPhotoVariantLocked(
    CVPixelBufferRef pixelBuffer,
    std::uint64_t mediaGeneration,
    std::uint64_t timelineEpoch,
    std::uint64_t transformRevision) noexcept {
    if (pixelBuffer == nullptr) {
        return nullptr;
    }

    const std::size_t width =
        CVPixelBufferGetWidth(
            pixelBuffer);
    const std::size_t height =
        CVPixelBufferGetHeight(
            pixelBuffer);
    const OSType pixelFormat =
        CVPixelBufferGetPixelFormatType(
            pixelBuffer);
    const std::size_t retainedBytes =
        PixelBufferFootprint(pixelBuffer);

    if (retainedBytes == 0 ||
        retainedBytes >
            kPhotoVariantRetainedByteBudget) {
        return nullptr;
    }

    auto releaseSlot =
        [this](
            PhotoVariantSlot& slot,
            bool countEviction) {
            if (slot.pixelBuffer == nullptr) {
                slot = {};
                return;
            }

            if (photoVariantRetainedBytes_ >=
                slot.retainedBytes) {
                photoVariantRetainedBytes_ -=
                    slot.retainedBytes;
            } else {
                photoVariantRetainedBytes_ = 0;
            }

            CVPixelBufferRelease(
                slot.pixelBuffer);
            slot = {};
            if (countEviction) {
                ++photoVariantEvictionCount_;
            }
        };

    for (auto& slot : photoVariants_) {
        if (slot.pixelBuffer != nullptr &&
            (slot.mediaGeneration !=
                 mediaGeneration ||
             slot.timelineEpoch !=
                 timelineEpoch ||
             slot.transformRevision !=
                 transformRevision)) {
            releaseSlot(
                slot,
                false);
        }
    }

    PhotoVariantSlot* destination = nullptr;
    for (auto& slot : photoVariants_) {
        if (slot.pixelBuffer != nullptr &&
            slot.mediaGeneration ==
                mediaGeneration &&
            slot.timelineEpoch ==
                timelineEpoch &&
            slot.transformRevision ==
                transformRevision &&
            slot.width == width &&
            slot.height == height &&
            slot.pixelFormat ==
                pixelFormat) {
            destination = &slot;
            break;
        }
    }

    const auto chooseEviction =
        [this, &destination]()
            -> PhotoVariantSlot* {
            PhotoVariantSlot* bestInactive =
                nullptr;
            PhotoVariantSlot* bestActive =
                nullptr;

            for (auto& slot : photoVariants_) {
                if (&slot == destination ||
                    slot.pixelBuffer == nullptr) {
                    continue;
                }

                PhotoVariantSlot*& best =
                    photoGeometryActiveLocked(
                        slot)
                        ? bestActive
                        : bestInactive;
                if (best == nullptr ||
                    slot.lastUseSerial <
                        best->lastUseSerial) {
                    best = &slot;
                }
            }

            return bestInactive != nullptr
                ? bestInactive
                : bestActive;
        };

    if (destination == nullptr) {
        for (auto& slot : photoVariants_) {
            if (slot.pixelBuffer == nullptr) {
                destination = &slot;
                break;
            }
        }
    }

    while (
        photoVariantRetainedBytes_ +
            retainedBytes -
            (destination != nullptr
                 ? destination->retainedBytes
                 : 0) >
        kPhotoVariantRetainedByteBudget) {
        PhotoVariantSlot* reclaim =
            chooseEviction();
        if (reclaim == nullptr) {
            return nullptr;
        }
        releaseSlot(
            *reclaim,
            true);
        if (destination == nullptr) {
            destination = reclaim;
        }
    }

    if (destination == nullptr) {
        destination =
            chooseEviction();
        if (destination == nullptr) {
            return nullptr;
        }
        releaseSlot(
            *destination,
            true);
    }

    if (destination->pixelBuffer !=
        pixelBuffer) {
        const std::size_t previousBytes =
            destination->retainedBytes;
        CVPixelBufferRetain(pixelBuffer);
        if (destination->pixelBuffer !=
            nullptr) {
            CVPixelBufferRelease(
                destination->pixelBuffer);
        }

        if (photoVariantRetainedBytes_ >=
            previousBytes) {
            photoVariantRetainedBytes_ -=
                previousBytes;
        } else {
            photoVariantRetainedBytes_ = 0;
        }

        destination->pixelBuffer =
            pixelBuffer;
        destination->retainedBytes =
            retainedBytes;
        photoVariantRetainedBytes_ +=
            retainedBytes;
    }

    destination->mediaGeneration =
        mediaGeneration;
    destination->timelineEpoch =
        timelineEpoch;
    destination->transformRevision =
        transformRevision;
    destination->width = width;
    destination->height = height;
    destination->pixelFormat =
        pixelFormat;
    destination->lastUseSerial =
        nextPhotoVariantUseSerialLocked();

    PhotoWorkingSetEntry* working =
        findPhotoWorkingSetEntryLocked(
            width,
            height,
            pixelFormat,
            mediaGeneration,
            timelineEpoch,
            transformRevision);
    if (working != nullptr) {
        working->preparedOnce = true;
        working->repreparePending = false;
    }

    return destination->pixelBuffer;
}

std::uint64_t
CameraConsumerAdapter::
nextPhotoVariantUseSerialLocked() noexcept {
    if (photoVariantUseSerial_ ==
        UINT64_MAX) {
        std::uint64_t next = 1;
        for (auto& slot : photoVariants_) {
            if (slot.pixelBuffer != nullptr) {
                slot.lastUseSerial = next++;
            }
        }
        photoVariantUseSerial_ = next;
    } else {
        ++photoVariantUseSerial_;
    }

    return photoVariantUseSerial_;
}

void CameraConsumerAdapter::pin(
    frame_engine::ReadyFrameLease lease) {
    pinned_[nextPinnedIndex_].reset();
    pinned_[nextPinnedIndex_].emplace(
        std::move(lease));

    nextPinnedIndex_ =
        (nextPinnedIndex_ + 1) %
        kPinnedLeaseCapacity;
}

}  // namespace vcam::product
