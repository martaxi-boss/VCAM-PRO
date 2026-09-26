#include "WitnessProtocol.h"

#include <charconv>
#include <map>
#include <sstream>
#include <string_view>

namespace vcam::gate1 {
namespace {

bool IsSafeValue(const std::string& value) {
    return value.find('\n') == std::string::npos &&
           value.find('\r') == std::string::npos;
}

bool ParseMap(
    const std::string& text,
    std::map<std::string, std::string>* values) {
    if (values == nullptr) return false;
    values->clear();

    std::istringstream input(text);
    std::string line;
    while (std::getline(input, line)) {
        if (line.empty()) continue;
        if (!line.empty() && line.back() == '\r') line.pop_back();

        const std::size_t pos = line.find('=');
        if (pos == std::string::npos || pos == 0) return false;

        const std::string key = line.substr(0, pos);
        const std::string value = line.substr(pos + 1);
        if (values->count(key) != 0) return false;
        values->emplace(key, value);
    }
    return !values->empty();
}

bool ParseU64(const std::string& text, std::uint64_t* value) {
    if (value == nullptr || text.empty()) return false;
    const char* begin = text.data();
    const char* end = begin + text.size();
    std::uint64_t parsed = 0;
    const auto result = std::from_chars(begin, end, parsed);
    if (result.ec != std::errc() || result.ptr != end) return false;
    *value = parsed;
    return true;
}

bool ParseInt(const std::string& text, int* value) {
    if (value == nullptr || text.empty()) return false;
    const char* begin = text.data();
    const char* end = begin + text.size();
    int parsed = -1;
    const auto result = std::from_chars(begin, end, parsed);
    if (result.ec != std::errc() || result.ptr != end) return false;
    *value = parsed;
    return true;
}

bool Get(
    const std::map<std::string, std::string>& values,
    const char* key,
    std::string* value) {
    const auto it = values.find(key);
    if (it == values.end() || value == nullptr) return false;
    *value = it->second;
    return true;
}

}  // namespace

std::string ExpectedMarkerForPid(int pid) {
    return "VCAM_PRO_LOAD_PROBE_001 process=mediaserverd pid=" +
           std::to_string(pid);
}

std::string RenderRunRequest(const RunRequest& request) {
    if (!IsSafeValue(request.nonce) ||
        !IsSafeValue(request.runnerVersion) ||
        !IsSafeValue(request.buildSha)) {
        return {};
    }

    std::ostringstream out;
    out << "schema=vcam-pro-gate1-request/1\n";
    out << "nonce=" << request.nonce << "\n";
    out << "proof_start_ns=" << request.proofStartNs << "\n";
    out << "runner_version=" << request.runnerVersion << "\n";
    out << "build_sha=" << request.buildSha << "\n";
    return out.str();
}

std::string RenderWitnessRecord(const WitnessRecord& record) {
    if (!IsSafeValue(record.nonce) ||
        !IsSafeValue(record.marker) ||
        !IsSafeValue(record.process) ||
        !IsSafeValue(record.witnessVersion)) {
        return {};
    }

    std::ostringstream out;
    out << "schema=vcam-pro-gate1-witness/1\n";
    out << "nonce=" << record.nonce << "\n";
    out << "marker=" << record.marker << "\n";
    out << "process=" << record.process << "\n";
    out << "pid=" << record.pid << "\n";
    out << "witness_version=" << record.witnessVersion << "\n";
    out << "observed_at_ns=" << record.observedAtNs << "\n";
    return out.str();
}

bool ParseRunRequest(
    const std::string& text,
    RunRequest* request) {
    if (request == nullptr) return false;

    std::map<std::string, std::string> values;
    if (!ParseMap(text, &values) || values.size() != 5) return false;

    RunRequest parsed;
    if (!Get(values, "schema", &parsed.schema) ||
        !Get(values, "nonce", &parsed.nonce) ||
        !Get(values, "runner_version", &parsed.runnerVersion) ||
        !Get(values, "build_sha", &parsed.buildSha)) {
        return false;
    }

    const auto start = values.find("proof_start_ns");
    if (start == values.end() ||
        !ParseU64(start->second, &parsed.proofStartNs)) {
        return false;
    }

    *request = std::move(parsed);
    return true;
}

bool ParseWitnessRecord(
    const std::string& text,
    WitnessRecord* record) {
    if (record == nullptr) return false;

    std::map<std::string, std::string> values;
    if (!ParseMap(text, &values) || values.size() != 7) return false;

    WitnessRecord parsed;
    if (!Get(values, "schema", &parsed.schema) ||
        !Get(values, "nonce", &parsed.nonce) ||
        !Get(values, "marker", &parsed.marker) ||
        !Get(values, "process", &parsed.process) ||
        !Get(values, "witness_version", &parsed.witnessVersion)) {
        return false;
    }

    const auto pid = values.find("pid");
    const auto observed = values.find("observed_at_ns");
    if (pid == values.end() ||
        observed == values.end() ||
        !ParseInt(pid->second, &parsed.pid) ||
        !ParseU64(observed->second, &parsed.observedAtNs)) {
        return false;
    }

    *record = std::move(parsed);
    return true;
}

ProtocolStatus ValidateRunRequest(
    const RunRequest& request,
    std::uint64_t nowNs,
    std::uint64_t maxAgeNs) {
    if (request.schema != "vcam-pro-gate1-request/1" ||
        request.nonce.size() < 16 ||
        request.runnerVersion.empty() ||
        request.buildSha.empty() ||
        request.proofStartNs == 0 ||
        request.proofStartNs > nowNs) {
        return ProtocolStatus::Malformed;
    }

    if (nowNs - request.proofStartNs > maxAgeNs) {
        return ProtocolStatus::Stale;
    }

    return ProtocolStatus::Ok;
}

ProtocolStatus ValidateWitnessRecord(
    const WitnessRecord& record,
    const std::string& expectedNonce,
    std::uint64_t proofStartNs,
    int currentPid,
    int pidAfter) {
    if (record.schema != "vcam-pro-gate1-witness/1" ||
        record.pid <= 0 ||
        record.observedAtNs == 0 ||
        record.witnessVersion.empty()) {
        return ProtocolStatus::Malformed;
    }

    if (record.nonce != expectedNonce) {
        return ProtocolStatus::WrongNonce;
    }

    if (record.observedAtNs < proofStartNs) {
        return ProtocolStatus::Stale;
    }

    if (record.process != "mediaserverd") {
        return ProtocolStatus::WrongProcess;
    }

    if (record.pid != currentPid ||
        (pidAfter > 0 && record.pid != pidAfter)) {
        return ProtocolStatus::WrongPid;
    }

    if (record.marker != ExpectedMarkerForPid(record.pid)) {
        return ProtocolStatus::WrongMarker;
    }

    return ProtocolStatus::Ok;
}

const char* ProtocolStatusString(ProtocolStatus value) {
    switch (value) {
        case ProtocolStatus::Ok: return "OK";
        case ProtocolStatus::Malformed: return "MALFORMED";
        case ProtocolStatus::WrongNonce: return "WRONG_NONCE";
        case ProtocolStatus::Stale: return "STALE";
        case ProtocolStatus::WrongMarker: return "WRONG_MARKER";
        case ProtocolStatus::WrongProcess: return "WRONG_PROCESS";
        case ProtocolStatus::WrongPid: return "WRONG_PID";
    }
    return "UNKNOWN";
}

}  // namespace vcam::gate1
