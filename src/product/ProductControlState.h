#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <string>

namespace vcam::product {

enum class ProductMediaKind : std::uint8_t {
    None = 0,
    Photo,
    Video,
};

enum class ProductPlaybackIntent : std::uint8_t {
    Stopped = 0,
    Playing,
    Paused,
};

inline constexpr double kProductPhotoTransformMaxTranslation = 1.0;
inline constexpr double kProductPhotoTransformMinScale = 0.25;
inline constexpr double kProductPhotoTransformMaxScale = 4.0;

struct ProductPhotoTransform {
    double translationX = 0.0;
    double translationY = 0.0;
    double scale = 1.0;
    std::uint64_t revision = 0;
};

inline ProductPhotoTransform NormalizeProductPhotoTransform(
    ProductPhotoTransform transform) noexcept {
    if (!std::isfinite(transform.translationX)) {
        transform.translationX = 0.0;
    }
    if (!std::isfinite(transform.translationY)) {
        transform.translationY = 0.0;
    }
    if (!std::isfinite(transform.scale) ||
        transform.scale <= 0.0) {
        transform.scale = 1.0;
    }

    transform.translationX = std::clamp(
        transform.translationX,
        -kProductPhotoTransformMaxTranslation,
        kProductPhotoTransformMaxTranslation);
    transform.translationY = std::clamp(
        transform.translationY,
        -kProductPhotoTransformMaxTranslation,
        kProductPhotoTransformMaxTranslation);
    transform.scale = std::clamp(
        transform.scale,
        kProductPhotoTransformMinScale,
        kProductPhotoTransformMaxScale);
    return transform;
}

struct ProductControlSnapshot {
    bool enabled = false;
    ProductMediaKind mediaKind = ProductMediaKind::None;
    std::string mediaPath;
    std::uint64_t selectionGeneration = 0;
    bool loopEnabled = false;
    ProductPlaybackIntent playbackIntent =
        ProductPlaybackIntent::Stopped;
    ProductPhotoTransform photoTransform{};

    bool hasMedia() const noexcept {
        return mediaKind != ProductMediaKind::None &&
               !mediaPath.empty() &&
               selectionGeneration != 0;
    }
};

}  // namespace vcam::product
