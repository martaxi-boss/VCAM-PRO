#pragma once

#include <stdint.h>

#define VCAM_FIRST_LOCAL_PHOTO_VIRTUAL_SUBSTITUTION_VERSION \
    "0.1.0+roothide11~photosub1"

#define VCAM_FIRST_LOCAL_PHOTO_VIRTUAL_SUBSTITUTION_NOTIFICATION \
    "com.vcampro.gate.first-local-photo-virtual-substitution.001"
#define VCAM_FIRST_LOCAL_PHOTO_VIRTUAL_SUBSTITUTION_SELECTION_STATE \
    "com.vcampro.gate.first-local-photo-virtual-substitution.001.selection"

#define VCAM_FIRST_LOCAL_PHOTO_VIRTUAL_SUBSTITUTION_FRESHNESS_SECONDS 180U
#define VCAM_FIRST_LOCAL_PHOTO_VIRTUAL_SUBSTITUTION_FUTURE_SKEW_SECONDS 5U

#define VCAM_FIRST_PHOTO_SUB_FLAG_VCAM_ENABLED UINT32_C(0x001)
#define VCAM_FIRST_PHOTO_SUB_FLAG_MEDIA_PHOTO UINT32_C(0x002)
#define VCAM_FIRST_PHOTO_SUB_FLAG_MEDIA_READY UINT32_C(0x004)
#define VCAM_FIRST_PHOTO_SUB_FLAG_GEOMETRY_OBSERVED UINT32_C(0x008)
#define VCAM_FIRST_PHOTO_SUB_FLAG_CALLBACK_EXERCISED UINT32_C(0x010)
#define VCAM_FIRST_PHOTO_SUB_FLAG_DECISION_VIRTUAL UINT32_C(0x020)
#define VCAM_FIRST_PHOTO_SUB_FLAG_VIRTUAL_NON_NULL UINT32_C(0x040)
#define VCAM_FIRST_PHOTO_SUB_FLAG_VIRTUAL_DIFFERENT UINT32_C(0x080)
#define VCAM_FIRST_PHOTO_SUB_FLAG_GEOMETRY_MATCH UINT32_C(0x100)
#define VCAM_FIRST_PHOTO_SUB_FLAG_VIRTUAL_COUNT_INCREMENT UINT32_C(0x200)
#define VCAM_FIRST_PHOTO_SUB_FLAG_DECISION_COUNT_INCREMENT UINT32_C(0x400)

#define VCAM_FIRST_PHOTO_SUB_REQUIRED_FLAGS \
    (VCAM_FIRST_PHOTO_SUB_FLAG_VCAM_ENABLED | \
     VCAM_FIRST_PHOTO_SUB_FLAG_MEDIA_PHOTO | \
     VCAM_FIRST_PHOTO_SUB_FLAG_MEDIA_READY | \
     VCAM_FIRST_PHOTO_SUB_FLAG_GEOMETRY_OBSERVED | \
     VCAM_FIRST_PHOTO_SUB_FLAG_CALLBACK_EXERCISED | \
     VCAM_FIRST_PHOTO_SUB_FLAG_DECISION_VIRTUAL | \
     VCAM_FIRST_PHOTO_SUB_FLAG_VIRTUAL_NON_NULL | \
     VCAM_FIRST_PHOTO_SUB_FLAG_VIRTUAL_DIFFERENT | \
     VCAM_FIRST_PHOTO_SUB_FLAG_GEOMETRY_MATCH | \
     VCAM_FIRST_PHOTO_SUB_FLAG_VIRTUAL_COUNT_INCREMENT | \
     VCAM_FIRST_PHOTO_SUB_FLAG_DECISION_COUNT_INCREMENT)

static inline uint64_t
vcam_first_photo_substitution_encode_state(
    uint32_t timestamp,
    uint32_t pid,
    uint32_t flags)
{
    return
        ((uint64_t)timestamp << 32) |
        ((uint64_t)(pid & UINT32_C(0x000fffff)) << 12) |
        (uint64_t)(flags & UINT32_C(0x00000fff));
}

static inline uint32_t
vcam_first_photo_substitution_state_timestamp(
    uint64_t state)
{
    return (uint32_t)(state >> 32);
}

static inline uint32_t
vcam_first_photo_substitution_state_pid(
    uint64_t state)
{
    return
        (uint32_t)((state >> 12) &
                   UINT64_C(0x000fffff));
}

static inline uint32_t
vcam_first_photo_substitution_state_flags(
    uint64_t state)
{
    return (uint32_t)(state & UINT64_C(0x00000fff));
}

static inline int
vcam_first_photo_substitution_state_is_valid_fresh(
    uint64_t state,
    uint64_t selectionGeneration,
    uint32_t now)
{
    const uint32_t timestamp =
        vcam_first_photo_substitution_state_timestamp(state);
    const uint32_t pid =
        vcam_first_photo_substitution_state_pid(state);
    const uint32_t flags =
        vcam_first_photo_substitution_state_flags(state);

    if (timestamp == 0U ||
        pid == 0U ||
        selectionGeneration == UINT64_C(0) ||
        flags != VCAM_FIRST_PHOTO_SUB_REQUIRED_FLAGS) {
        return 0;
    }

    if (timestamp > now) {
        return
            (timestamp - now) <=
            VCAM_FIRST_LOCAL_PHOTO_VIRTUAL_SUBSTITUTION_FUTURE_SKEW_SECONDS;
    }

    return
        (now - timestamp) <=
        VCAM_FIRST_LOCAL_PHOTO_VIRTUAL_SUBSTITUTION_FRESHNESS_SECONDS;
}
