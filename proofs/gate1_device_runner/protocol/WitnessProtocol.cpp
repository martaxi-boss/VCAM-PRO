#include "WitnessProtocol.h"

#include <charconv>
#include <map>
#include <sstream>

namespace vcam::gate1 {
namespace {

std::map<std::string, std::string> parseKeyValues(const std::string& text) {
    std::map<std::string, std::string> values;
    std::istringstream input(text);
    std::string line;
    while (std::getline(input, line)) {
        if (line.empty()) continue;
        const auto pos = line.find('=');
        if (pos == std::string::npos || pos == 0) continue;
        values[line.substr(0, pos)] = line.substr(pos + 1);
    }
    return values;
}

bool parseU64(const std::string& value, std::uint64_t* out) {
    if (out == nullptr || value.empty()) return false;
    std::uint64_t parsed = 0;
    const auto result = std::from_chars(
        value.data(), value.data() + value.size(), parsed);
    if (result.ec != std::errc{} || result.ptr != value.data() + value.size()) {
        return false;
    }
    *out = parsed;
    return true;
}

bool parseInt(const std::string& value, int* out) {
    if (out == nullptr || value.empty()) return false;
    int parsed = 0;
    const auto result = std::from_chars(
        value.data(), value.data() + value.size(), parsed);
    if (result.ec != std::errc{} || result.ptr != value.data() + value.size()) {
        return false;
    }
    *out = parsed;
    return true;
}

std::string get(
    const std::map<std::string, std::string>& values,
    const std::string& key) {
    const auto it = values.find(key);
    return it == values.end() ? std::string{} : it->second;
}

}  // namespace

bool parseRunRequest(const std::string& text, RunRequestRecord* out) {
    if (out == nullptr) return false;
    const auto values = parseKeyValues(text);
    if (get(values, "schema") != "vcam-pro-gate1-request/1") return false;

    RunRequestRecord record;
    record.nonce = get(values, "nonce");
    record.runnerVersion = get(values, "runner_version");
    record.buildSha = get(values, "build_sha");
    if (record.nonce.empty() || record.runnerVersion.empty()) return false;
    if (!parseU64(get(values, "proof_start_ns"), &record.proofStartNs)) return false;
    if (!parseU64(get(values, "expires_ns"), &record.expiresNs)) return false;
    if (record.expiresNs <= record.proofStartNs) return false;
    *out = std::move(record);
    return true;
}

bool runRequestIsActive(
    const RunRequestRecord& request,
    std::uint64_t nowNs) {
    return !request.nonce.empty() &&
           nowNs >= request.proofStartNs &&
           nowNs <= request.expiresNs;
}

bool parseWitnessRecord(const std::string& text, WitnessRecord* out) {
    if (out == nullptr) return false;
    const auto values = parseKeyValues(text);
    if (get(values, "schema") != "vcam-pro-gate1-witness/1") return false;

    WitnessRecord record;
    record.nonce = get(values, "nonce");
    record.marker = get(values, "marker");
    record.process = get(values, "process");
    record.witnessVersion = get(values, "witness_version");
    if (record.nonce.empty() || record.marker.empty() ||
        record.process.empty() || record.witnessVersion.empty()) {
        return false;
    }
    if (!parseInt(get(values, "pid"), &record.pid) || record.pid <= 0) return false;
    if (!parseU64(get(values, "observed_ns"), &record.observedNs)) return false;
    *out = std::move(record);
    return true;
}

WitnessValidation validateWitness(
    const WitnessRecord& record,
    const std::string& expectedNonce,
    std::uint64_t proofStartNs,
    int expectedCurrentPid) {
    if (record.nonce.empty() || record.marker.empty() ||
        record.process.empty() || record.pid <= 0 ||
        record.observedNs == 0) {
        return WitnessValidation::Malformed;
    }
    if (record.nonce != expectedNonce) return WitnessValidation::WrongNonce;
    if (record.observedNs < proofStartNs) return WitnessValidation::Stale;
    if (record.process != "mediaserverd") return WitnessValidation::WrongProcess;
    if (record.pid != expectedCurrentPid) return WitnessValidation::WrongPid;

    const std::string expected =
        std::string(kGate1MarkerPrefix) +
        " process=mediaserverd pid=" +
        std::to_string(record.pid);
    if (record.marker != expected) return WitnessValidation::WrongMarker;
    return WitnessValidation::Valid;
}

std::string witnessValidationString(WitnessValidation value) {
    switch (value) {
        case WitnessValidation::Valid: return "VALID";
        case WitnessValidation::Malformed: return "MALFORMED";
        case WitnessValidation::WrongNonce: return "WRONG_NONCE";
        case WitnessValidation::Stale: return "STALE";
        case WitnessValidation::WrongMarker: return "WRONG_MARKER";
        case WitnessValidation::WrongProcess: return "WRONG_PROCESS";
        case WitnessValidation::WrongPid: return "WRONG_PID";
    }
    return "UNKNOWN";
}
}  // namespace vcam::gate1
