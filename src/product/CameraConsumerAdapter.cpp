#include "CameraConsumerAdapter.h"

#include <algorithm>
#include <cmath>
#if defined(VCAM_TESTING)
#include <cstdio>
#endif
#include <cstring>
#include <limits>
#include <new>
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

struct DirectRect {
    std::size_t x = 0;
    std::size_t y = 0;
    std::size_t width = 0;
    std::size_t height = 0;
};

struct DirectRegions {
    DirectRect source{};
    DirectRect destination{};
};

std::size_t EvenExtent(
    double requested,
    std::size_t maximum) noexcept {
    if (maximum < 2) {
        return 0;
    }
    std::size_t value =
        static_cast<std::size_t>(
            std::llround(requested));
    value = std::max<std::size_t>(
        2,
        std::min(maximum, value));
    value -= value % 2;
    return value == 0 ? 2 : value;
}

long long EvenOffset(
    long long value) noexcept {
    if ((value % 2) != 0) {
        value += value > 0 ? -1 : 1;
    }
    return value;
}

bool ComputeBaseCrop(
    std::size_t sourceWidth,
    std::size_t sourceHeight,
    std::size_t destinationWidth,
    std::size_t destinationHeight,
    DirectRect* crop) noexcept {
    if (crop == nullptr ||
        sourceWidth < 2 ||
        sourceHeight < 2 ||
        destinationWidth < 2 ||
        destinationHeight < 2) {
        return false;
    }

    std::size_t width = sourceWidth;
    std::size_t height = sourceHeight;

    const long double sourceAspect =
        static_cast<long double>(sourceWidth) /
        static_cast<long double>(sourceHeight);
    const long double destinationAspect =
        static_cast<long double>(destinationWidth) /
        static_cast<long double>(destinationHeight);

    if (sourceAspect > destinationAspect) {
        width = EvenExtent(
            static_cast<double>(sourceHeight) *
                static_cast<double>(destinationWidth) /
                static_cast<double>(destinationHeight),
            sourceWidth);
    } else if (sourceAspect < destinationAspect) {
        height = EvenExtent(
            static_cast<double>(sourceWidth) *
                static_cast<double>(destinationHeight) /
                static_cast<double>(destinationWidth),
            sourceHeight);
    }

    if (width < 2 ||
        height < 2) {
        return false;
    }

    std::size_t x =
        (sourceWidth - width) / 2;
    std::size_t y =
        (sourceHeight - height) / 2;
    x &= ~std::size_t{1};
    y &= ~std::size_t{1};

    *crop = {
        x,
        y,
        width,
        height,
    };
    return true;
}

