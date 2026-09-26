#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace vcam::gate1 {

enum class FinalResult : std::uint8_t {
    NotProven = 0,
    Pass,
    FailLoadUnstable,
};

enum class ProofState : std::uint8_t {
    Idle = 0,
    CheckingPrerequisites,
    ArmingMarkerCapture,
    CapturingPidBefore,
    RestartRequested,
    WaitingForRespawn,
    ObservingMarker,
    StabilityObservation,
    CompletedPass,
    CompletedNotProven,
    CompletedUnstable,
};

struct PackageProbe {
    bool installed = false;
    std::string packageId;
    std::string version;
    std::string queryMethod;
    bool dylibPresent = false;
    bool plistPresent = false;
    bool payloadValid = false;
};

struct ProcessSnapshot {
    bool unambiguous = false;
    int pid = -1;
};

struct MarkerObservation {
    bool found = false;
    std::string runNonce;
    std::string text;
    std::string process;
    int pid = -1;
    std::uint64_t observedAtNs = 0;
    std::string error;
};

struct DeviceInfo {
    std::string osVersion;
    std::string machine;
    std::string architecture;
};

struct ProofConfig {
    std::uint64_t respawnTimeoutNs = 8'000'000'000ULL;
    std::uint64_t stabilityWindowNs = 5'000'000'000ULL;
    std::uint64_t sampleIntervalNs = 250'000'000ULL;
};

struct Evidence {
    std::string schema = "vcam-pro-gate1-proof/2";
    std::string runnerVersion = "0.2.0";
    std::string buildSha;
    std::string runNonce;

    FinalResult finalResult = FinalResult::NotProven;
    std::string reasonCode = "NOT_STARTED";
    ProofState finalState = ProofState::Idle;

    DeviceInfo device;
    PackageProbe loadProbe;

    std::uint64_t proofStartNs = 0;
    std::uint64_t proofEndNs = 0;

    int pidBefore = -1;
    int pidAfter = -1;
    std::vector<int> pidHistory;

    int intentionalRestartRequests = 0;
    std::string restartAction;
    std::uint64_t restartRequestedAtNs = 0;

    bool markerFound = false;
    std::string markerText;
    int markerPid = -1;
    std::string markerCaptureBackend;

    std::uint64_t stabilityDurationNs = 0;
    bool restartLoopDetected = false;

    std::vector<std::string> helperErrors;
    bool gate2Attempted = false;
};

class Platform {
public:
    virtual ~Platform() = default;

    virtual std::uint64_t nowMonotonicNs() = 0;
    virtual void waitForNs(std::uint64_t durationNs) = 0;

    virtual DeviceInfo deviceInfo() = 0;
    virtual PackageProbe queryLoadProbe() = 0;

    virtual bool armMarkerCapture(
        std::uint64_t proofStartNs,
        std::string* runNonce,
        std::string* backend,
        std::string* error) = 0;

    virtual ProcessSnapshot discoverMediaserverd() = 0;

    virtual bool requestSingleRestart(
        int pid,
        std::string* action,
        std::string* error) = 0;

    virtual MarkerObservation pollMarker(
        std::uint64_t proofStartNs) = 0;
};

class Gate1ProofRunner final {
public:
    explicit Gate1ProofRunner(
        Platform& platform,
        ProofConfig config = {});

    Evidence run(const std::string& buildSha = "");

    ProofState state() const noexcept;

    static std::string finalResultString(FinalResult value);
    static std::string stateString(ProofState value);

    static std::string renderText(const Evidence& evidence);
    static std::string renderJson(const Evidence& evidence);

private:
    Evidence finishNotProven(
        Evidence evidence,
        const std::string& reason);

    Evidence finishUnstable(
        Evidence evidence,
        const std::string& reason);

    Evidence finishPass(Evidence evidence);

    void appendPid(Evidence* evidence, int pid) const;

    bool captureMarkerIfPresent(Evidence* evidence);

    Platform& platform_;
    ProofConfig config_;
    ProofState state_ = ProofState::Idle;
};

}  // namespace vcam::gate1
