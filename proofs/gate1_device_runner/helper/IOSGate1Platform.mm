#import <Foundation/Foundation.h>

#include "IOSGate1Platform.h"
#include "Gate1Paths.h"
#include "WitnessProtocol.h"

#include <arpa/inet.h>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <mach/mach_time.h>
#include <signal.h>
#include <sstream>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/utsname.h>
#include <unistd.h>
#include <vector>

namespace vcam::gate1 {
namespace {

std::uint64_t MonotonicNs() {
    static mach_timebase_info_data_t info = [] {
        mach_timebase_info_data_t value{};
        (void)mach_timebase_info(&value);
        return value;
    }();

    const std::uint64_t ticks = mach_absolute_time();
    return (ticks * info.numer) / info.denom;
}

bool ReadFile(const char* path, std::string* value) {
    if (value == nullptr) return false;
    std::ifstream input(path, std::ios::binary);
    if (!input) return false;
    std::ostringstream out;
    out << input.rdbuf();
    *value = out.str();
    return true;
}

bool WriteFile(
    const char* path,
    const std::string& value,
    mode_t mode) {
    std::ofstream output(path, std::ios::binary | std::ios::trunc);
    if (!output) return false;
    output.write(value.data(), static_cast<std::streamsize>(value.size()));
    output.close();
    if (!output) return false;
    return chmod(path, mode) == 0;
}

bool RegularNonEmptyFile(const char* path) {
    struct stat st {};
    return stat(path, &st) == 0 &&
           S_ISREG(st.st_mode) &&
           st.st_size > 0;
}

std::string RandomNonce() {
    unsigned char bytes[16] = {};
    arc4random_buf(bytes, sizeof(bytes));

    static constexpr char kHex[] = "0123456789abcdef";
    std::string out;
    out.reserve(sizeof(bytes) * 2);
    for (unsigned char byte : bytes) {
        out.push_back(kHex[(byte >> 4) & 0x0f]);
        out.push_back(kHex[byte & 0x0f]);
    }
    return out;
}

bool ParseInstalledPackage(
    const std::string& status,
    const std::string& package,
    std::string* version) {
    std::istringstream input(status);
    std::string line;
    bool inTarget = false;
    bool installed = false;
    std::string foundVersion;

    auto finishParagraph = [&]() -> bool {
        if (inTarget && installed && !foundVersion.empty()) {
            if (version != nullptr) *version = foundVersion;
            return true;
        }
        inTarget = false;
        installed = false;
        foundVersion.clear();
        return false;
    };

    while (std::getline(input, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty()) {
            if (finishParagraph()) return true;
            continue;
        }

        constexpr const char* kPackage = "Package: ";
        constexpr const char* kVersion = "Version: ";
        constexpr const char* kStatus = "Status: ";

        if (line.rfind(kPackage, 0) == 0) {
            inTarget = line.substr(strlen(kPackage)) == package;
        } else if (inTarget && line.rfind(kVersion, 0) == 0) {
            foundVersion = line.substr(strlen(kVersion));
        } else if (inTarget && line.rfind(kStatus, 0) == 0) {
            installed =
                line.substr(strlen(kStatus)) == "install ok installed";
        }
    }

    return finishParagraph();
}

bool LoadProbePlistIsExpected() {
    @autoreleasepool {
        NSDictionary* plist =
            [NSDictionary dictionaryWithContentsOfFile:
                @(kLoadProbePlistPath)];
        if (plist == nil) return false;

        NSDictionary* filter = plist[@"Filter"];
        NSArray* executables = filter[@"Executables"];
        return [executables isKindOfClass:[NSArray class]] &&
               executables.count == 1 &&
               [executables[0] isEqualToString:@"mediaserverd"];
    }
}

}  // namespace

struct IOSGate1Platform::Impl {
    std::string runNonce;
    std::uint64_t proofStartNs = 0;
    std::string buildSha;
    bool restartIssued = false;
};

IOSGate1Platform::IOSGate1Platform()
    : impl_(std::make_unique<Impl>()) {}

IOSGate1Platform::~IOSGate1Platform() = default;

std::uint64_t IOSGate1Platform::nowMonotonicNs() {
    return MonotonicNs();
}

void IOSGate1Platform::waitForNs(std::uint64_t durationNs) {
    struct timespec request {};
    request.tv_sec =
        static_cast<time_t>(durationNs / 1000000000ULL);
    request.tv_nsec =
        static_cast<long>(durationNs % 1000000000ULL);
    while (nanosleep(&request, &request) != 0 &&
           errno == EINTR) {
    }
}

DeviceInfo IOSGate1Platform::deviceInfo() {
    DeviceInfo info;

    @autoreleasepool {
        NSOperatingSystemVersion version =
            NSProcessInfo.processInfo.operatingSystemVersion;
        info.osVersion =
            std::to_string(version.majorVersion) + "." +
            std::to_string(version.minorVersion) + "." +
            std::to_string(version.patchVersion);
    }

    struct utsname uts {};
    if (uname(&uts) == 0) {
        info.machine = uts.machine;
    }
    info.architecture = "arm64";
    return info;
}

PackageProbe IOSGate1Platform::queryLoadProbe() {
    PackageProbe probe;
    probe.packageId = kLoadProbePackage;

    const char* candidates[] = {
        "/var/jb/var/lib/dpkg/status",
        "/var/lib/dpkg/status",
    };

    for (const char* path : candidates) {
        std::string status;
        if (!ReadFile(path, &status)) continue;

        std::string version;
        if (ParseInstalledPackage(
                status,
                kLoadProbePackage,
                &version)) {
            probe.installed = true;
            probe.version = version;
            probe.queryMethod =
                std::string("dpkg-status-file:") + path;
            break;
        }
    }

    probe.dylibPresent =
        RegularNonEmptyFile(kLoadProbeDylibPath);
    probe.plistPresent =
        RegularNonEmptyFile(kLoadProbePlistPath);

    probe.payloadValid =
        probe.installed &&
        probe.version == kLoadProbeVersion &&
        probe.dylibPresent &&
        probe.plistPresent &&
        LoadProbePlistIsExpected();

    return probe;
}

bool IOSGate1Platform::armMarkerCapture(
    std::uint64_t proofStartNs,
    std::string* runNonce,
    std::string* backend,
    std::string* error) {
    (void)unlink(kWitnessEvidencePath);

    impl_->runNonce = RandomNonce();
    impl_->proofStartNs = proofStartNs;
    impl_->restartIssued = false;

    RunRequest request;
    request.schema = "vcam-pro-gate1-request/1";
    request.nonce = impl_->runNonce;
    request.proofStartNs = proofStartNs;
    request.runnerVersion = kRunnerVersion;
    request.buildSha = impl_->buildSha;

    const std::string rendered = RenderRunRequest(request);
    if (rendered.empty() ||
        !WriteFile(kRunRequestPath, rendered, 0644)) {
        if (error != nullptr) {
            *error = "failed to create Gate 1 run request";
        }
        return false;
    }

    if (runNonce != nullptr) {
        *runNonce = impl_->runNonce;
    }
    if (backend != nullptr) {
        *backend =
            "mediaserverd-local OSLogStoreCurrentProcessIdentifier witness";
    }
    return true;
}

ProcessSnapshot IOSGate1Platform::discoverMediaserverd() {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size = 0;
    if (sysctl(mib, 4, nullptr, &size, nullptr, 0) != 0 ||
        size == 0) {
        return {};
    }

    std::vector<unsigned char> storage(size);
    if (sysctl(
            mib,
            4,
            storage.data(),
            &size,
            nullptr,
            0) != 0) {
        return {};
    }

    const size_t count = size / sizeof(kinfo_proc);
    const kinfo_proc* processes =
        reinterpret_cast<const kinfo_proc*>(storage.data());

    int foundPid = -1;
    int matches = 0;
    for (size_t i = 0; i < count; ++i) {
        const kinfo_proc& process = processes[i];
        if (strcmp(
                process.kp_proc.p_comm,
                "mediaserverd") == 0) {
            ++matches;
            foundPid = process.kp_proc.p_pid;
        }
    }

    return {
        matches == 1 && foundPid > 0,
        matches == 1 ? foundPid : -1,
    };
}

bool IOSGate1Platform::requestSingleRestart(
    int pid,
    std::string* action,
    std::string* error) {
    if (action != nullptr) {
        *action = "SIGTERM_EXACT_PID";
    }
    if (impl_->restartIssued) {
        if (error != nullptr) *error = "duplicate restart blocked";
        return false;
    }
    impl_->restartIssued = true;

    if (pid <= 0) {
        if (error != nullptr) *error = "invalid PID";
        return false;
    }
    if (kill(pid, SIGTERM) != 0) {
        if (error != nullptr) {
            *error =
                std::string("SIGTERM failed errno=") +
                std::to_string(errno);
        }
        return false;
    }
    return true;
}

MarkerObservation IOSGate1Platform::pollMarker(
    std::uint64_t proofStartNs) {
    MarkerObservation observation;

    std::string text;
    if (!ReadFile(kWitnessEvidencePath, &text)) {
        return observation;
    }

    WitnessRecord record;
    if (!ParseWitnessRecord(text, &record)) {
        observation.error = "malformed witness evidence";
        return observation;
    }

    observation.runNonce = record.nonce;
    observation.text = record.marker;
    observation.process = record.process;
    observation.pid = record.pid;
    observation.observedAtNs = record.observedAtNs;

    if (record.observedAtNs < proofStartNs) {
        observation.error = "stale witness evidence";
        return observation;
    }

    observation.found = true;
    return observation;
}

void IOSGate1Platform::setBuildSha(
    const std::string& buildSha) {
    impl_->buildSha = buildSha;
}

void IOSGate1Platform::cleanupActiveRequest() {
    (void)unlink(kRunRequestPath);
    (void)unlink(kWitnessEvidencePath);
}

}  // namespace vcam::gate1
