#pragma once

#include <cstdint>
#include <mutex>

namespace vcam::control {

class SelectionCompletionGate final {
public:
    std::uint64_t beginRequest() {
        std::lock_guard<std::mutex> lock(mutex_);

        ++requestToken_;
        if (requestToken_ == 0) {
            ++requestToken_;
        }

        consumed_ = false;
        fileCompletionClaimed_ = false;
        finalCommitClaimed_ = false;
        return requestToken_;
    }

    bool accept(
        std::uint64_t requestToken) {
        std::lock_guard<std::mutex> lock(mutex_);

        if (requestToken == 0 ||
            requestToken != requestToken_ ||
            consumed_) {
            return false;
        }

        consumed_ = true;
        return true;
    }

    bool claimFileCompletion(
        std::uint64_t requestToken) {
        std::lock_guard<std::mutex> lock(mutex_);

        if (requestToken == 0 ||
            requestToken != requestToken_ ||
            !consumed_ ||
            fileCompletionClaimed_) {
            return false;
        }

        fileCompletionClaimed_ = true;
        return true;
    }

    template <typename CommitAction>
    bool commitIfCurrent(
        std::uint64_t requestToken,
        CommitAction&& commitAction) {
        std::lock_guard<std::mutex> lock(mutex_);

        if (requestToken == 0 ||
            requestToken != requestToken_ ||
            !consumed_ ||
            !fileCompletionClaimed_ ||
            finalCommitClaimed_) {
            return false;
        }

        finalCommitClaimed_ = true;
        return commitAction();
    }

    std::uint64_t currentRequestToken() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return requestToken_;
    }

private:
    mutable std::mutex mutex_;
    std::uint64_t requestToken_ = 0;
    bool consumed_ = false;
    bool fileCompletionClaimed_ = false;
    bool finalCommitClaimed_ = false;
};

}  // namespace vcam::control
