#pragma once

#include "ProductControlState.h"

#include <dispatch/dispatch.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>

namespace vcam::product {

enum class SharedControlLoadProvenance : std::uint8_t {
    Absent = 0,
    Valid,
    InvalidOrUnreadable,
};

class SharedControlStore final {
public:
    using ChangeCallback =
        std::function<void(
            const ProductControlSnapshot&)>;

    static constexpr const char*
        kDefaultControlPath =
        "/var/jb/var/mobile/Library/Preferences/com.vcampro.control.plist";
    static constexpr const char*
        kDefaultNotification =
        "com.vcampro.controlChanged";

    SharedControlStore(
        std::string controlPath =
            kDefaultControlPath,
        std::string notificationName =
            kDefaultNotification);

    ~SharedControlStore();

    SharedControlStore(
        const SharedControlStore&) = delete;
    SharedControlStore& operator=(
        const SharedControlStore&) = delete;

    bool load(
        ProductControlSnapshot* snapshot) const;

    SharedControlLoadProvenance
    loadWithProvenance(
        ProductControlSnapshot* snapshot) const;

    bool save(
        const ProductControlSnapshot& snapshot,
        bool postChangeNotification = true);

    bool startObserving(
        ChangeCallback callback);
    void stopObserving();

    const std::string&
    controlPath() const noexcept;
    const std::string&
    notificationName() const noexcept;

    std::uint64_t
    diskReadCount() const noexcept;
    std::uint64_t
    diskWriteCount() const noexcept;

private:
    void handleDarwinChange();

    std::string controlPath_;
    std::string notificationName_;
    dispatch_queue_t notificationQueue_ = nullptr;
    int notifyToken_ = 0;

    mutable std::atomic<std::uint64_t>
        diskReadCount_{0};
    std::atomic<std::uint64_t>
        diskWriteCount_{0};

    mutable std::mutex callbackMutex_;
    ChangeCallback callback_;
    bool observing_ = false;
};

}  // namespace vcam::product
