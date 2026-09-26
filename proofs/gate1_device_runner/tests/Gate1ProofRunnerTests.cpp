#include "Gate1ProofRunner.h"

#include <cstdlib>
#include <functional>
#include <iostream>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace {

using namespace vcam::gate1;

int gTestsRun = 0;
int gFailures = 0;

#define CHECK(condition)                                                        \
    do {                                                                        \
        if (!(condition)) {                                                     \
            std::cerr << "CHECK failed at " << __FILE__ << ":" << __LINE__    \
                      << ": " #condition << std::endl;                          \
            return false;                                                       \
        }                                                                       \
    } while (false)

class FakePlatform final : public Platform {
public:
    std::uint64_t nowMonotonicNs() override {
        return nowNs;
    }

    void waitForNs(std::uint64_t durationNs) override {
        nowNs += durationNs;
    }

    DeviceInfo deviceInfo() override {
        return {"15.8.8", "iPhone8,2", "arm64"};
    }

    PackageProbe queryLoadProbe() override {
        ++packageQueries;
        return packageProbe;
    }

    bool armMarkerCapture(
        std::uint64_t proofStartNs,
        std::string* runNonce,
        std::string* backend,
        std::string* error) override {
        ++markerArmCalls;
        armedAtNs = proofStartNs;
        if (runNonce != nullptr) {
            *runNonce = markerRunNonce;
        }
        if (backend != nullptr) {
            *backend = markerBackend;
        }
        if (!markerArmAvailable && error != nullptr) {
            *error = "marker backend unavailable";
        }
        return markerArmAvailable;
    }

    ProcessSnapshot discoverMediaserverd() override {
        ++processDiscoveryCalls;
        if (processSnapshots.empty()) {
            return {};
        }

        if (processIndex >= processSnapshots.size()) {
            return processSnapshots.back();
        }

        return processSnapshots[processIndex++];
    }

    bool requestSingleRestart(
        int pid,
        std::string* action,
        std::string* error) override {
        ++restartRequests;
        restartTargetPid = pid;
        if (action != nullptr) {
            *action = "SIGTERM_EXACT_PID";
        }
        if (!restartAvailable && error != nullptr) {
            *error = "restart unavailable";
        }
        return restartAvailable;
    }

    MarkerObservation pollMarker(
        std::uint64_t) override {
        ++markerPollCalls;
        if (markers.empty()) {
            return {};
        }

        if (markerIndex >= markers.size()) {
            return markers.back();
        }

        return markers[markerIndex++];
    }

    void resetForRerun() {
        processIndex = 0;
        markerIndex = 0;
        processDiscoveryCalls = 0;
        markerPollCalls = 0;
        restartRequests = 0;
        restartTargetPid = -1;
        markerArmCalls = 0;
        nowNs += 1'000'000'000ULL;
    }

    std::uint64_t nowNs = 1'000'000'000ULL;
    std::uint64_t armedAtNs = 0;

    PackageProbe packageProbe{
        true,
        "com.vcampro.loadprobe",
        "0.0.1",
        "dpkg-status-file:/var/jb/var/lib/dpkg/status",
        true,
        true,
        true,
    };

    bool markerArmAvailable = true;
    bool restartAvailable = true;
    std::string markerBackend = "mediaserverd-local OSLogStoreCurrentProcessIdentifier witness";
    std::string markerRunNonce = "test-nonce-0123456789";

    std::vector<ProcessSnapshot> processSnapshots;
    std::vector<MarkerObservation> markers;

    std::size_t processIndex = 0;
    std::size_t markerIndex = 0;

    int packageQueries = 0;
    int markerArmCalls = 0;
    int processDiscoveryCalls = 0;
    int restartRequests = 0;
    int restartTargetPid = -1;
    int markerPollCalls = 0;
};

ProofConfig FastConfig() {
    ProofConfig config;
    config.respawnTimeoutNs = 400;
    config.stabilityWindowNs = 400;
    config.sampleIntervalNs = 100;
    return config;
}

