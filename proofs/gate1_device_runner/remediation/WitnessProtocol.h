#pragma once

#include <cstdint>
#include <string>

namespace vcam::gate1 {

struct RunRequest {
    std::string schema;
    std::string nonce;
    std::uint64_t proofStartNs = 0;
    std::string runnerVersion;
    std::string buildSha;
};

struct WitnessRecord {
    std::string schema;
    std::string nonce;
    std::string marker;
    std::string process;
    int pid = -1;
    std::string witnessVersion;
    std::uint64_t observedAtNs = 0;
};

enum class ProtocolStatus {
    Ok = 0,
    Malformed,
    WrongNonce,
    Stale,
    WrongMarker,
    WrongProcess,
    WrongPid,
};

std::string ExpectedMarkerForPid(int pid);

std::string RenderRunRequest(const RunRequest& request);
std::string RenderWitnessRecord(const WitnessRecord& record);

bool ParseRunRequest(
    const std::string& text,
    RunRequest* request);

bool ParseWitnessRecord(
    const std::string& text,
    WitnessRecord* record);

ProtocolStatus ValidateRunRequest(
    const RunRequest& request,
    std::uint64_t nowNs,
    std::uint64_t maxAgeNs);

ProtocolStatus ValidateWitnessRecord(
    const WitnessRecord& record,
    const std::string& expectedNonce,
    std::uint64_t proofStartNs,
    int currentPid,
    int pidAfter);

const char* ProtocolStatusString(ProtocolStatus value);

}  // namespace vcam::gate1
