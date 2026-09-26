#pragma once

namespace vcam::gate1 {

inline constexpr const char* kRunRequestPath =
    "/var/tmp/VCAM_PRO_GATE1_REQUEST.txt";
inline constexpr const char* kWitnessEvidencePath =
    "/var/tmp/VCAM_PRO_GATE1_WITNESS.txt";
inline constexpr const char* kResultDirectory =
    "/var/mobile/Library/VCAMPROGate1";
inline constexpr const char* kResultTextPath =
    "/var/mobile/Library/VCAMPROGate1/VCAM_PRO_GATE1_RESULT.txt";
inline constexpr const char* kResultJsonPath =
    "/var/mobile/Library/VCAMPROGate1/VCAM_PRO_GATE1_RESULT.json";

inline constexpr const char* kRunnerVersion = "0.2.1";
inline constexpr const char* kWitnessVersion = "0.1.0";
inline constexpr const char* kLoadProbePackage = "com.vcampro.loadprobe";
inline constexpr const char* kLoadProbeVersion = "0.0.1";
inline constexpr const char* kLoadProbeDylibPath =
    "/var/jb/usr/lib/TweakInject/VCAMProLoadProbe.dylib";
inline constexpr const char* kLoadProbePlistPath =
    "/var/jb/usr/lib/TweakInject/VCAMProLoadProbe.plist";
inline constexpr const char* kRequiredMarker = "VCAM_PRO_LOAD_PROBE_001";

}  // namespace vcam::gate1
