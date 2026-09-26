#pragma once

#include "ProductControlState.h"

#include <cstdint>
#include <string>

#if defined(VCAM_TESTING)
#include <functional>
#endif

namespace vcam::product {

#if defined(VCAM_TESTING)
enum class SharedMediaStagerTestPoint : std::uint8_t {
    BeforeDestinationCreate = 0,
    BeforePublish,
    BeforeDelete,
    BeforeReconcileDelete,
};

using SharedMediaStagerTestHook =
    std::function<void(
        SharedMediaStagerTestPoint)>;

void SetSharedMediaStagerTestHook(
    SharedMediaStagerTestHook hook);
#endif

class SharedMediaStager final {
public:
    static constexpr const char*
        kDefaultMediaDirectory =
        "/var/jb/var/mobile/Library/VCAMPro/Media";

    explicit SharedMediaStager(
        std::string mediaDirectory =
            kDefaultMediaDirectory);

    bool stageAndValidate(
        const std::string& temporarySourcePath,
        ProductMediaKind kind,
        std::uint64_t generation,
        std::string* stagedPath,
        std::string* errorMessage);

    bool removeOwnedPath(
        const std::string& path) const;

    bool isExistingOwnedMediaPath(
        const std::string& path) const;

    bool reconcileOwnedMedia(
        const std::string& activeOwnedPath,
        std::string* errorMessage) const;

    const std::string&
    mediaDirectory() const noexcept;

private:
    bool validate(
        const std::string& path,
        ProductMediaKind kind,
        std::string* errorMessage) const;

    bool isOwnedPath(
        const std::string& path) const;

    std::string mediaDirectory_;
};

}  // namespace vcam::product