MarkerObservation Marker(
    int pid,
    std::uint64_t observedAtNs,
    const std::string& process = "mediaserverd") {
    MarkerObservation marker;
    marker.found = true;
    marker.runNonce = "test-nonce-0123456789";
    marker.text =
        "VCAM_PRO_LOAD_PROBE_001 process=" +
        process +
        " pid=" +
        std::to_string(pid);
    marker.process = process;
    marker.pid = pid;
    marker.observedAtNs = observedAtNs;
    return marker;
}

bool TestLoadProbeMissing() {
    FakePlatform platform;
    platform.packageProbe.installed = false;

    Gate1ProofRunner runner(platform, FastConfig());
    const auto evidence = runner.run("test");

    CHECK(evidence.finalResult == FinalResult::NotProven);
    CHECK(evidence.reasonCode == "LOAD_PROBE_NOT_INSTALLED");
    CHECK(platform.restartRequests == 0);
    CHECK(platform.markerArmCalls == 0);
    return true;
}

bool TestPayloadInvalid() {
    FakePlatform platform;
    platform.packageProbe.payloadValid = false;

    Gate1ProofRunner runner(platform, FastConfig());
    const auto evidence = runner.run("test");

    CHECK(evidence.finalResult == FinalResult::NotProven);
    CHECK(evidence.reasonCode == "LOAD_PROBE_PAYLOAD_INVALID");
    CHECK(platform.restartRequests == 0);
    return true;
}

bool TestMarkerCaptureUnavailable() {
    FakePlatform platform;
    platform.markerArmAvailable = false;

    Gate1ProofRunner runner(platform, FastConfig());
    const auto evidence = runner.run("test");

    CHECK(evidence.finalResult == FinalResult::NotProven);
    CHECK(evidence.reasonCode == "MARKER_CAPTURE_UNAVAILABLE");
    CHECK(platform.restartRequests == 0);
    return true;
}

bool TestMediaserverdNotFound() {
    FakePlatform platform;
    platform.processSnapshots = {{false, -1}};

    Gate1ProofRunner runner(platform, FastConfig());
    const auto evidence = runner.run("test");

    CHECK(evidence.finalResult == FinalResult::NotProven);
    CHECK(evidence.reasonCode == "MEDIASERVERD_NOT_UNAMBIGUOUS");
    CHECK(platform.restartRequests == 0);
    return true;
}

bool TestValidPrerequisitesExactlyOneRestart() {
    FakePlatform platform;
    platform.processSnapshots = {
        {true, 100},
        {false, -1},
        {true, 200},
        {true, 200},
        {true, 200},
        {true, 200},
        {true, 200},
    };
    platform.markers = {
        {},
        Marker(200, platform.nowNs + 200),
    };

    Gate1ProofRunner runner(platform, FastConfig());
    const auto evidence = runner.run("test");

    CHECK(platform.restartRequests == 1);
    CHECK(platform.restartTargetPid == 100);
    CHECK(evidence.intentionalRestartRequests == 1);
    return true;
}

bool TestCleanPidTransitionRecorded() {
    FakePlatform platform;
    platform.processSnapshots = {
        {true, 111},
        {false, -1},
        {true, 222},
        {true, 222},
        {true, 222},
        {true, 222},
        {true, 222},
    };
    platform.markers = {
        {},
        Marker(222, platform.nowNs + 200),
    };

    Gate1ProofRunner runner(platform, FastConfig());
    const auto evidence = runner.run("test");

    CHECK(evidence.pidBefore == 111);
    CHECK(evidence.pidAfter == 222);
    CHECK(evidence.pidHistory.size() >= 2);
    CHECK(evidence.pidHistory.front() == 111);
    CHECK(evidence.pidHistory.back() == 222);
    return true;
}

