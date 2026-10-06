#pragma once

namespace vcam::media_engine {

// Shared across translation units, isolated to the decoding thread. Camera
// callbacks on other threads must continue to own their output while VCAM is ON.
inline thread_local bool localSourceAccessActive = false;

class ScopedLocalSourceAccess final {
public:
    ScopedLocalSourceAccess() noexcept
        : previous_(localSourceAccessActive) {
        localSourceAccessActive = true;
    }
    ~ScopedLocalSourceAccess() {
        localSourceAccessActive = previous_;
    }
    ScopedLocalSourceAccess(const ScopedLocalSourceAccess&) = delete;
    ScopedLocalSourceAccess& operator=(const ScopedLocalSourceAccess&) = delete;

private:
    bool previous_;
};

inline bool IsLocalSourceAccessActive() noexcept {
    return localSourceAccessActive;
}

}  // namespace vcam::media_engine
