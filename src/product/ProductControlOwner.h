#pragma once

#include "ProductControlState.h"
#include "SharedControlStore.h"
#include "SharedMediaStager.h"

#include <functional>
#include <mutex>
#include <string>

namespace vcam::product {

class ProductControlOwner final {
public:
    using CommitAction =
        std::function<bool()>;
    using CommitGate =
        std::function<bool(
            const CommitAction&)>;

    ProductControlOwner(
        std::string controlPath =
            SharedControlStore::
                kDefaultControlPath,
        std::string notificationName =
            SharedControlStore::
                kDefaultNotification,
        std::string mediaDirectory =
            SharedMediaStager::
                kDefaultMediaDirectory);

    bool reload();

    ProductControlSnapshot
    snapshot() const;

    bool setEnabled(bool enabled);

    bool selectFromTemporaryPath(
        const std::string& temporarySourcePath,
        ProductMediaKind kind,
        std::string* errorMessage);

    bool selectFromTemporaryPath(
        const std::string& temporarySourcePath,
        ProductMediaKind kind,
        const CommitGate& commitGate,
        std::string* errorMessage);

    bool clearMedia();

    bool setLoopEnabled(bool enabled);

    bool setPlaybackIntent(
        ProductPlaybackIntent intent);

    const std::string&
    lastStatus() const noexcept;

    const std::string&
    mediaDirectory() const noexcept;

private:
    bool commit(
        const ProductControlSnapshot& next,
        const std::string& oldPath,
        const std::string& newPathOnFailure);

    static std::uint64_t
    nextGeneration(
        std::uint64_t current) noexcept;

    mutable std::mutex mutex_;
    SharedControlStore store_;
    SharedMediaStager stager_;
    ProductControlSnapshot current_{};
    std::string lastStatus_ =
        "VCAM control ready.";
};

}  // namespace vcam::product
