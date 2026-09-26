#pragma once

#include "ReadyFrameQueue.h"

#include <CoreVideo/CoreVideo.h>

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>

namespace vcam::controlled {

struct ControlledFrameLifetimeTracker;

enum class ControlledAcquireKind : std::uint8_t {
    Presented = 0,
    Disabled,
    Unbound,
    Inactive,
    Empty,
    NoEligibleFrame,
    Contended,
    LeaseBusy,
};

class ControlledPresentedFrame final {
public:
    ControlledPresentedFrame(
        ControlledPresentedFrame&& other) noexcept;
    ControlledPresentedFrame& operator=(
        ControlledPresentedFrame&& other) noexcept;

    ControlledPresentedFrame(
        const ControlledPresentedFrame&) = delete;
    ControlledPresentedFrame& operator=(
        const ControlledPresentedFrame&) = delete;

    ~ControlledPresentedFrame();

    bool valid() const noexcept;
    CVPixelBufferRef pixelBuffer() const noexcept;
    const frame_engine::FrameIdentity&
    identity() const noexcept;

private:
    friend class ControlledFrameConsumer;

    ControlledPresentedFrame(
        CVPixelBufferRef pixelBuffer,
        const frame_engine::FrameIdentity& identity,
        std::shared_ptr<
            ControlledFrameLifetimeTracker> tracker);

    void release() noexcept;

    CVPixelBufferRef pixelBuffer_ = nullptr;
    frame_engine::FrameIdentity identity_{};
    std::shared_ptr<
        ControlledFrameLifetimeTracker> tracker_;
};

struct ControlledAcquireResult {
    ControlledAcquireKind kind =
        ControlledAcquireKind::Unbound;
    std::optional<ControlledPresentedFrame> frame;
};

class ControlledFrameConsumer final {
public:
    ControlledFrameConsumer();

    ControlledFrameConsumer(
        const ControlledFrameConsumer&) = delete;
    ControlledFrameConsumer& operator=(
        const ControlledFrameConsumer&) = delete;

    void bind(
        frame_engine::ReadyFrameQueue* queue,
        std::uint64_t mediaGeneration,
        std::uint64_t timelineEpoch) noexcept;
    void unbind() noexcept;

    void setEnabled(bool enabled) noexcept;
    bool enabled() const noexcept;

    void setPresentationActive(bool active) noexcept;
    bool presentationActive() const noexcept;

    ControlledAcquireResult tryAcquire() noexcept;

    std::size_t outstandingFrameCount() const noexcept;

private:
    frame_engine::ReadyFrameQueue* queue_ = nullptr;

    std::uint64_t contextGeneration_ = 0;
    std::uint64_t contextEpoch_ = 0;
    std::uint64_t lastGeneration_ = 0;
    std::uint64_t lastEpoch_ = 0;
    std::optional<std::uint64_t> lastSequence_;

    std::shared_ptr<
        ControlledFrameLifetimeTracker> tracker_;

    std::atomic<bool> enabled_{false};
    std::atomic<bool> presentationActive_{false};
};

}  // namespace vcam::controlled
