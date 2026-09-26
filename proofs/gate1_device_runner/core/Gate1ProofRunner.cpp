#include "Gate1ProofRunner.h"

#include <algorithm>
#include <sstream>

namespace vcam::gate1 {

namespace {

std::string JsonEscape(const std::string& value) {
    std::ostringstream out;
    for (const char c : value) {
        switch (c) {
            case '\\': out << "\\\\"; break;
            case '"': out << "\\\""; break;
            case '\n': out << "\\n"; break;
            case '\r': out << "\\r"; break;
            case '\t': out << "\\t"; break;
            default: out << c; break;
        }
    }
    return out.str();
}

}  // namespace

Gate1ProofRunner::Gate1ProofRunner(
    Platform& platform,
    ProofConfig config)
    : platform_(platform),
      config_(config) {}

Evidence Gate1ProofRunner::run(const std::string& buildSha) {
    Evidence evidence;
    evidence.buildSha = buildSha;
    evidence.proofStartNs = platform_.nowMonotonicNs();
    evidence.device = platform_.deviceInfo();

    state_ = ProofState::CheckingPrerequisites;
    evidence.loadProbe = platform_.queryLoadProbe();

    if (!evidence.loadProbe.installed) {
        return finishNotProven(
            std::move(evidence),
            "LOAD_PROBE_NOT_INSTALLED");
    }

    if (!evidence.loadProbe.dylibPresent ||
        !evidence.loadProbe.plistPresent ||
        !evidence.loadProbe.payloadValid) {
        return finishNotProven(
            std::move(evidence),
            "LOAD_PROBE_PAYLOAD_INVALID");
    }

    state_ = ProofState::ArmingMarkerCapture;
    std::string markerBackend;
    std::string markerError;
    if (!platform_.armMarkerCapture(
            evidence.proofStartNs,
            &evidence.runNonce,
            &markerBackend,
            &markerError)) {
        if (!markerError.empty()) {
            evidence.helperErrors.push_back(markerError);
        }
        evidence.markerCaptureBackend = markerBackend;
        return finishNotProven(
            std::move(evidence),
            "MARKER_CAPTURE_UNAVAILABLE");
    }
    evidence.markerCaptureBackend = markerBackend;

    state_ = ProofState::CapturingPidBefore;
    const ProcessSnapshot before =
        platform_.discoverMediaserverd();
    if (!before.unambiguous || before.pid <= 0) {
        return finishNotProven(
            std::move(evidence),
            "MEDIASERVERD_NOT_UNAMBIGUOUS");
    }

    evidence.pidBefore = before.pid;
    appendPid(&evidence, before.pid);

    state_ = ProofState::RestartRequested;
    std::string restartAction;
    std::string restartError;
    evidence.restartRequestedAtNs =
        platform_.nowMonotonicNs();

    ++evidence.intentionalRestartRequests;
    if (!platform_.requestSingleRestart(
            evidence.pidBefore,
            &restartAction,
            &restartError)) {
        evidence.restartAction = restartAction;
        if (!restartError.empty()) {
            evidence.helperErrors.push_back(restartError);
        }
        return finishNotProven(
            std::move(evidence),
            "RESTART_UNAVAILABLE");
    }
    evidence.restartAction = restartAction;

    state_ = ProofState::WaitingForRespawn;
    const std::uint64_t respawnDeadline =
        evidence.restartRequestedAtNs + config_.respawnTimeoutNs;

    bool respawned = false;
    while (platform_.nowMonotonicNs() < respawnDeadline) {
        const ProcessSnapshot snapshot =
            platform_.discoverMediaserverd();

        if (snapshot.unambiguous && snapshot.pid > 0) {
            appendPid(&evidence, snapshot.pid);
            if (snapshot.pid != evidence.pidBefore) {
                evidence.pidAfter = snapshot.pid;
                respawned = true;
                break;
            }
        }

        captureMarkerIfPresent(&evidence);
        platform_.waitForNs(config_.sampleIntervalNs);
    }

    if (!respawned) {
        return finishUnstable(
            std::move(evidence),
            "MEDIASERVERD_DID_NOT_RESPAWN");
    }

    state_ = ProofState::ObservingMarker;
    captureMarkerIfPresent(&evidence);

    state_ = ProofState::StabilityObservation;
    const std::uint64_t stabilityStart =
        platform_.nowMonotonicNs();
    const std::uint64_t stabilityDeadline =
        stabilityStart + config_.stabilityWindowNs;

    while (platform_.nowMonotonicNs() < stabilityDeadline) {
        const ProcessSnapshot snapshot =
            platform_.discoverMediaserverd();

        if (!snapshot.unambiguous || snapshot.pid <= 0) {
            evidence.restartLoopDetected = true;
            return finishUnstable(
                std::move(evidence),
                "MEDIASERVERD_BECAME_UNAVAILABLE");
        }

        appendPid(&evidence, snapshot.pid);

        if (snapshot.pid != evidence.pidAfter) {
            evidence.restartLoopDetected = true;
            return finishUnstable(
                std::move(evidence),
                "MEDIASERVERD_PID_CHURN");
        }

        captureMarkerIfPresent(&evidence);
        platform_.waitForNs(config_.sampleIntervalNs);
    }

    evidence.stabilityDurationNs =
        platform_.nowMonotonicNs() - stabilityStart;

    if (!evidence.markerFound) {
        return finishNotProven(
            std::move(evidence),
            "MARKER_NOT_OBSERVED");
    }

    if (evidence.markerPid != evidence.pidAfter) {
        return finishNotProven(
            std::move(evidence),
            "MARKER_PID_MISMATCH");
    }

    return finishPass(std::move(evidence));
}

ProofState Gate1ProofRunner::state() const noexcept {
    return state_;
}

std::string Gate1ProofRunner::finalResultString(FinalResult value) {
    switch (value) {
        case FinalResult::Pass:
            return "GATE_1_PASS";
        case FinalResult::FailLoadUnstable:
            return "GATE_1_FAIL_LOAD_UNSTABLE";
        case FinalResult::NotProven:
        default:
            return "GATE_1_NOT_PROVEN";
    }
}

std::string Gate1ProofRunner::stateString(ProofState value) {
    switch (value) {
        case ProofState::Idle: return "Idle";
        case ProofState::CheckingPrerequisites: return "CheckingPrerequisites";
        case ProofState::ArmingMarkerCapture: return "ArmingMarkerCapture";
        case ProofState::CapturingPidBefore: return "CapturingPidBefore";
        case ProofState::RestartRequested: return "RestartRequested";
        case ProofState::WaitingForRespawn: return "WaitingForRespawn";
        case ProofState::ObservingMarker: return "ObservingMarker";
        case ProofState::StabilityObservation: return "StabilityObservation";
        case ProofState::CompletedPass: return "CompletedPass";
        case ProofState::CompletedNotProven: return "CompletedNotProven";
        case ProofState::CompletedUnstable: return "CompletedUnstable";
    }
    return "Unknown";
}

std::string Gate1ProofRunner::renderText(const Evidence& evidence) {
    std::ostringstream out;
    out << finalResultString(evidence.finalResult) << "\n";
    out << "reason=" << evidence.reasonCode << "\n";
    out << "state=" << stateString(evidence.finalState) << "\n";
    out << "device_os=" << evidence.device.osVersion << "\n";
    out << "device_machine=" << evidence.device.machine << "\n";
    out << "device_architecture=" << evidence.device.architecture << "\n";
    out << "runner_version=" << evidence.runnerVersion << "\n";
    out << "build_sha=" << evidence.buildSha << "\n";
    out << "run_nonce=" << evidence.runNonce << "\n";
    out << "load_probe=" << evidence.loadProbe.packageId
        << " version=" << evidence.loadProbe.version << "\n";
    out << "package_query_method=" << evidence.loadProbe.queryMethod << "\n";
    out << "dylib_present=" << (evidence.loadProbe.dylibPresent ? "YES" : "NO") << "\n";
    out << "plist_present=" << (evidence.loadProbe.plistPresent ? "YES" : "NO") << "\n";
    out << "payload_valid=" << (evidence.loadProbe.payloadValid ? "YES" : "NO") << "\n";
    out << "pid_before=" << evidence.pidBefore << "\n";
    out << "pid_after=" << evidence.pidAfter << "\n";
    out << "intentional_restart_requests=" << evidence.intentionalRestartRequests << "\n";
    out << "restart_action=" << evidence.restartAction << "\n";
    out << "marker_found=" << (evidence.markerFound ? "YES" : "NO") << "\n";
    out << "marker_text=" << evidence.markerText << "\n";
    out << "marker_pid=" << evidence.markerPid << "\n";
    out << "marker_capture_backend=" << evidence.markerCaptureBackend << "\n";
    out << "restart_loop_detected=" << (evidence.restartLoopDetected ? "YES" : "NO") << "\n";
    out << "stability_duration_ns=" << evidence.stabilityDurationNs << "\n";
    out << "gate2_attempted=NO\n";
    return out.str();
}

std::string Gate1ProofRunner::renderJson(const Evidence& evidence) {
    std::ostringstream out;
    out << "{";
    out << "\"schema\":\"" << JsonEscape(evidence.schema) << "\",";
    out << "\"runner_version\":\"" << JsonEscape(evidence.runnerVersion) << "\",";
    out << "\"build_sha\":\"" << JsonEscape(evidence.buildSha) << "\",";
    out << "\"run_nonce\":\"" << JsonEscape(evidence.runNonce) << "\",";
    out << "\"final_result\":\"" << finalResultString(evidence.finalResult) << "\",";
    out << "\"reason_code\":\"" << JsonEscape(evidence.reasonCode) << "\",";
    out << "\"final_state\":\"" << stateString(evidence.finalState) << "\",";
    out << "\"device_os\":\"" << JsonEscape(evidence.device.osVersion) << "\",";
    out << "\"device_machine\":\"" << JsonEscape(evidence.device.machine) << "\",";
    out << "\"device_architecture\":\"" << JsonEscape(evidence.device.architecture) << "\",";
    out << "\"load_probe_package\":\"" << JsonEscape(evidence.loadProbe.packageId) << "\",";
    out << "\"load_probe_version\":\"" << JsonEscape(evidence.loadProbe.version) << "\",";
    out << "\"load_probe_query_method\":\"" << JsonEscape(evidence.loadProbe.queryMethod) << "\",";
    out << "\"load_probe_payload_valid\":" << (evidence.loadProbe.payloadValid ? "true" : "false") << ",";
    out << "\"proof_start_ns\":" << evidence.proofStartNs << ",";
    out << "\"proof_end_ns\":" << evidence.proofEndNs << ",";
    out << "\"pid_before\":" << evidence.pidBefore << ",";
    out << "\"pid_after\":" << evidence.pidAfter << ",";
    out << "\"pid_history\":[";
    for (std::size_t i = 0; i < evidence.pidHistory.size(); ++i) {
        if (i != 0) out << ",";
        out << evidence.pidHistory[i];
    }
    out << "],";
    out << "\"intentional_restart_requests\":" << evidence.intentionalRestartRequests << ",";
    out << "\"restart_action\":\"" << JsonEscape(evidence.restartAction) << "\",";
    out << "\"restart_requested_at_ns\":" << evidence.restartRequestedAtNs << ",";
    out << "\"marker_found\":" << (evidence.markerFound ? "true" : "false") << ",";
    out << "\"marker_text\":\"" << JsonEscape(evidence.markerText) << "\",";
    out << "\"marker_pid\":" << evidence.markerPid << ",";
    out << "\"marker_capture_backend\":\"" << JsonEscape(evidence.markerCaptureBackend) << "\",";
    out << "\"stability_duration_ns\":" << evidence.stabilityDurationNs << ",";
    out << "\"restart_loop_detected\":" << (evidence.restartLoopDetected ? "true" : "false") << ",";
    out << "\"helper_errors\":[";
    for (std::size_t i = 0; i < evidence.helperErrors.size(); ++i) {
        if (i != 0) out << ",";
        out << "\"" << JsonEscape(evidence.helperErrors[i]) << "\"";
    }
    out << "],";
    out << "\"gate2_attempted\":false";
    out << "}";
    return out.str();
}

Evidence Gate1ProofRunner::finishNotProven(
    Evidence evidence,
    const std::string& reason) {
    state_ = ProofState::CompletedNotProven;
    evidence.finalState = state_;
    evidence.finalResult = FinalResult::NotProven;
    evidence.reasonCode = reason;
    evidence.proofEndNs = platform_.nowMonotonicNs();
    return evidence;
}

Evidence Gate1ProofRunner::finishUnstable(
    Evidence evidence,
    const std::string& reason) {
    state_ = ProofState::CompletedUnstable;
    evidence.finalState = state_;
    evidence.finalResult = FinalResult::FailLoadUnstable;
    evidence.reasonCode = reason;
    evidence.proofEndNs = platform_.nowMonotonicNs();
    return evidence;
}

Evidence Gate1ProofRunner::finishPass(Evidence evidence) {
    state_ = ProofState::CompletedPass;
    evidence.finalState = state_;
    evidence.finalResult = FinalResult::Pass;
    evidence.reasonCode = "MARKER_OBSERVED_AND_STABLE";
    evidence.proofEndNs = platform_.nowMonotonicNs();
    return evidence;
}

void Gate1ProofRunner::appendPid(
    Evidence* evidence,
    int pid) const {
    if (evidence == nullptr || pid <= 0) return;
    if (evidence->pidHistory.empty() ||
        evidence->pidHistory.back() != pid) {
        evidence->pidHistory.push_back(pid);
    }
}

bool Gate1ProofRunner::captureMarkerIfPresent(Evidence* evidence) {
    if (evidence == nullptr || evidence->markerFound) {
        return evidence != nullptr && evidence->markerFound;
    }

    const MarkerObservation marker =
        platform_.pollMarker(evidence->proofStartNs);

    if (!marker.error.empty()) {
        evidence->helperErrors.push_back(marker.error);
    }

    if (!marker.found) return false;
    if (marker.observedAtNs < evidence->proofStartNs) return false;

    if (marker.runNonce != evidence->runNonce) {
        evidence->helperErrors.push_back("witness nonce mismatch");
        return false;
    }

    if (marker.process != "mediaserverd") {
        evidence->helperErrors.push_back("witness process mismatch");
        return false;
    }

    evidence->markerFound = true;
    evidence->markerText = marker.text;
    evidence->markerPid = marker.pid;
    return true;
}

}  // namespace vcam::gate1
