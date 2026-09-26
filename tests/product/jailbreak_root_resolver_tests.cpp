#include "JailbreakRootResolver.h"

#include <cerrno>
#include <cstdlib>
#include <fstream>
#include <functional>
#include <iostream>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

namespace {

using vcam::product::ResolveJailbreakRootForImagePath;
using vcam::product::ResolvePathInJailbreakRoot;

int gTests = 0;
int gFailures = 0;

#define CHECK(condition) \
    do { \
        if (!(condition)) { \
            std::cerr << "CHECK failed at " \
                      << __FILE__ << ":" \
                      << __LINE__ << ": " \
                      << #condition << std::endl; \
            return false; \
        } \
    } while (false)

std::string MakeTempRoot() {
    char pattern[] =
        "/tmp/vcam-jbroot-resolver-XXXXXX";
    char* result = mkdtemp(pattern);
    return result == nullptr
        ? std::string{}
        : std::string(result);
}

bool MakeDirectory(
    const std::string& path) {
    if (mkdir(
            path.c_str(),
            0755) == 0) {
        return true;
    }
    return errno == EEXIST;
}

bool EnsurePath(
    const std::string& root,
    const std::string& suffix) {
    std::string current = root;
    std::size_t start = 0;

    while (start < suffix.size()) {
        const std::size_t slash =
            suffix.find('/', start);
        const std::string part =
            suffix.substr(
                start,
                slash == std::string::npos
                    ? std::string::npos
                    : slash - start);

        if (!part.empty()) {
            current += "/" + part;
            if (!MakeDirectory(current)) {
                return false;
            }
        }

        if (slash == std::string::npos) {
            break;
        }
        start = slash + 1;
    }

    return true;
}

void RemoveTree(
    const std::string& root) {
    if (root.empty()) {
        return;
    }
    const std::string command =
        "rm -rf '" + root + "'";
    (void)std::system(command.c_str());
}

bool TestConventionalRootlessModel() {
    const std::string image =
        "/var/jb/usr/lib/TweakInject/VCAMPro.dylib";

    CHECK(
        ResolveJailbreakRootForImagePath(
            image) ==
        "/var/jb");

    CHECK(
        ResolvePathInJailbreakRoot(
            "/var/mobile/Library/Preferences/"
            "com.vcampro.control.plist",
            "/var/jb") ==
        "/var/jb/var/mobile/Library/Preferences/"
        "com.vcampro.control.plist");

    return true;
}

bool TestRandomizedRootHideControlAndMedia() {
    const std::string root =
        MakeTempRoot();
    CHECK(!root.empty());

    const std::string loader =
        root + "/usr/lib/TweakInject";
    CHECK(EnsurePath(
        root,
        "usr/lib/TweakInject"));

    const std::string image =
        loader + "/VCAMPro.dylib";
    {
        std::ofstream file(image);
        file << "probe";
    }

    const std::string jbrootLink =
        loader + "/.jbroot";
    CHECK(
        symlink(
            root.c_str(),
            jbrootLink.c_str()) == 0);

    char canonicalBuffer[PATH_MAX];
    CHECK(
        realpath(
            root.c_str(),
            canonicalBuffer) != nullptr);
    const std::string canonicalRoot =
        canonicalBuffer;

    const std::string resolved =
        ResolveJailbreakRootForImagePath(
            image);
    CHECK(resolved == canonicalRoot);

    CHECK(
        ResolvePathInJailbreakRoot(
            "/var/mobile/Library/Preferences/"
            "com.vcampro.control.plist",
            resolved) ==
        canonicalRoot +
        "/var/mobile/Library/Preferences/"
        "com.vcampro.control.plist");

    CHECK(
        ResolvePathInJailbreakRoot(
            "/var/mobile/Library/VCAMPro/Media",
            resolved) ==
        canonicalRoot +
        "/var/mobile/Library/VCAMPro/Media");

    RemoveTree(root);
    return true;
}

bool TestResolutionFailureFailsOpenToConventional() {
    const std::string resolved =
        ResolveJailbreakRootForImagePath(
            "/unrecognized/location/VCAMPro.dylib");

    CHECK(resolved == "/var/jb");

    CHECK(
        ResolvePathInJailbreakRoot(
            "/var/mobile/Library/VCAMPro/Media",
            resolved) ==
        "/var/jb/var/mobile/Library/VCAMPro/Media");

    return true;
}

bool TestRelativeJoin() {
    CHECK(
        ResolvePathInJailbreakRoot(
            "var/mobile/Library/VCAMPro/Media",
            "/randomized/jbroot") ==
        "/randomized/jbroot/var/mobile/Library/VCAMPro/Media");
    return true;
}

void Run(
    const char* name,
    const std::function<bool()>& test) {
    ++gTests;
    const bool passed = test();
    std::cout
        << (passed ? "PASS " : "FAIL ")
        << name
        << std::endl;
    if (!passed) {
        ++gFailures;
    }
}

}  // namespace

int main() {
    Run(
        "conventional rootless model",
        TestConventionalRootlessModel);
    Run(
        "randomized RootHide control and media paths",
        TestRandomizedRootHideControlAndMedia);
    Run(
        "resolution failure fails open to conventional rootless",
        TestResolutionFailureFailsOpenToConventional);
    Run(
        "relative path join",
        TestRelativeJoin);

    std::cout
        << "Jailbreak root resolver tests run: "
        << gTests
        << ", failures: "
        << gFailures
        << std::endl;

    if (gFailures == 0) {
        std::cout
            << "SHARED_CONTROL_ROOT_RESOLUTION=PASS\n"
            << "SHARED_MEDIA_ROOT_RESOLUTION=PASS\n"
            << "ROOT_RESOLUTION_FAILURE_FAIL_OPEN=PASS\n"
            << "CONVENTIONAL_ROOTLESS_PATH_COMPAT=PASS\n";
    }

    return gFailures == 0 ? 0 : 1;
}