bool ComputeDirectRegions(
    std::size_t sourceWidth,
    std::size_t sourceHeight,
    std::size_t destinationWidth,
    std::size_t destinationHeight,
    double translationX,
    double translationY,
    double scale,
    DirectRegions* regions) noexcept {
    if (regions == nullptr ||
        !std::isfinite(translationX) ||
        !std::isfinite(translationY) ||
        !std::isfinite(scale)) {
        return false;
    }

    translationX =
        std::clamp(
            translationX,
            -1.0,
            1.0);
    translationY =
        std::clamp(
            translationY,
            -1.0,
            1.0);
    scale =
        std::clamp(
            scale <= 0.0 ? 1.0 : scale,
            0.25,
            4.0);

    DirectRect base;
    if (!ComputeBaseCrop(
            sourceWidth,
            sourceHeight,
            destinationWidth,
            destinationHeight,
            &base)) {
        return false;
    }

    DirectRegions result;
    result.source = base;
    result.destination = {
        0,
        0,
        destinationWidth,
        destinationHeight,
    };

    constexpr double tolerance = 1.0e-6;

    if (scale > 1.0 + tolerance) {
        const std::size_t cropWidth =
            EvenExtent(
                static_cast<double>(
                    base.width) /
                    scale,
                base.width);
        const std::size_t cropHeight =
            EvenExtent(
                static_cast<double>(
                    base.height) /
                    scale,
                base.height);
        if (cropWidth == 0 ||
            cropHeight == 0) {
            return false;
        }

        const std::size_t maxX =
            base.width - cropWidth;
        const std::size_t maxY =
            base.height - cropHeight;
        const long long shiftX =
            EvenOffset(
                static_cast<long long>(
                    std::llround(
                        translationX *
                        static_cast<double>(maxX) /
                        2.0)));
        const long long shiftY =
            EvenOffset(
                static_cast<long long>(
                    std::llround(
                        translationY *
                        static_cast<double>(maxY) /
                        2.0)));

        long long sourceX =
            static_cast<long long>(base.x) +
            static_cast<long long>(maxX / 2) -
            shiftX;
        long long sourceY =
            static_cast<long long>(base.y) +
            static_cast<long long>(maxY / 2) -
            shiftY;
        const long long maxSourceX =
            static_cast<long long>(
                base.x + maxX);
        const long long maxSourceY =
            static_cast<long long>(
                base.y + maxY);

        sourceX = std::max<long long>(
            static_cast<long long>(base.x),
            std::min(maxSourceX, sourceX));
        sourceY = std::max<long long>(
            static_cast<long long>(base.y),
            std::min(maxSourceY, sourceY));

        result.source = {
            static_cast<std::size_t>(
                sourceX) &
                ~std::size_t{1},
            static_cast<std::size_t>(
                sourceY) &
                ~std::size_t{1},
            cropWidth,
            cropHeight,
        };
    } else if (scale < 1.0 - tolerance) {
        const std::size_t outputWidth =
            EvenExtent(
                static_cast<double>(
                    destinationWidth) *
                    scale,
                destinationWidth);
        const std::size_t outputHeight =
            EvenExtent(
                static_cast<double>(
                    destinationHeight) *
                    scale,
                destinationHeight);
        const std::size_t maxX =
            destinationWidth -
            outputWidth;
        const std::size_t maxY =
            destinationHeight -
            outputHeight;

        long long destinationX =
            static_cast<long long>(
                maxX / 2) +
            EvenOffset(
                static_cast<long long>(
                    std::llround(
                        translationX *
                        static_cast<double>(maxX) /
                        2.0)));
        long long destinationY =
            static_cast<long long>(
                maxY / 2) +
            EvenOffset(
                static_cast<long long>(
                    std::llround(
                        translationY *
                        static_cast<double>(maxY) /
                        2.0)));

        destinationX = std::max<long long>(
            0,
            std::min<long long>(
                static_cast<long long>(
                    maxX),
                destinationX));
        destinationY = std::max<long long>(
            0,
            std::min<long long>(
                static_cast<long long>(
                    maxY),
                destinationY));

        result.destination = {
            static_cast<std::size_t>(
                destinationX) &
                ~std::size_t{1},
            static_cast<std::size_t>(
                destinationY) &
                ~std::size_t{1},
            outputWidth,
            outputHeight,
        };
    } else if (
        std::fabs(translationX) >
            tolerance ||
        std::fabs(translationY) >
            tolerance) {
        const long long maxPanX =
            static_cast<long long>(
                (destinationWidth / 4) &
                ~std::size_t{1});
        const long long maxPanY =
            static_cast<long long>(
                (destinationHeight / 4) &
                ~std::size_t{1});
        const long long dx =
            EvenOffset(
                static_cast<long long>(
                    std::llround(
                        translationX *
                        static_cast<double>(
                            maxPanX))));
        const long long dy =
            EvenOffset(
                static_cast<long long>(
                    std::llround(
                        translationY *
                        static_cast<double>(
                            maxPanY))));
        const std::size_t absX =
            static_cast<std::size_t>(
                dx < 0 ? -dx : dx);
        const std::size_t absY =
            static_cast<std::size_t>(
                dy < 0 ? -dy : dy);
        const std::size_t visibleWidth =
            destinationWidth -
            absX;
        const std::size_t visibleHeight =
            destinationHeight -
            absY;

        if (visibleWidth < 2 ||
            visibleHeight < 2) {
            return false;
        }

        // Pan after the base aspect-fit transform. Convert destination-space
        // visibility back to the equivalent region inside the source crop.
        const double xScale =
            static_cast<double>(
                base.width) /
            static_cast<double>(
                destinationWidth);
        const double yScale =
            static_cast<double>(
                base.height) /
            static_cast<double>(
                destinationHeight);

        const std::size_t sourceOffsetX =
            EvenExtent(
                static_cast<double>(absX) *
                    xScale,
                base.width);
        const std::size_t sourceOffsetY =
            EvenExtent(
                static_cast<double>(absY) *
                    yScale,
                base.height);

        const std::size_t sourceVisibleWidth =
            EvenExtent(
                static_cast<double>(
                    visibleWidth) *
                    xScale,
                base.width);
        const std::size_t sourceVisibleHeight =
            EvenExtent(
                static_cast<double>(
                    visibleHeight) *
                    yScale,
                base.height);

        result.source = {
            base.x +
                (dx < 0
                     ? sourceOffsetX
                     : 0),
            base.y +
                (dy < 0
                     ? sourceOffsetY
                     : 0),
            sourceVisibleWidth,
            sourceVisibleHeight,
        };
        result.destination = {
            dx > 0 ? absX : 0,
            dy > 0 ? absY : 0,
            visibleWidth &
                ~std::size_t{1},
            visibleHeight &
                ~std::size_t{1},
        };
    }

    return
        result.source.width >= 2 &&
        result.source.height >= 2 &&
        result.destination.width >= 2 &&
        result.destination.height >= 2;
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

bool CameraConsumerAdapter::bindDirectPhotoSource(
    CVPixelBufferRef source,
    std::uint64_t mediaGeneration,
    std::uint64_t timelineEpoch,
    std::uint64_t transformRevision,
    double translationX,
    double translationY,
    double scale) {
    if (source == nullptr ||
        mediaGeneration == 0 ||
        timelineEpoch == 0 ||
        !CVPixelBufferIsPlanar(source) ||
        CVPixelBufferGetPlaneCount(source) != 2 ||
        !SupportsInPlaceBlackOwnership(source)) {
        return false;
    }

    std::lock_guard<std::mutex> lock(mutex_);

    const bool unchanged =
        directPhotoSource_ == source &&
        directPhotoGeneration_ ==
            mediaGeneration &&
        directPhotoEpoch_ ==
            timelineEpoch &&
        directPhotoRevision_ ==
            transformRevision &&
        directPhotoTranslationX_ ==
            translationX &&
        directPhotoTranslationY_ ==
            translationY &&
        directPhotoScale_ ==
            scale;

    if (unchanged) {
        return true;
    }

    if (directPhotoSource_ != source) {
        CVPixelBufferRetain(source);
        if (directPhotoSource_ != nullptr) {
            CVPixelBufferRelease(
                directPhotoSource_);
        }
        directPhotoSource_ = source;
    }

    directPhotoGeneration_ =
        mediaGeneration;
    directPhotoEpoch_ =
        timelineEpoch;
    directPhotoRevision_ =
        transformRevision;
    directPhotoTranslationX_ =
        std::clamp(
            translationX,
            -1.0,
            1.0);
    directPhotoTranslationY_ =
        std::clamp(
            translationY,
            -1.0,
            1.0);
    directPhotoScale_ =
        std::clamp(
            (!std::isfinite(scale) ||
             scale <= 0.0)
                ? 1.0
                : scale,
            0.25,
            4.0);

    for (auto& plan : directPhotoPlans_) {
        plan = {};
    }
    directPhotoPlanSerial_ = 0;
    directPhotoRenderCount_ = 0;
    directPhotoRenderFailureCount_ = 0;
    return true;
}

bool CameraConsumerAdapter::
prepareDirectPhotoGeometry(
    std::size_t width,
    std::size_t height,
    OSType pixelFormat,
    std::uint64_t mediaGeneration,
    std::uint64_t timelineEpoch,
    std::uint64_t transformRevision) {
    if (width == 0 ||
        height == 0 ||
        pixelFormat == 0) {
        return false;
    }

    std::lock_guard<std::mutex> lock(mutex_);

    if (directPhotoSource_ == nullptr ||
        directPhotoGeneration_ !=
            mediaGeneration ||
        directPhotoEpoch_ !=
            timelineEpoch ||
        directPhotoRevision_ !=
            transformRevision ||
        !SupportsInPlaceBlackOwnership(
            directPhotoSource_) ||
        (pixelFormat !=
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
         pixelFormat !=
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)) {
        return false;
    }

    DirectRegions regions;
    if (!ComputeDirectRegions(
            CVPixelBufferGetWidth(
                directPhotoSource_),
            CVPixelBufferGetHeight(
                directPhotoSource_),
            width,
            height,
            directPhotoTranslationX_,
            directPhotoTranslationY_,
            directPhotoScale_,
            &regions)) {
        return false;
    }

    if ((regions.source.x % 2) != 0 ||
        (regions.source.y % 2) != 0 ||
        (regions.source.width % 2) != 0 ||
        (regions.source.height % 2) != 0 ||
        (regions.destination.x % 2) != 0 ||
        (regions.destination.y % 2) != 0 ||
        (regions.destination.width % 2) != 0 ||
        (regions.destination.height % 2) != 0) {
        return false;
    }

    DirectPhotoPlan* plan =
        findDirectPhotoPlanLocked(
            width,
            height,
            pixelFormat,
            mediaGeneration,
            timelineEpoch,
            transformRevision);

    if (plan == nullptr) {
        for (auto& candidate :
             directPhotoPlans_) {
            if (!candidate.valid) {
                plan = &candidate;
                break;
            }
        }
    }

    if (plan == nullptr) {
        plan = &directPhotoPlans_[0];
        for (auto& candidate :
             directPhotoPlans_) {
            if (candidate.preparedSerial <
                plan->preparedSerial) {
                plan = &candidate;
            }
        }
    }

    const std::size_t yColumnCount =
        regions.destination.width;
    const std::size_t yRowCount =
        regions.destination.height;
    const std::size_t cbCrColumnCount =
        regions.destination.width / 2;
    const std::size_t cbCrRowCount =
        regions.destination.height / 2;

    if (yColumnCount >
            std::numeric_limits<std::size_t>::max() -
                yRowCount ||
        yColumnCount + yRowCount >
            std::numeric_limits<std::size_t>::max() -
                cbCrColumnCount ||
        yColumnCount + yRowCount +
                cbCrColumnCount >
            std::numeric_limits<std::size_t>::max() -
                cbCrRowCount) {
        return false;
    }

    const std::size_t mapEntryCount =
        yColumnCount +
        yRowCount +
        cbCrColumnCount +
        cbCrRowCount;
    if (mapEntryCount >
        kDirectRenderScratchByteBudget /
            sizeof(std::uint32_t)) {
        return false;
    }
    const std::size_t mappingBytes =
        mapEntryCount *
        sizeof(std::uint32_t);

    std::size_t retainedMapBytes = 0;
    for (const auto& candidate :
         directPhotoPlans_) {
        if (&candidate != plan &&
            candidate.valid) {
            if (retainedMapBytes >
                kDirectRenderScratchByteBudget -
                    candidate.mappingBytes) {
                return false;
            }
            retainedMapBytes +=
                candidate.mappingBytes;
        }
    }
    if (mappingBytes >
        kDirectRenderScratchByteBudget -
            retainedMapBytes) {
        return false;
    }

    // Replacing/refreshing a plan is producer-side. Drop its old vectors
    // before allocating the new immutable coordinate maps so transient memory
    // stays inside the declared mapping budget.
    *plan = {};

    try {
        plan->ySourceColumns.resize(
            yColumnCount);
        plan->ySourceRows.resize(
            yRowCount);
        plan->cbCrSourceByteColumns.resize(
            cbCrColumnCount);
        plan->cbCrSourceRows.resize(
            cbCrRowCount);
    } catch (const std::bad_alloc&) {
        *plan = {};
        return false;
    }

    const std::size_t sourceWidth =
        regions.source.width;
    const std::size_t sourceHeight =
        regions.source.height;
    const std::size_t sourceCbCrWidth =
        sourceWidth / 2;
    const std::size_t sourceCbCrHeight =
        sourceHeight / 2;

    for (std::size_t x = 0;
         x < yColumnCount;
         ++x) {
        const std::size_t relative =
            std::min(
                sourceWidth - 1,
                static_cast<std::size_t>(
                    (static_cast<std::uint64_t>(x) *
                     sourceWidth) /
                    yColumnCount));
        plan->ySourceColumns[x] =
            static_cast<std::uint32_t>(
                regions.source.x +
                relative);
    }

    for (std::size_t y = 0;
         y < yRowCount;
         ++y) {
        const std::size_t relative =
            std::min(
                sourceHeight - 1,
                static_cast<std::size_t>(
                    (static_cast<std::uint64_t>(y) *
                     sourceHeight) /
                    yRowCount));
        plan->ySourceRows[y] =
            static_cast<std::uint32_t>(
                regions.source.y +
                relative);
    }

    for (std::size_t x = 0;
         x < cbCrColumnCount;
         ++x) {
        const std::size_t relative =
            std::min(
                sourceCbCrWidth - 1,
                static_cast<std::size_t>(
                    (static_cast<std::uint64_t>(x) *
                     sourceCbCrWidth) /
                    cbCrColumnCount));
        plan->cbCrSourceByteColumns[x] =
            static_cast<std::uint32_t>(
                regions.source.x +
                relative * 2);
    }

    for (std::size_t y = 0;
         y < cbCrRowCount;
         ++y) {
        const std::size_t relative =
            std::min(
                sourceCbCrHeight - 1,
                static_cast<std::size_t>(
                    (static_cast<std::uint64_t>(y) *
                     sourceCbCrHeight) /
                    cbCrRowCount));
        plan->cbCrSourceRows[y] =
            static_cast<std::uint32_t>(
                regions.source.y / 2 +
                relative);
    }

    const OSType sourceFormat =
        CVPixelBufferGetPixelFormatType(
            directPhotoSource_);
    for (std::size_t value = 0;
         value < 256;
         ++value) {
        std::uint8_t yValue =
            static_cast<std::uint8_t>(value);
        std::uint8_t cbCrValue =
            static_cast<std::uint8_t>(value);

        if (sourceFormat !=
            pixelFormat) {
            if (sourceFormat ==
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
                yValue =
                    static_cast<std::uint8_t>(
                        16U +
                        (value * 219U +
                         127U) /
                            255U);
                cbCrValue =
                    static_cast<std::uint8_t>(
                        16U +
                        (value * 224U +
                         127U) /
                            255U);
            } else {
                const unsigned yClamped =
                    std::min(
                        235U,
                        std::max(
                            16U,
                            static_cast<unsigned>(
                                value)));
                const unsigned cbCrClamped =
                    std::min(
                        240U,
                        std::max(
                            16U,
                            static_cast<unsigned>(
                                value)));
                yValue =
                    static_cast<std::uint8_t>(
                        ((yClamped - 16U) *
                             255U +
                         109U) /
                        219U);
                cbCrValue =
                    static_cast<std::uint8_t>(
                        ((cbCrClamped - 16U) *
                             255U +
                         112U) /
                        224U);
            }
        }

        plan->yValueMap[value] =
            yValue;
        plan->cbCrValueMap[value] =
            cbCrValue;
    }

    if (directPhotoPlanSerial_ ==
        UINT64_MAX) {
        std::uint64_t serial = 1;
        for (auto& candidate :
             directPhotoPlans_) {
            if (candidate.valid) {
                candidate.preparedSerial =
                    serial++;
            }
        }
        directPhotoPlanSerial_ = serial;
    } else {
        ++directPhotoPlanSerial_;
    }

    plan->valid = true;
    plan->mediaGeneration =
        mediaGeneration;
    plan->timelineEpoch =
        timelineEpoch;
    plan->transformRevision =
        transformRevision;
    plan->width = width;
    plan->height = height;
    plan->pixelFormat =
        pixelFormat;
    plan->sourceX =
        regions.source.x;
    plan->sourceY =
        regions.source.y;
    plan->sourceWidth =
        regions.source.width;
    plan->sourceHeight =
        regions.source.height;
    plan->destinationX =
        regions.destination.x;
    plan->destinationY =
        regions.destination.y;
    plan->destinationWidth =
        regions.destination.width;
    plan->destinationHeight =
        regions.destination.height;
    plan->mappingBytes =
        mappingBytes;
    plan->preparedSerial =
        directPhotoPlanSerial_;
    return true;
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
                decision.pixelBufferLease.
                    retain(
                        decision.pixelBuffer);
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
                        if (selected == nullptr) {
                            mediaFailure =
                                CameraFailOpenReason::
                                    InvalidLease;
                        }
                    } else {
                        pin(
                            std::move(
                                *acquired.lease));
                    }

                    if (selected != nullptr) {
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
                        if (reusableStaticMedia_) {
                            decision.pixelBufferLease.
                                retain(
                                    decision.pixelBuffer);
                        }
                        return decision;
                    }
                }
            }
        }
    }

    if (lock.owns_lock() &&
        reusableStaticMedia_ &&
        renderDirectPhotoIntoOriginalLocked(
            original)) {
        virtualDecisionCount_.
            fetch_add(
                1,
                std::memory_order_relaxed);
        mediaVirtualDecisionCount_.
            fetch_add(
                1,
                std::memory_order_relaxed);

        CameraDecision direct;
        direct.kind =
            CameraDecisionKind::Virtual;
        direct.source =
            CameraDecisionSource::
                DirectRenderedPhoto;
        direct.reason =
            CameraFailOpenReason::None;
        direct.mediaFailureReason =
            mediaFailure;
        direct.pixelBuffer =
            original;
        return direct;
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

std::uint64_t
CameraConsumerAdapter::
directPhotoRenderCount() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return directPhotoRenderCount_;
}