bool TestMarkerStablePidPasses() {
    FakePlatform platform;
    platform.processSnapshots = {
        {true, 10},
        {true, 20},
        {true, 20},
        {true, 20},
        {true, 20},
        {true, 20},
    };
    platform.markers = {
        Marker(20, platform.nowNs + 1),
    };

    Gate1ProofRunner runner(platform, FastConfig());
    const auto evidence = runner.run("test");

    CHECK(evidence.finalResult == FinalResult::Pass);
    CHECK(evidence.reasonCode == "MARKER_OBSERVED_AND_STABLE");
    CHECK(evidence.markerFound);
    CHECK(!evidence.restartLoopDetected);
    CHECK(evidence.stabilityDurationNs >= FastConfig().stabilityWindowNs);
    return true;
}

bool TestStablePidWithoutMarkerNotProven() {
    FakePlatform platform;
    platform.processSnapshots = {
        {true, 10},
        {true, 20},
        {true, 20},
        {true, 20},
        {true, 20},
        {true, 20},
    };

    Gate1ProofRunner runner(platform, FastConfig());
    const auto evidence = runner.run("test");

    CHECK(evidence.finalResult == FinalResult::NotProven);
    CHECK(evidence.reasonCode == "MARKER_NOT_OBSERVED");
    CHECK(platform.restartRequests == 1);
    return true;
}

bool TestStalePreRunMarkerIgnored() {
    FakePlatform platform;
    const std::uint64_t staleTime = platform.nowNs - 1;
    platform.processSnapshots = {
        {true, 10},
        {true, 20},
        {true, 20},
        {true, 20},
        {true, 20},
        {true, 20},
    };
    platform.markers = {
        Marker(20, staleTime),
        {},
    };

    Gate1ProofRunner runner(platform, FastConfig());
    const auto evidence = runner.run("test");

    CHECK(evidence.finalResult == FinalResult::NotProven);
    CHECK(evidence.reasonCode == "MARKER_NOT_OBSERVED");
    CHECK(!evidence.markerFound);
    return true;
}

bool TestMarkerPidMismatchNotProven() {
    FakePlatform platform;
    platform.processSnapshots = {
        {true, 10},
        {true, 20},
        {true, 20},
        {true, 20},
        {true, 20},
        {true, 20},
    };
    platform.markers = {
        Marker(999, platform.nowNs + 1),
    };

    Gate1ProofRunner runner(platform, FastConfig());
    const auto evidence = runner.run("test");

    CHECK(evidence.finalResult == FinalResult::NotProven);
    CHECK(evidence.reasonCode == "MARKER_PID_MISMATCH");
    CHECK(evidence.markerFound);
    CHECK(evidence.markerPid == 999);
    return true;
}

bool TestPidChurnUnstable() {
    FakePlatform platform;
    platform.processSnapshots = {
        {true, 10},
        {true, 20},
        {true, 20},
        {true, 30},
    };
    platform.markers = {
        Marker(20, platform.nowNs + 1),
    };

    Gate1ProofRunner runner(platform, FastConfig());
    const auto evidence = runner.run("test");

    CHECK(evidence.finalResult == FinalResult::FailLoadUnstable);
    CHECK(evidence.reasonCode == "MEDIASERVERD_PID_CHURN");
    CHECK(evidence.restartLoopDetected);
    CHECK(platform.restartRequests == 1);
    return true;
}

bool TestDaemonUnavailableUnstable() {
    FakePlatform platform;
    platform.processSnapshots = {
        {true, 10},
        {true, 20},
        {false, -1},
    };
    platform.markers = {
        Marker(20, platform.nowNs + 1),
    };

    Gate1ProofRunner runner(platform, FastConfig());
    const auto evidence = runner.run("test");

    CHECK(evidence.finalResult == FinalResult::FailLoadUnstable);
    CHECK(evidence.reasonCode == "MEDIASERVERD_BECAME_UNAVAILABLE");
    CHECK(evidence.restartLoopDetected);
    return true;
}

