#pragma once
#include <cstdint>
#include <string>

namespace vcam::gate1 {
inline constexpr const char* kGate1MarkerPrefix = "VCAM_PRO_LOAD_PROBE_001";
inline constexpr const char* kRunRequestPath = "/var/tmp/vcampro-gate1-request.txt";
inline constexpr const char* kWitnessEvidencePath = "/var/tmp/vcampro-gate1-witness.txt";
inline constexpr const char* kResultDirectory = "/var/mobile/Library/VCAMProGate1";
inline constexpr const char* kResultTextPath = "/var/mobile/Library/VCAMProGate1/VCAM_PRO_GATE1_RESULT.txt";
inline constexpr const char* kResultJsonPath = "/var/mobile/Library/VCAMProGate1/VCAM_PRO_GATE1_RESULT.json";

struct RunRequestRecord {
    std::string nonce;
    std::uint64_t proofStartNs = 0;
    std::uint64_t expiresNs = 0;
    std::string runnerVersion;
    std::string buildSha;
};

struct WitnessRecord {
    std::string nonce;
    std::string marker;
    std::string process;
    int pid = -1;
    std::string witnessVersion;
    std::uint64_t observedNs = 0;
};

bool parseRunRequest(const std::string& text, RunRequestRecord* out);
bool runRequestIsActive(const RunRequestRecord& request, std::uint64_t nowNs);
bool parseWitnessRecord(const std::string& text, WitnessRecord* out);

enum class WitnessValidation {
    Valid = 0,
    Malformed,
    WrongNonce,
    Stale,
    WrongMarker,
    WrongProcess,
    WrongPid,
};

WitnessValidation validateWitness(
    const WitnessRecord& record,
    const std::string& expectedNonce,
    std::uint64_t proofStartNs,
    int expectedCurrentPid);

std::string witnessValidationString(WitnessValidation value);
}  // namespace vcam::gate1
