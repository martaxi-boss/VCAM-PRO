#include "Gate1WitnessProtocol.h"

#include <cstdlib>
#include <functional>
#include <iostream>
#include <string>

namespace {

using namespace vcam::gate1;

int gTests = 0;
int gFailures = 0;

#define CHECK(x) do { if (!(x)) { std::cerr << "CHECK failed: " #x << "\n"; return false; } } while (false)

WitnessRunRequest ValidRequest() {
    return {true, "nonce-123", 1000, "0.2.0", "deadbeef"};
}

WitnessRecord ValidRecord() {
    return {
        true,
        "nonce-123",
        kGate1Marker,
        kGate1Process,
        222,
        kGate1WitnessVersion,
        1000,
        1200,
    };
}

bool TestWitnessDisabledWithoutToken() {
    auto r = ValidRequest();
    r.active = false;
    std::string reason;
    CHECK(!ValidateWitnessRunRequest(r, &reason));
    CHECK(reason == "RUN_REQUEST_INACTIVE");
    return true;
}

bool TestWrongNonceRejected() {
    auto record = ValidRecord();
    std::string reason;
    CHECK(!ValidateWitnessRecord(record, "other", 222, 1000, 1300, &reason));
    CHECK(reason == "WITNESS_NONCE_MISMATCH");
    return true;
}

bool TestStaleEvidenceRejected() {
    auto record = ValidRecord();
    record.observedAtNs = 999;
    std::string reason;
    CHECK(!ValidateWitnessRecord(record, "nonce-123", 222, 1000, 1300, &reason));
    CHECK(reason == "WITNESS_STALE");
    return true;
}

bool TestExactMarkerRequired() {
    auto record = ValidRecord();
    record.marker = "VCAM_PRO_LOAD_PROBE_001_FAKE";
    std::string reason;
    CHECK(!ValidateWitnessRecord(record, "nonce-123", 222, 1000, 1300, &reason));
    CHECK(reason == "WITNESS_MARKER_MISMATCH");
    return true;
}

bool TestWrongProcessRejected() {
    auto record = ValidRecord();
    record.process = "SpringBoard";
    std::string reason;
    CHECK(!ValidateWitnessRecord(record, "nonce-123", 222, 1000, 1300, &reason));
    CHECK(reason == "WITNESS_PROCESS_MISMATCH");
    return true;
}

bool TestMarkerPidMustEqualCurrentPid() {
    auto record = ValidRecord();
    std::string reason;
    CHECK(!ValidateWitnessRecord(record, "nonce-123", 333, 1000, 1300, &reason));
    CHECK(reason == "WITNESS_PID_MISMATCH");
    return true;
}

bool TestMarkerPidCanMatchPidAfter() {
    const auto record = ValidRecord();
    std::string reason;
    CHECK(ValidateWitnessRecord(record, "nonce-123", 222, 1000, 1300, &reason));
    CHECK(record.pid == 222);
    return true;
}

bool TestMalformedUnavailableRecordRejected() {
    WitnessRecord record;
    std::string reason;
    CHECK(!ValidateWitnessRecord(record, "nonce-123", 222, 1000, 1300, &reason));
    CHECK(reason == "WITNESS_MALFORMED");
    return true;
}

bool TestExpiredEvidenceRejected() {
    auto record = ValidRecord();
    record.observedAtNs = 2000;
    std::string reason;
    CHECK(!ValidateWitnessRecord(
        record,
        "nonce-123",
        222,
        1000,
        2000 + kWitnessMaxAgeNs + 1,
        &reason));
    CHECK(reason == "WITNESS_STALE");
    return true;
}

void Run(const char* name, const std::function<bool()>& fn) {
    ++gTests;
    if (!fn()) {
        ++gFailures;
        std::cerr << "[FAIL] " << name << "\n";
    } else {
        std::cout << "[PASS] " << name << "\n";
    }
}

}  // namespace

int main() {
    Run("witness disabled without token", TestWitnessDisabledWithoutToken);
    Run("wrong nonce rejected", TestWrongNonceRejected);
    Run("stale evidence rejected", TestStaleEvidenceRejected);
    Run("exact marker required", TestExactMarkerRequired);
    Run("wrong process rejected", TestWrongProcessRejected);
    Run("marker pid equals current pid", TestMarkerPidMustEqualCurrentPid);
    Run("marker pid can equal pid after", TestMarkerPidCanMatchPidAfter);
    Run("marker unavailable record rejected", TestMalformedUnavailableRecordRejected);
    Run("expired witness rejected", TestExpiredEvidenceRejected);

    std::cout << "Gate 1 remediation tests run: " << gTests
              << ", failures: " << gFailures << "\n";
    return gFailures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
