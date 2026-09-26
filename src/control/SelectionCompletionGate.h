#pragma once
#include <cstdint>
namespace vcam::control {
class SelectionCompletionGate final {
public:
    std::uint64_t beginRequest() noexcept {
        ++requestToken_;
        if (requestToken_ == 0) ++requestToken_;
        consumed_ = false;
        return requestToken_;
    }
    bool accept(std::uint64_t requestToken) noexcept {
        if (requestToken == 0 || requestToken != requestToken_ || consumed_) {
            return false;
        }
        consumed_ = true;
        return true;
    }
    std::uint64_t currentRequestToken() const noexcept {
        return requestToken_;
    }
private:
    std::uint64_t requestToken_ = 0;
    bool consumed_ = false;
};
}  // namespace vcam::control
