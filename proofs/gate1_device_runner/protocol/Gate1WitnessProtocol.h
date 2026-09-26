#pragma once

#include <cstdint>
#include <string>

namespace vcam::gate1 {

inline constexpr const char* kGate1Marker = "VCAM_PRO_LOAD_PROBE_001";
inline constexpr const char* kGate1Process = "mediaserverd";
inline constexpr const char* kGate1RequestPath = "/var/tmp/com.vcampro.gate1.request.json";
inline constexpr const char* kGate1WitnessPath = "/var/tmp/com.vcampro.gate1.witness.json";
inline constexpr const char* kGate1WitnessVersion = "0.1.0";
inline constexpr const char* kGate1RunnerVersion = "0.2.0";
inline constexpr std::uint64_t kWitnessMaxAgeNs = 20'000'000'000ULL;

struct WitnessRunRequest {
    bool active = false;
    std::string nonce;
    std::uint64_t proofStartNs = 0;
    std::string runnerVersion;
    std::string buildSha;
};

struct WitnessRecord {
    bool parsed = false;
    std::string nonce;
    std::string marker;
    std::string process;
    int pid = -1;
    std::string witnessVersion;
    std::uint64_t proofStartNs = 0;
    std::uint64_t observedAtNs = 0;
};

bool ValidateWitnessRunRequest(
    const WitnessRunRequest& request,
    std::string* reason);

bool ValidateWitnessRecord(
    const WitnessRecord& record,
    const std::string& expectedNonce,
    int expectedCurrentPid,
    std::uint64_t expectedProofStartNs,
    std::uint64_t nowNs,
    std::string* reason);

}  // namespace vcam::gate1