bool TestNoDuplicateRestartOnTimeout() {
    FakePlatform platform;
    platform.processSnapshots = {
        {true, 10},
        {true, 10},
        {true, 10},
        {true, 10},
        {true, 10},
        {true, 10},
    };

    Gate1ProofRunner runner(platform, FastConfig());
    const auto evidence = runner.run("test");

    CHECK(evidence.finalResult == FinalResult::FailLoadUnstable);
    CHECK(evidence.reasonCode == "MEDIASERVERD_DID_NOT_RESPAWN");
    CHECK(platform.restartRequests == 1);
    CHECK(evidence.intentionalRestartRequests == 1);
    return true;
}

bool TestExplicitRerunCreatesNewLifecycle() {
    FakePlatform platform;
    platform.processSnapshots = {
        {true, 10},
        {true, 20},
        {true, 20},
        {true, 20},
        {true, 20},
        {true, 20},
    };
    platform.markers = {
        Marker(20, platform.nowNs + 1),
    };

    Gate1ProofRunner runner(platform, FastConfig());
    const auto first = runner.run("first");
    CHECK(first.finalResult == FinalResult::Pass);
    CHECK(platform.restartRequests == 1);

    platform.resetForRerun();
    platform.processSnapshots = {
        {true, 20},
        {true, 30},
        {true, 30},
        {true, 30},
        {true, 30},
        {true, 30},
    };
    platform.markers = {
        Marker(30, platform.nowNs + 1),
    };

    const auto second = runner.run("second");

    CHECK(second.finalResult == FinalResult::Pass);
    CHECK(second.pidBefore == 20);
    CHECK(second.pidAfter == 30);
    CHECK(platform.restartRequests == 1);
    CHECK(second.proofStartNs > first.proofStartNs);
    return true;
}

bool TestFinalStateNeverStartsGate2() {
    FakePlatform platform;
    platform.processSnapshots = {
        {true, 10},
        {true, 20},
        {true, 20},
        {true, 20},
        {true, 20},
        {true, 20},
    };
    platform.markers = {
        Marker(20, platform.nowNs + 1),
    };

    Gate1ProofRunner runner(platform, FastConfig());
    const auto evidence = runner.run("test");

    CHECK(evidence.finalResult == FinalResult::Pass);
    CHECK(evidence.finalState == ProofState::CompletedPass);
    CHECK(!evidence.gate2Attempted);
    CHECK(runner.state() == ProofState::CompletedPass);
    return true;
}

void Run(
    const std::string& name,
    const std::function<bool()>& test) {
    ++gTestsRun;
    try {
        if (!test()) {
            ++gFailures;
            std::cerr << "[FAIL] " << name << std::endl;
            return;
        }
        std::cout << "[PASS] " << name << std::endl;
    } catch (const std::exception& error) {
        ++gFailures;
        std::cerr << "[FAIL] " << name
                  << ": " << error.what() << std::endl;
    }
}

}  // namespace

int main() {
    Run("load probe missing", TestLoadProbeMissing);
    Run("payload invalid", TestPayloadInvalid);
    Run("marker capture unavailable", TestMarkerCaptureUnavailable);
    Run("mediaserverd not found", TestMediaserverdNotFound);
    Run("valid prerequisites one restart", TestValidPrerequisitesExactlyOneRestart);
    Run("clean PID transition", TestCleanPidTransitionRecorded);
    Run("marker plus stable PID passes", TestMarkerStablePidPasses);
    Run("stable PID no marker", TestStablePidWithoutMarkerNotProven);
    Run("stale marker ignored", TestStalePreRunMarkerIgnored);
    Run("marker PID mismatch", TestMarkerPidMismatchNotProven);
    Run("PID churn unstable", TestPidChurnUnstable);
    Run("daemon unavailable unstable", TestDaemonUnavailableUnstable);
    Run("no duplicate restart on timeout", TestNoDuplicateRestartOnTimeout);
    Run("explicit rerun new lifecycle", TestExplicitRerunCreatesNewLifecycle);
    Run("final state no Gate 2", TestFinalStateNeverStartsGate2);

    std::cout << "Gate 1 runner host tests run: "
              << gTestsRun
              << ", failures: " << gFailures << std::endl;

    return gFailures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
