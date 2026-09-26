#pragma once

#include "ControlledFrameConsumer.h"
#include "ProductControlState.h"
#include "SharedControlStore.h"

#include <atomic>
#include <cstdint>
#include <memory>

namespace vcam::media_engine {
class InternalGalleryMediaSession;
}

namespace vcam::controlled {

class ControlledRuntime final {
public:
    ControlledRuntime();
    ~ControlledRuntime();

    ControlledRuntime(
        const ControlledRuntime&) = delete;
    ControlledRuntime& operator=(
        const ControlledRuntime&) = delete;

    bool start();
    void stop();

    ControlledFrameConsumer&
    consumer() noexcept;

    std::uint64_t
    presentationSerial() const noexcept;

    product::ProductControlSnapshot
    appliedSnapshot() const;

private:
    void applySnapshot(
        const product::ProductControlSnapshot& snapshot);

    void applyMutableControls(
        const product::ProductControlSnapshot& snapshot);

    void bindCurrentSession();
    void bumpPresentationSerial() noexcept;

    product::SharedControlStore store_;

    std::unique_ptr<
        media_engine::InternalGalleryMediaSession>
        session_;

    ControlledFrameConsumer consumer_;
    product::ProductControlSnapshot applied_{};

    std::atomic<std::uint64_t>
        presentationSerial_{1};

    bool started_ = false;
};

}  // namespace vcam::controlled
