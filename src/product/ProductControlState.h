#pragma once

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

struct ProductControlSnapshot {
    bool enabled = false;
    ProductMediaKind mediaKind = ProductMediaKind::None;
    std::string mediaPath;
    std::uint64_t selectionGeneration = 0;
    bool loopEnabled = false;
    ProductPlaybackIntent playbackIntent =
        ProductPlaybackIntent::Stopped;

    bool hasMedia() const noexcept {
        return mediaKind != ProductMediaKind::None &&
               !mediaPath.empty() &&
               selectionGeneration != 0;
    }
};

}  // namespace vcam::product
