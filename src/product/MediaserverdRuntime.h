#pragma once

#include "CameraConsumerAdapter.h"

#include <CoreVideo/CoreVideo.h>

#include <cstdint>
#include <memory>

namespace vcam::product {

class MediaserverdRuntime final {
public:
    MediaserverdRuntime();
    ~MediaserverdRuntime();

    MediaserverdRuntime(
        const MediaserverdRuntime&) = delete;
    MediaserverdRuntime& operator=(
        const MediaserverdRuntime&) = delete;

    static MediaserverdRuntime& shared();

    bool start();

    void observeRealCameraBuffer(
        CVPixelBufferRef buffer) noexcept;

    CameraDecision decideCameraBuffer(
        CVPixelBufferRef original) noexcept;

    CameraConsumerAdapter&
    cameraAdapter() noexcept;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace vcam::product
