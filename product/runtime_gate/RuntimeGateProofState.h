#pragma once

#include <stdint.h>

#define VCAM_RUNTIME_GATE_VERSION "0.1.0+roothide4~runtimegate1"
#define VCAM_RUNTIME_GATE_NOTIFICATION     "com.vcampro.gate.mediaserverd-runtime.001"
#define VCAM_RUNTIME_GATE_FRESHNESS_SECONDS 180U
#define VCAM_RUNTIME_GATE_FUTURE_SKEW_SECONDS 5U

#define VCAM_RUNTIME_GATE_FLAG_RUNTIME_START_PASS UINT32_C(0x1)
#define VCAM_RUNTIME_GATE_FLAG_REFERENCE_HOOK_DISABLED UINT32_C(0x2)
#define VCAM_RUNTIME_GATE_REQUIRED_FLAGS     (VCAM_RUNTIME_GATE_FLAG_RUNTIME_START_PASS |      VCAM_RUNTIME_GATE_FLAG_REFERENCE_HOOK_DISABLED)

static inline uint64_t
vcam_runtime_gate_encode_state(
    uint32_t timestamp,
    uint32_t pid)
{
    return
        ((uint64_t)timestamp << 32) |
        ((uint64_t)(pid & UINT32_C(0x3fffffff)) << 2) |
        (uint64_t)VCAM_RUNTIME_GATE_REQUIRED_FLAGS;
}

static inline uint32_t
vcam_runtime_gate_state_timestamp(
    uint64_t state)
{
    return (uint32_t)(state >> 32);
}

static inline uint32_t
vcam_runtime_gate_state_pid(
    uint64_t state)
{
    return
        (uint32_t)((state >> 2) &
                   UINT64_C(0x3fffffff));
}

static inline uint32_t
vcam_runtime_gate_state_flags(
    uint64_t state)
{
    return (uint32_t)(state & UINT64_C(0x3));
}

static inline int
vcam_runtime_gate_state_is_valid_fresh(
    uint64_t state,
    uint32_t now)
{
    const uint32_t timestamp =
        vcam_runtime_gate_state_timestamp(state);
    const uint32_t pid =
        vcam_runtime_gate_state_pid(state);
    const uint32_t flags =
        vcam_runtime_gate_state_flags(state);

    if (timestamp == 0U ||
        pid == 0U ||
        flags != VCAM_RUNTIME_GATE_REQUIRED_FLAGS) {
        return 0;
    }

    if (timestamp > now) {
        return
            (timestamp - now) <=
            VCAM_RUNTIME_GATE_FUTURE_SKEW_SECONDS;
    }

    return
        (now - timestamp) <=
        VCAM_RUNTIME_GATE_FRESHNESS_SECONDS;
}
