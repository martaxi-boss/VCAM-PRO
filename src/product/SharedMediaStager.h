#pragma once

#include "ProductControlState.h"

#include <cstdint>
#include <string>

namespace vcam::product {

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

    const std::string&
    mediaDirectory() const noexcept;

private:
    bool validate(
        const std::string& path,
        ProductMediaKind kind,
        std::string* errorMessage) const;

    bool isOwnedPath(
        const std::string& path) const noexcept;

    std::string mediaDirectory_;
};

}  // namespace vcam::product
