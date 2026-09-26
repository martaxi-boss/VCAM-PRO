#include "WitnessProtocol.h"

#include <cstdlib>
#include <functional>
#include <iostream>
#include <string>

namespace {

using namespace vcam::gate1;

int gTestsRun = 0;
int gFailures = 0;

#define CHECK(condition) do { if (!(condition)) { return false; } } while (false)

RunRequest Request() {
    RunRequest request;
    request.schema = "vcam-pro-gate1-request/1";
    request.nonce = "00112233445566778899aabbccddeeff";
    request.proofStartNs = 1000;
    request.runnerVersion = "0.2.0";
    request.buildSha = "abcdef";
    return request;
}

WitnessRecord Record() {
    WitnessRecord record;
    record.schema = "vcam-pro-gate1-witness/1";
    record.nonce = Request().nonce;
    record.process = "mediaserverd";
    record.pid = 222;
    record.marker = ExpectedMarkerForPid(record.pid);
    record.witnessVersion = "0.1.0";
    record.observedAtNs = 1100;
    return record;
}

bool NoActiveToken() {
    RunRequest empty;
    return ValidateRunRequest(empty, 2000, 5000) ==
        ProtocolStatus::Malformed;
}

bool ActiveToken() {
    return ValidateRunRequest(Request(), 2000, 5000) ==
        ProtocolStatus::Ok;
}

bool WrongNonce() {
    auto r = Record();
    r.nonce = "ffeeddccbbaa99887766554433221100";
    return ValidateWitnessRecord(
        r, Request().nonce, 1000, 222, 222) ==
        ProtocolStatus::WrongNonce;
}

bool StaleWitness() {
    auto r = Record();
    r.observedAtNs = 999;
    return ValidateWitnessRecord(
        r, Request().nonce, 1000, 222, 222) ==
        ProtocolStatus::Stale;
}

bool ExactMarkerRequired() {
    auto r = Record();
    r.marker = "VCAM_PRO_LOAD_PROBE_001";
    return ValidateWitnessRecord(
        r, Request().nonce, 1000, 222, 222) ==
        ProtocolStatus::WrongMarker;
}

bool WrongProcess() {
    auto r = Record();
    r.process = "SpringBoard";
    return ValidateWitnessRecord(
        r, Request().nonce, 1000, 222, 222) ==
        ProtocolStatus::WrongProcess;
}

bool CurrentPidRequired() {
    return ValidateWitnessRecord(
        Record(), Request().nonce, 1000, 333, 222) ==
        ProtocolStatus::WrongPid;
}

bool PidAfterRequired() {
    return ValidateWitnessRecord(
        Record(), Request().nonce, 1000, 222, 333) ==
        ProtocolStatus::WrongPid;
}

bool ValidWitness() {
    return ValidateWitnessRecord(
        Record(), Request().nonce, 1000, 222, 222) ==
        ProtocolStatus::Ok;
}

bool StaleRequest() {
    return ValidateRunRequest(Request(), 10000, 5000) ==
        ProtocolStatus::Stale;
}

bool WitnessRoundTrip() {
    const WitnessRecord original = Record();
    const std::string rendered = RenderWitnessRecord(original);
    if (rendered.empty()) return false;

    WitnessRecord parsed;
    return ParseWitnessRecord(rendered, &parsed) &&
           parsed.nonce == original.nonce &&
           parsed.marker == original.marker &&
           parsed.process == original.process &&
           parsed.pid == original.pid &&
           parsed.witnessVersion == original.witnessVersion &&
           parsed.observedAtNs == original.observedAtNs;
}

void Run(const char* name, const std::function<bool()>& test) {
    ++gTestsRun;
    if (test()) {
        std::cout << "[PASS] " << name << "\n";
    } else {
        ++gFailures;
        std::cerr << "[FAIL] " << name << "\n";
    }
}

}  // namespace

int main() {
    Run("witness disabled without active token", NoActiveToken);
    Run("active token accepted", ActiveToken);
    Run("wrong nonce rejected", WrongNonce);
    Run("stale witness rejected", StaleWitness);
    Run("exact marker required", ExactMarkerRequired);
    Run("wrong process rejected", WrongProcess);
    Run("current mediaserverd PID required", CurrentPidRequired);
    Run("PID_AFTER required", PidAfterRequired);
    Run("valid witness accepted", ValidWitness);
    Run("stale request rejected", StaleRequest);
    Run("witness record round trip", WitnessRoundTrip);

    std::cout << "Gate 1 remediation tests run: "
              << gTestsRun << ", failures: " << gFailures << "\n";
    return gFailures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
