#include "Gate1WitnessProtocol.h"

namespace vcam::gate1 {

namespace {

bool Fail(std::string* reason, const char* value) {
    if (reason != nullptr) {
        *reason = value;
    }
    return false;
}

}  // namespace

bool ValidateWitnessRunRequest(
    const WitnessRunRequest& request,
    std::string* reason) {
    if (!request.active) {
        return Fail(reason, "RUN_REQUEST_INACTIVE");
    }
    if (request.nonce.empty()) {
        return Fail(reason, "RUN_NONCE_MISSING");
    }
    if (request.proofStartNs == 0) {
        return Fail(reason, "RUN_START_MISSING");
    }
    if (request.runnerVersion.empty()) {
        return Fail(reason, "RUNNER_VERSION_MISSING");
    }
    if (request.buildSha.empty()) {
        return Fail(reason, "BUILD_SHA_MISSING");
    }
    if (reason != nullptr) {
        reason->clear();
    }
    return true;
}

bool ValidateWitnessRecord(
    const WitnessRecord& record,
    const std::string& expectedNonce,
    int expectedCurrentPid,
    std::uint64_t expectedProofStartNs,
    std::uint64_t nowNs,
    std::string* reason) {
    if (!record.parsed) {
        return Fail(reason, "WITNESS_MALFORMED");
    }
    if (record.nonce != expectedNonce || expectedNonce.empty()) {
        return Fail(reason, "WITNESS_NONCE_MISMATCH");
    }
    if (record.marker != kGate1Marker) {
        return Fail(reason, "WITNESS_MARKER_MISMATCH");
    }
    if (record.process != kGate1Process) {
        return Fail(reason, "WITNESS_PROCESS_MISMATCH");
    }
    if (record.pid <= 0 || record.pid != expectedCurrentPid) {
        return Fail(reason, "WITNESS_PID_MISMATCH");
    }
    if (record.witnessVersion.empty()) {
        return Fail(reason, "WITNESS_VERSION_MISSING");
    }
    if (record.proofStartNs != expectedProofStartNs ||
        expectedProofStartNs == 0) {
        return Fail(reason, "WITNESS_RUN_START_MISMATCH");
    }
    if (record.observedAtNs < expectedProofStartNs) {
        return Fail(reason, "WITNESS_STALE");
    }
    if (nowNs < record.observedAtNs) {
        return Fail(reason, "WITNESS_TIME_INVALID");
    }
    if ((nowNs - record.observedAtNs) > kWitnessMaxAgeNs) {
        return Fail(reason, "WITNESS_STALE");
    }
    if (reason != nullptr) {
        reason->clear();
    }
    return true;
}

}  // namespace vcam::gate1
