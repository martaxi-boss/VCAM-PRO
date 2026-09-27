#pragma once

#include <stdint.h>

#define VCAM_IOS15_ACTIVATION_PARITY_VERSION \
    "0.1.0+roothide13~activationparity1"

#define VCAM_IOS15_ACTIVATION_PARITY_NOTIFICATION \
    "com.vcampro.gate.ios15-activation-parity.001"
#define VCAM_IOS15_ACTIVATION_PARITY_SELECTION_STATE \
    "com.vcampro.gate.ios15-activation-parity.001.selection"

#define VCAM_IOS15_ACTIVATION_PARITY_FRESHNESS_SECONDS 180U
#define VCAM_IOS15_ACTIVATION_PARITY_FUTURE_SKEW_SECONDS 5U

enum class IOS15ActivationOutput : uint8_t {
    None = 0,
    Original = 1,
    BlackVirtual = 2,
    PhotoVirtual = 3,
};

#define VCAM_ACTIVATION_FLAG_CALLBACK_EXERCISED UINT32_C(0x004)
#define VCAM_ACTIVATION_FLAG_VCAM_ENABLED UINT32_C(0x008)
#define VCAM_ACTIVATION_FLAG_MEDIA_PHOTO UINT32_C(0x010)
#define VCAM_ACTIVATION_FLAG_DECISION_VIRTUAL UINT32_C(0x020)
#define VCAM_ACTIVATION_FLAG_VIRTUAL_NON_NULL UINT32_C(0x040)
#define VCAM_ACTIVATION_FLAG_VIRTUAL_DIFFERENT UINT32_C(0x080)
#define VCAM_ACTIVATION_FLAG_GEOMETRY_MATCH UINT32_C(0x100)
#define VCAM_ACTIVATION_FLAG_SOURCE_BLACK UINT32_C(0x200)
#define VCAM_ACTIVATION_FLAG_SOURCE_MEDIA UINT32_C(0x400)
#define VCAM_ACTIVATION_FLAG_DECISION_ORIGINAL UINT32_C(0x800)

static inline uint64_t
vcam_ios15_activation_parity_encode_state(
    uint32_t timestamp,
    uint32_t pid,
    IOS15ActivationOutput output,
    uint32_t flags)
{
    return
        ((uint64_t)timestamp << 32) |
        ((uint64_t)(pid & UINT32_C(0x000fffff)) << 12) |
        (uint64_t)(flags & UINT32_C(0x00000ffc)) |
        (uint64_t)((uint8_t)output & UINT8_C(0x03));
}

static inline uint32_t
vcam_ios15_activation_parity_timestamp(
    uint64_t state)
{
    return (uint32_t)(state >> 32);
}

static inline uint32_t
vcam_ios15_activation_parity_pid(
    uint64_t state)
{
    return
        (uint32_t)((state >> 12) &
                   UINT64_C(0x000fffff));
}

static inline IOS15ActivationOutput
vcam_ios15_activation_parity_output(
    uint64_t state)
{
    return
        (IOS15ActivationOutput)
            (uint8_t)(state & UINT64_C(0x03));
}

static inline uint32_t
vcam_ios15_activation_parity_flags(
    uint64_t state)
{
    return
        (uint32_t)(state & UINT64_C(0x00000ffc));
}

static inline int
vcam_ios15_activation_parity_state_is_fresh(
    uint64_t state,
    uint32_t now)
{
    const uint32_t timestamp =
        vcam_ios15_activation_parity_timestamp(state);
    const uint32_t pid =
        vcam_ios15_activation_parity_pid(state);
    const IOS15ActivationOutput output =
        vcam_ios15_activation_parity_output(state);

    if (timestamp == 0U ||
        pid == 0U ||
        output == IOS15ActivationOutput::None) {
        return 0;
    }

    if (timestamp > now) {
        return
            (timestamp - now) <=
            VCAM_IOS15_ACTIVATION_PARITY_FUTURE_SKEW_SECONDS;
    }

    return
        (now - timestamp) <=
        VCAM_IOS15_ACTIVATION_PARITY_FRESHNESS_SECONDS;
}

static inline int
vcam_ios15_activation_parity_state_is_valid(
    uint64_t state,
    uint64_t selectionGeneration,
    uint32_t now)
{
    if (!vcam_ios15_activation_parity_state_is_fresh(
            state,
            now)) {
        return 0;
    }

    const IOS15ActivationOutput output =
        vcam_ios15_activation_parity_output(state);
    const uint32_t flags =
        vcam_ios15_activation_parity_flags(state);

    const uint32_t callback =
        VCAM_ACTIVATION_FLAG_CALLBACK_EXERCISED;

    switch (output) {
        case IOS15ActivationOutput::Original:
            return
                (flags & callback) != 0 &&
                (flags & VCAM_ACTIVATION_FLAG_VCAM_ENABLED) == 0 &&
                (flags & VCAM_ACTIVATION_FLAG_DECISION_ORIGINAL) != 0 &&
                (flags & VCAM_ACTIVATION_FLAG_DECISION_VIRTUAL) == 0;

        case IOS15ActivationOutput::BlackVirtual:
            return
                (flags & callback) != 0 &&
                (flags & VCAM_ACTIVATION_FLAG_VCAM_ENABLED) != 0 &&
                (flags & VCAM_ACTIVATION_FLAG_DECISION_VIRTUAL) != 0 &&
                (flags & VCAM_ACTIVATION_FLAG_SOURCE_BLACK) != 0 &&
                (flags & VCAM_ACTIVATION_FLAG_VIRTUAL_NON_NULL) != 0 &&
                (flags & VCAM_ACTIVATION_FLAG_VIRTUAL_DIFFERENT) != 0 &&
                (flags & VCAM_ACTIVATION_FLAG_GEOMETRY_MATCH) != 0;

        case IOS15ActivationOutput::PhotoVirtual:
            return
                selectionGeneration != UINT64_C(0) &&
                (flags & callback) != 0 &&
                (flags & VCAM_ACTIVATION_FLAG_VCAM_ENABLED) != 0 &&
                (flags & VCAM_ACTIVATION_FLAG_MEDIA_PHOTO) != 0 &&
                (flags & VCAM_ACTIVATION_FLAG_DECISION_VIRTUAL) != 0 &&
                (flags & VCAM_ACTIVATION_FLAG_SOURCE_MEDIA) != 0 &&
                (flags & VCAM_ACTIVATION_FLAG_VIRTUAL_NON_NULL) != 0 &&
                (flags & VCAM_ACTIVATION_FLAG_VIRTUAL_DIFFERENT) != 0 &&
                (flags & VCAM_ACTIVATION_FLAG_GEOMETRY_MATCH) != 0;

        case IOS15ActivationOutput::None:
        default:
            return 0;
    }
}