std::uint64_t
CameraConsumerAdapter::
directPhotoRenderFailureCount() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return directPhotoRenderFailureCount_;
}

std::size_t
CameraConsumerAdapter::
directPhotoScratchBytes() const {
    std::lock_guard<std::mutex> lock(mutex_);

    std::size_t total = 0;
    for (const auto& plan :
         directPhotoPlans_) {
        if (!plan.valid) {
            continue;
        }
        if (total >
            kDirectRenderScratchByteBudget -
                plan.mappingBytes) {
            return
                kDirectRenderScratchByteBudget;
        }
        total += plan.mappingBytes;
    }
    return total;
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
    clearDirectPhotoSourceLocked();
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

CameraConsumerAdapter::PhotoWorkingSetEntry*
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

void CameraConsumerAdapter::
clearDirectPhotoSourceLocked() noexcept {
    if (directPhotoSource_ != nullptr) {
        CVPixelBufferRelease(
            directPhotoSource_);
        directPhotoSource_ = nullptr;
    }

    directPhotoGeneration_ = 0;
    directPhotoEpoch_ = 0;
    directPhotoRevision_ = 0;
    directPhotoTranslationX_ = 0.0;
    directPhotoTranslationY_ = 0.0;
    directPhotoScale_ = 1.0;
    for (auto& plan : directPhotoPlans_) {
        plan = {};
    }
    directPhotoPlanSerial_ = 0;
    directPhotoRenderCount_ = 0;
    directPhotoRenderFailureCount_ = 0;
}

CameraConsumerAdapter::DirectPhotoPlan*
CameraConsumerAdapter::
findDirectPhotoPlanLocked(
    std::size_t width,
    std::size_t height,
    OSType pixelFormat,
    std::uint64_t mediaGeneration,
    std::uint64_t timelineEpoch,
    std::uint64_t transformRevision) noexcept {
    for (auto& plan : directPhotoPlans_) {
        if (plan.valid &&
            plan.mediaGeneration ==
                mediaGeneration &&
            plan.timelineEpoch ==
                timelineEpoch &&
            plan.transformRevision ==
                transformRevision &&
            plan.width == width &&
            plan.height == height &&
            plan.pixelFormat ==
                pixelFormat) {
            return &plan;
        }
    }
    return nullptr;
}

bool CameraConsumerAdapter::
renderDirectPhotoIntoOriginalLocked(
    CVPixelBufferRef original) noexcept {
    if (original == nullptr ||
        directPhotoSource_ == nullptr ||
        context_.currentMediaGeneration !=
            directPhotoGeneration_ ||
        context_.currentTimelineEpoch !=
            directPhotoEpoch_ ||
        reusableStaticRevision_ !=
            directPhotoRevision_ ||
        !SupportsInPlaceBlackOwnership(
            original) ||
        !SupportsInPlaceBlackOwnership(
            directPhotoSource_)) {
        return false;
    }

    DirectPhotoPlan* plan =
        findDirectPhotoPlanLocked(
            CVPixelBufferGetWidth(
                original),
            CVPixelBufferGetHeight(
                original),
            CVPixelBufferGetPixelFormatType(
                original),
            directPhotoGeneration_,
            directPhotoEpoch_,
            directPhotoRevision_);

    if (plan == nullptr ||
        !plan->valid ||
        plan->ySourceColumns.size() !=
            plan->destinationWidth ||
        plan->ySourceRows.size() !=
            plan->destinationHeight ||
        plan->cbCrSourceByteColumns.size() !=
            plan->destinationWidth / 2 ||
        plan->cbCrSourceRows.size() !=
            plan->destinationHeight / 2) {
        return false;
    }

    if (CVPixelBufferLockBaseAddress(
            directPhotoSource_,
            kCVPixelBufferLock_ReadOnly) !=
        kCVReturnSuccess) {
        ++directPhotoRenderFailureCount_;
        return false;
    }

    if (CVPixelBufferLockBaseAddress(
            original,
            0) != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(
            directPhotoSource_,
            kCVPixelBufferLock_ReadOnly);
        ++directPhotoRenderFailureCount_;
        return false;
    }

    bool success = true;

    const OSType destinationFormat =
        CVPixelBufferGetPixelFormatType(
            original);
    const std::uint8_t blackY =
        destinationFormat ==
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ? 16
            : 0;

    for (std::size_t plane = 0;
         plane < 2;
         ++plane) {
        auto* base =
            static_cast<std::uint8_t*>(
                CVPixelBufferGetBaseAddressOfPlane(
                    original,
                    plane));
        const std::size_t stride =
            CVPixelBufferGetBytesPerRowOfPlane(
                original,
                plane);
        const std::size_t rows =
            CVPixelBufferGetHeightOfPlane(
                original,
                plane);
        if (base == nullptr ||
            stride == 0 ||
            rows == 0) {
            success = false;
            break;
        }
        std::memset(
            base,
            plane == 0 ? blackY : 128,
            stride * rows);
    }

    const auto* sourceYBase =
        static_cast<const std::uint8_t*>(
            CVPixelBufferGetBaseAddressOfPlane(
                directPhotoSource_,
                0));
    const auto* sourceCbCrBase =
        static_cast<const std::uint8_t*>(
            CVPixelBufferGetBaseAddressOfPlane(
                directPhotoSource_,
                1));
    auto* destinationYBase =
        static_cast<std::uint8_t*>(
            CVPixelBufferGetBaseAddressOfPlane(
                original,
                0));
    auto* destinationCbCrBase =
        static_cast<std::uint8_t*>(
            CVPixelBufferGetBaseAddressOfPlane(
                original,
                1));

    if (success &&
        (sourceYBase == nullptr ||
         sourceCbCrBase == nullptr ||
         destinationYBase == nullptr ||
         destinationCbCrBase == nullptr)) {
        success = false;
    }

    if (success) {
        const std::size_t sourceYStride =
            CVPixelBufferGetBytesPerRowOfPlane(
                directPhotoSource_,
                0);
        const std::size_t sourceCbCrStride =
            CVPixelBufferGetBytesPerRowOfPlane(
                directPhotoSource_,
                1);
        const std::size_t destinationYStride =
            CVPixelBufferGetBytesPerRowOfPlane(
                original,
                0);
        const std::size_t destinationCbCrStride =
            CVPixelBufferGetBytesPerRowOfPlane(
                original,
                1);

        const std::size_t sourceYRows =
            CVPixelBufferGetHeightOfPlane(
                directPhotoSource_,
                0);
        const std::size_t sourceYColumns =
            CVPixelBufferGetWidthOfPlane(
                directPhotoSource_,
                0);
        const std::size_t sourceCbCrRows =
            CVPixelBufferGetHeightOfPlane(
                directPhotoSource_,
                1);
        const std::size_t sourceCbCrBytes =
            CVPixelBufferGetWidthOfPlane(
                directPhotoSource_,
                1) * 2;

#if defined(VCAM_TESTING)
        if (!plan->ySourceRows.empty() &&
            !plan->ySourceColumns.empty()) {
            const std::size_t debugRow =
                plan->ySourceRows[0];
            const std::size_t debugColumn =
                plan->ySourceColumns[0];
            const auto* debugSource =
                sourceYBase +
                debugRow *
                    sourceYStride;
            std::fprintf(
                stderr,
                "DIRECT_PLAN_DEBUG row=%zu col=%zu source=%u mapped=%u destHeight=%zu destWidth=%zu sourceRows=%zu sourceCols=%zu\n",
                debugRow,
                debugColumn,
                static_cast<unsigned>(
                    debugSource[debugColumn]),
                static_cast<unsigned>(
                    plan->yValueMap[
                        debugSource[
                            debugColumn]]),
                plan->destinationHeight,
                plan->destinationWidth,
                plan->ySourceRows.size(),
                plan->ySourceColumns.size());
        }
#endif

        for (std::size_t y = 0;
             y < plan->destinationHeight &&
             success;
             ++y) {
            const std::size_t sourceRowIndex =
                plan->ySourceRows[y];
            if (sourceRowIndex >=
                sourceYRows) {
                success = false;
                break;
            }

            const auto* sourceRow =
                sourceYBase +
                sourceRowIndex *
                    sourceYStride;
            auto* destinationRow =
                destinationYBase +
                (plan->destinationY + y) *
                    destinationYStride +
                plan->destinationX;

            for (std::size_t x = 0;
                 x < plan->destinationWidth;
                 ++x) {
                const std::size_t sourceX =
                    plan->ySourceColumns[x];
                if (sourceX >=
                    sourceYColumns) {
                    success = false;
                    break;
                }
                destinationRow[x] =
                    plan->yValueMap[
                        sourceRow[sourceX]];
            }
        }

#if defined(VCAM_TESTING)
        if (plan->destinationHeight != 0 &&
            plan->destinationWidth != 0) {
            std::fprintf(
                stderr,
                "DIRECT_PLAN_DEST_AFTER=%u\n",
                static_cast<unsigned>(
                    destinationYBase[
                        plan->destinationY *
                            destinationYStride +
                        plan->destinationX]));
        }
#endif

        for (std::size_t y = 0;
             y < plan->destinationHeight / 2 &&
             success;
             ++y) {
            const std::size_t sourceRowIndex =
                plan->cbCrSourceRows[y];
            if (sourceRowIndex >=
                sourceCbCrRows) {
                success = false;
                break;
            }

            const auto* sourceRow =
                sourceCbCrBase +
                sourceRowIndex *
                    sourceCbCrStride;
            auto* destinationRow =
                destinationCbCrBase +
                (plan->destinationY / 2 + y) *
                    destinationCbCrStride +
                plan->destinationX;

            for (std::size_t x = 0;
                 x <
                     plan->destinationWidth / 2;
                 ++x) {
                const std::size_t sourceByte =
                    plan->
                        cbCrSourceByteColumns[x];
                if (sourceByte + 1 >=
                    sourceCbCrBytes) {
                    success = false;
                    break;
                }
                destinationRow[x * 2] =
                    plan->cbCrValueMap[
                        sourceRow[
                            sourceByte]];
                destinationRow[x * 2 + 1] =
                    plan->cbCrValueMap[
                        sourceRow[
                            sourceByte + 1]];
            }
        }
    }

    CVPixelBufferUnlockBaseAddress(
        original,
        0);
    CVPixelBufferUnlockBaseAddress(
        directPhotoSource_,
        kCVPixelBufferLock_ReadOnly);

    if (!success) {
        ++directPhotoRenderFailureCount_;
        return false;
    }

    CVBufferSetAttachment(
        original,
        kCVImageBufferColorPrimariesKey,
        kCVImageBufferColorPrimaries_ITU_R_709_2,
        kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(
        original,
        kCVImageBufferTransferFunctionKey,
        kCVImageBufferTransferFunction_ITU_R_709_2,
        kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(
        original,
        kCVImageBufferYCbCrMatrixKey,
        kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(
        original,
        CFSTR("vcam_patched"),
        kCFBooleanTrue,
        kCVAttachmentMode_ShouldPropagate);

    ++directPhotoRenderCount_;
    return true;
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
