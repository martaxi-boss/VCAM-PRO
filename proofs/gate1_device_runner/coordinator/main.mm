#include "Gate1ProofRunner.h"
#include "Gate1Paths.h"
#include "IOSGate1Platform.h"

#include <cerrno>
#include <fstream>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

#ifndef VCAM_GATE1_BUILD_SHA
#define VCAM_GATE1_BUILD_SHA "unknown"
#endif

namespace {

bool EnsureResultDirectory() {
    if (mkdir(vcam::gate1::kResultDirectory, 0755) != 0 &&
        errno != EEXIST) {
        return false;
    }
    (void)chmod(vcam::gate1::kResultDirectory, 0755);
    return true;
}

bool WriteResult(
    const char* path,
    const std::string& value) {
    std::ofstream output(path, std::ios::binary | std::ios::trunc);
    if (!output) return false;
    output.write(value.data(), static_cast<std::streamsize>(value.size()));
    output.close();
    if (!output) return false;
    return chmod(path, 0644) == 0;
}

}  // namespace

int main() {
    using namespace vcam::gate1;

    IOSGate1Platform platform;
    platform.setBuildSha(VCAM_GATE1_BUILD_SHA);

    ProofConfig config;
    config.respawnTimeoutNs = 8ULL * 1000ULL * 1000ULL * 1000ULL;
    config.stabilityWindowNs = 5ULL * 1000ULL * 1000ULL * 1000ULL;
    config.sampleIntervalNs = 250ULL * 1000ULL * 1000ULL;

    Gate1ProofRunner runner(platform, config);
    Evidence evidence = runner.run(VCAM_GATE1_BUILD_SHA);

    const bool resultDirReady = EnsureResultDirectory();
    bool textWritten = false;
    bool jsonWritten = false;
    if (resultDirReady) {
        textWritten =
            WriteResult(
                kResultTextPath,
                Gate1ProofRunner::renderText(evidence));
        jsonWritten =
            WriteResult(
                kResultJsonPath,
                Gate1ProofRunner::renderJson(evidence));
    }

    platform.cleanupActiveRequest();

    return (textWritten && jsonWritten) ? 0 : 2;
}
