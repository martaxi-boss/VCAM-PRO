#pragma once

#include "Gate1ProofRunner.h"

#include <memory>

namespace vcam::gate1 {

class IOSGate1Platform final : public Platform {
public:
    IOSGate1Platform();
    ~IOSGate1Platform() override;

    IOSGate1Platform(const IOSGate1Platform&) = delete;
    IOSGate1Platform& operator=(const IOSGate1Platform&) = delete;

    std::uint64_t nowMonotonicNs() override;
    void waitForNs(std::uint64_t durationNs) override;

    DeviceInfo deviceInfo() override;
    PackageProbe queryLoadProbe() override;

    bool armMarkerCapture(
        std::uint64_t proofStartNs,
        std::string* backend,
        std::string* error) override;

    ProcessSnapshot discoverMediaserverd() override;

    bool requestSingleRestart(
        int pid,
        std::string* action,
        std::string* error) override;

    MarkerObservation pollMarker(
        std::uint64_t proofStartNs) override;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace vcam::gate1
