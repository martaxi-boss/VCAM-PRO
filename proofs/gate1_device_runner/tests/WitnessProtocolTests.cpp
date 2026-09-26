#include "WitnessProtocol.h"

#include <cstdlib>
#include <functional>
#include <iostream>
#include <string>

namespace {

using namespace vcam::gate1;

int gTests = 0;
int gFailures = 0;

#define CHECK(x) do { if (!(x)) {     std::cerr << "CHECK failed line " << __LINE__ << ": " #x << "\n";     return false; } } while (false)

RunRequest GoodRequest() {
    RunRequest request;
    request.schema = "vcam-pro-gate1-request/1";
    request.nonce = "0123456789abcdef0123456789abcdef";
    request.proofStartNs = 1000;
    request.runnerVersion = "0.2.0";
    request.buildSha = "abc123";
    return request;
}

WitnessRecord GoodRecord() {
    WitnessRecord record;
    record.schema = "vcam-pro-gate1-witness/1";
    record.nonce = "0123456789abcdef0123456789abcdef";
    record.process = "mediaserverd";
    record.pid = 222;
    record.marker = ExpectedMarkerForPid(record.pid);
    record.witnessVersion = "0.1.0";
    record.observedAtNs = 1500;
    return record;
}

bool TestNoActiveToken() {
    RunRequest request;
    CHECK(!ParseRunRequest("", &request));
    return true;
}

bool TestRequestRoundTrip() {
    const RunRequest original = GoodRequest();
    RunRequest parsed;
    CHECK(ParseRunRequest(RenderRunRequest(original), &parsed));
    CHECK(parsed.nonce == original.nonce);
    CHECK(parsed.proofStartNs == original.proofStartNs);
    return true;
}

bool TestFreshRequestAccepted() {
    CHECK(ValidateRunRequest(GoodRequest(), 2000, 2000) == ProtocolStatus::Ok);
    return true;
}

bool TestStaleRequestRejected() {
    CHECK(ValidateRunRequest(GoodRequest(), 5000, 1000) == ProtocolStatus::Stale);
    return true;
}

bool TestWrongNonceRejected() {
    const auto record = GoodRecord();
    CHECK(ValidateWitnessRecord(record, "different-nonce-0000", 1000, 222, 222) == ProtocolStatus::WrongNonce);
    return true;
}

bool TestStaleWitnessRejected() {
    auto record = GoodRecord();
    record.observedAtNs = 999;
    CHECK(ValidateWitnessRecord(record, record.nonce, 1000, 222, 222) == ProtocolStatus::Stale);
    return true;
}

bool TestExactMarkerRequired() {
    auto record = GoodRecord();
    record.marker = "VCAM_PRO_LOAD_PROBE_001";
    CHECK(ValidateWitnessRecord(record, record.nonce, 1000, 222, 222) == ProtocolStatus::WrongMarker);
    return true;
}

bool TestWrongProcessRejected() {
    auto record = GoodRecord();
    record.process = "SpringBoard";
    CHECK(ValidateWitnessRecord(record, record.nonce, 1000, 222, 222) == ProtocolStatus::WrongProcess);
    return true;
}

bool TestMarkerPidMustEqualCurrentPid() {
    const auto record = GoodRecord();
    CHECK(ValidateWitnessRecord(record, record.nonce, 1000, 333, 222) == ProtocolStatus::WrongPid);
    return true;
}

bool TestMarkerPidMustEqualPidAfter() {
    const auto record = GoodRecord();
    CHECK(ValidateWitnessRecord(record, record.nonce, 1000, 222, 333) == ProtocolStatus::WrongPid);
    return true;
}

bool TestValidWitnessAccepted() {
    const auto record = GoodRecord();
    CHECK(ValidateWitnessRecord(record, record.nonce, 1000, 222, 222) == ProtocolStatus::Ok);
    return true;
}

bool TestMalformedWitnessRejected() {
    WitnessRecord record;
    CHECK(!ParseWitnessRecord("schema=vcam-pro-gate1-witness/1\nnonce=x\n", &record));
    return true;
}

bool TestWitnessRoundTrip() {
    const WitnessRecord original = GoodRecord();
    WitnessRecord parsed;
    CHECK(ParseWitnessRecord(RenderWitnessRecord(original), &parsed));
    CHECK(parsed.nonce == original.nonce);
    CHECK(parsed.marker == original.marker);
    CHECK(parsed.process == "mediaserverd");
    CHECK(parsed.pid == 222);
    return true;
}

void Run(const char* name, const std::function<bool()>& test) {
    ++gTests;
    if (test()) {
        std::cout << "[PASS] " << name << "\n";
    } else {
        ++gFailures;
        std::cerr << "[FAIL] " << name << "\n";
    }
}

}  // namespace

int main() {
    Run("no active token", TestNoActiveToken);
    Run("request round trip", TestRequestRoundTrip);
    Run("fresh request accepted", TestFreshRequestAccepted);
    Run("stale request rejected", TestStaleRequestRejected);
    Run("wrong nonce rejected", TestWrongNonceRejected);
    Run("stale witness rejected", TestStaleWitnessRejected);
    Run("exact marker required", TestExactMarkerRequired);
    Run("wrong process rejected", TestWrongProcessRejected);
    Run("marker pid equals current", TestMarkerPidMustEqualCurrentPid);
    Run("marker pid equals pid after", TestMarkerPidMustEqualPidAfter);
    Run("valid witness accepted", TestValidWitnessAccepted);
    Run("malformed witness rejected", TestMalformedWitnessRejected);
    Run("witness round trip", TestWitnessRoundTrip);

    std::cout << "Gate 1 remediation tests run: " << gTests << ", failures: " << gFailures << "\n";
    return gFailures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
