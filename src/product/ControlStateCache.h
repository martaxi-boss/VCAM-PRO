#pragma once

#include "ProductControlState.h"

#include <atomic>
#include <cstdint>
#include <mutex>

namespace vcam::product {

class ControlStateCache final {
public:
    ControlStateCache() = default;

    void replace(const ProductControlSnapshot& snapshot);

    bool enabledFast() const noexcept;
    ProductControlSnapshot snapshot() const;
    std::uint64_t refreshCount() const noexcept;

private:
    std::atomic<bool> enabled_{false};
    std::atomic<std::uint64_t> refreshCount_{0};

    mutable std::mutex mutex_;
    ProductControlSnapshot snapshot_{};
};

}  // namespace vcam::product
