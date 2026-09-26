#include "WitnessProtocol.h"

#include <cstdlib>
#include <functional>
#include <iostream>
#include <string>

using namespace vcam::gate1;

namespace {
int tests = 0;
int failures = 0;
#define CHECK(x) do { if (!(x)) { std::cerr << "CHECK failed: " #x << "\n"; return false; } } while (0)

std::string Request(const std::string& nonce = "n1") {
    return "schema=vcam-pro-gate1-request/1\nnonce=" + nonce +
        "\nproof_start_ns=100\nexpires_ns=500\nrunner_version=0.2.0\nbuild_sha=abc\n";
}

std::string Witness(
    const std::string& nonce = "n1",
    const std::string& marker =
        "VCAM_PRO_LOAD_PROBE_001 process=mediaserverd pid=20",
    const std::string& process = "mediaserverd",
    int pid = 20,
    std::uint64_t observed = 200) {
    return "schema=vcam-pro-gate1-witness/1\nnonce=" + nonce +
        "\nmarker=" + marker +
        "\nprocess=" + process +
        "\npid=" + std::to_string(pid) +
        "\nwitness_version=0.2.0\nobserved_ns=" +
        std::to_string(observed) + "\n";
}

bool noTokenDisabled() {
    RunRequestRecord request;
    CHECK(!parseRunRequest("", &request));
    return true;
}

bool activeTokenBounded() {
    RunRequestRecord request;
    CHECK(parseRunRequest(Request(), &request));
    CHECK(runRequestIsActive(request, 100));
    CHECK(runRequestIsActive(request, 500));
    CHECK(!runRequestIsActive(request, 99));
    CHECK(!runRequestIsActive(request, 501));
    return true;
}

bool wrongNonceRejected() {
    WitnessRecord witness;
    CHECK(parseWitnessRecord(Witness("other"), &witness));
    CHECK(validateWitness(witness, "n1", 100, 20) ==
          WitnessValidation::WrongNonce);
    return true;
}

bool staleRejected() {
    WitnessRecord witness;
    CHECK(parseWitnessRecord(
        Witness("n1",
                "VCAM_PRO_LOAD_PROBE_001 process=mediaserverd pid=20",
                "mediaserverd",
                20,
                99),
        &witness));
    CHECK(validateWitness(witness, "n1", 100, 20) ==
          WitnessValidation::Stale);
    return true;
}

bool exactMarkerRequired() {
    WitnessRecord witness;
    CHECK(parseWitnessRecord(
        Witness("n1", "VCAM_PRO_LOAD_PROBE_001", "mediaserverd", 20, 200),
        &witness));
    CHECK(validateWitness(witness, "n1", 100, 20) ==
          WitnessValidation::WrongMarker);
    return true;
}

bool wrongProcessRejected() {
    WitnessRecord witness;
    CHECK(parseWitnessRecord(
        Witness("n1",
                "VCAM_PRO_LOAD_PROBE_001 process=SpringBoard pid=20",
                "SpringBoard",
                20,
                200),
        &witness));
    CHECK(validateWitness(witness, "n1", 100, 20) ==
          WitnessValidation::WrongProcess);
    return true;
}

bool currentPidRequired() {
    WitnessRecord witness;
    CHECK(parseWitnessRecord(Witness(), &witness));
    CHECK(validateWitness(witness, "n1", 100, 21) ==
          WitnessValidation::WrongPid);
    return true;
}

bool validAccepted() {
    WitnessRecord witness;
    CHECK(parseWitnessRecord(Witness(), &witness));
    CHECK(validateWitness(witness, "n1", 100, 20) ==
          WitnessValidation::Valid);
    return true;
}

void run(const char* name, const std::function<bool()>& test) {
    ++tests;
    if (test()) {
        std::cout << "[PASS] " << name << "\n";
    } else {
        ++failures;
        std::cout << "[FAIL] " << name << "\n";
    }
}
}  // namespace

int main() {
    run("witness disabled without active token", noTokenDisabled);
    run("run token is bounded", activeTokenBounded);
    run("wrong nonce rejected", wrongNonceRejected);
    run("stale witness rejected", staleRejected);
    run("exact marker required", exactMarkerRequired);
    run("wrong process rejected", wrongProcessRejected);
    run("marker pid equals current mediaserverd", currentPidRequired);
    run("valid witness accepted", validAccepted);

    std::cout << "Gate 1 witness protocol tests run: "
              << tests << ", failures: " << failures << "\n";
    return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
