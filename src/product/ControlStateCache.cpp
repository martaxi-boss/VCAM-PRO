#include "ControlStateCache.h"

namespace vcam::product {

void ControlStateCache::replace(
    const ProductControlSnapshot& snapshot) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        snapshot_ = snapshot;
    }

    enabled_.store(
        snapshot.enabled,
        std::memory_order_release);
    refreshCount_.fetch_add(
        1,
        std::memory_order_acq_rel);
}

bool ControlStateCache::enabledFast() const noexcept {
    return enabled_.load(
        std::memory_order_acquire);
}

ProductControlSnapshot
ControlStateCache::snapshot() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return snapshot_;
}

std::uint64_t
ControlStateCache::refreshCount() const noexcept {
    return refreshCount_.load(
        std::memory_order_acquire);
}

}  // namespace vcam::product
