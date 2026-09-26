#pragma once

#include <dlfcn.h>
#include <limits.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstdlib>
#include <string>

namespace vcam::product {

namespace jailbreak_root_detail {

inline const char kResolverImageAnchor = 0;

inline std::string ParentDirectory(
    const std::string& path) {
    const std::size_t separator =
        path.find_last_of('/');

    if (separator ==
        std::string::npos) {
        return {};
    }

    if (separator == 0) {
        return "/";
    }

    return path.substr(
        0,
        separator);
}

inline bool IsDirectory(
    const std::string& path) {
    struct stat info {};
    return
        !path.empty() &&
        stat(
            path.c_str(),
            &info) == 0 &&
        S_ISDIR(info.st_mode);
}

inline std::string RealPath(
    const std::string& path) {
    if (path.empty()) {
        return {};
    }

    char resolved[PATH_MAX];
    if (realpath(
            path.c_str(),
            resolved) == nullptr) {
        return {};
    }

    return std::string(resolved);
}

inline std::string PrefixBeforePlacement(
    const std::string& imagePath) {
    constexpr const char*
        kTweakInject =
            "/usr/lib/TweakInject/";
    constexpr const char*
        kMobileSubstrate =
            "/Library/MobileSubstrate/"
            "DynamicLibraries/";

    for (const char* marker : {
             kTweakInject,
             kMobileSubstrate}) {
        const std::size_t position =
            imagePath.rfind(marker);

        if (position ==
                std::string::npos ||
            position == 0) {
            continue;
        }

        return imagePath.substr(
            0,
            position);
    }

    return {};
}

inline std::string NormalizeFallback(
    const std::string& fallback) {
    return fallback.empty()
        ? std::string("/var/jb")
        : fallback;
}

}  // namespace jailbreak_root_detail

inline std::string
ResolveJailbreakRootForImagePath(
    const std::string& imagePath,
    const std::string& fallback =
        "/var/jb") {
    const std::string safeFallback =
        jailbreak_root_detail::
            NormalizeFallback(
                fallback);

    if (imagePath.empty()) {
        return safeFallback;
    }

    const std::string canonicalImage =
        jailbreak_root_detail::RealPath(
            imagePath);

    const std::string effectiveImage =
        canonicalImage.empty()
            ? imagePath
            : canonicalImage;

    const std::string loaderDirectory =
        jailbreak_root_detail::
            ParentDirectory(
                effectiveImage);

    if (!loaderDirectory.empty()) {
        const std::string loaderRoot =
            loaderDirectory +
            "/.jbroot";

        const std::string resolvedRoot =
            jailbreak_root_detail::
                RealPath(
                    loaderRoot);

        if (jailbreak_root_detail::
                IsDirectory(
                    resolvedRoot)) {
            return resolvedRoot;
        }
    }

    const std::string placementRoot =
        jailbreak_root_detail::
            PrefixBeforePlacement(
                effectiveImage);

    if (jailbreak_root_detail::
            IsDirectory(
                placementRoot) ||
        (!placementRoot.empty() &&
         effectiveImage.find(
             "/usr/lib/TweakInject/") !=
             std::string::npos) ||
        (!placementRoot.empty() &&
         effectiveImage.find(
             "/Library/MobileSubstrate/"
             "DynamicLibraries/") !=
             std::string::npos)) {
        return placementRoot;
    }

    return safeFallback;
}

inline std::string
ResolveRuntimeJailbreakRoot() {
    Dl_info info {};

    if (dladdr(
            static_cast<const void*>(
                &jailbreak_root_detail::
                    kResolverImageAnchor),
            &info) == 0 ||
        info.dli_fname == nullptr) {
        return "/var/jb";
    }

    return
        ResolveJailbreakRootForImagePath(
            info.dli_fname);
}

inline std::string
ResolvePathInJailbreakRoot(
    const std::string& rootRelativePath,
    const std::string& jailbreakRoot =
        ResolveRuntimeJailbreakRoot()) {
    if (rootRelativePath.empty()) {
        return jailbreakRoot;
    }

    if (jailbreakRoot.empty()) {
        return rootRelativePath;
    }

    if (rootRelativePath.front() == '/') {
        return
            jailbreakRoot +
            rootRelativePath;
    }

    return
        jailbreakRoot +
        "/" +
        rootRelativePath;
}

}  // namespace vcam::product
