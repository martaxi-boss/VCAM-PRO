#include "ProductControlOwner.h"

#include <limits>
#include <utility>

namespace vcam::product {

ProductControlOwner::ProductControlOwner(
    std::string controlPath,
    std::string notificationName,
    std::string mediaDirectory)
    : store_(
          std::move(controlPath),
          std::move(notificationName)),
      stager_(
          std::move(mediaDirectory)) {
    (void)reload();
}

bool ProductControlOwner::reload() {
    ProductControlSnapshot snapshot;
    if (!store_.load(&snapshot)) {
        std::lock_guard<std::mutex>
            lock(mutex_);
        lastStatus_ =
            "Unable to read VCAM control state.";
        return false;
    }

    std::lock_guard<std::mutex>
        lock(mutex_);
    current_ = std::move(snapshot);
    lastStatus_ =
        current_.hasMedia()
            ? "Existing local media loaded."
            : "No media selected.";
    return true;
}

ProductControlSnapshot
ProductControlOwner::snapshot() const {
    std::lock_guard<std::mutex>
        lock(mutex_);
    return current_;
}

bool ProductControlOwner::setEnabled(
    bool enabled) {
    ProductControlSnapshot next;
    {
        std::lock_guard<std::mutex>
            lock(mutex_);
        next = current_;
    }

    next.enabled = enabled;

    if (!store_.save(next)) {
        std::lock_guard<std::mutex>
            lock(mutex_);
        lastStatus_ =
            "Unable to update VCAM enabled state.";
        return false;
    }

    {
        std::lock_guard<std::mutex>
            lock(mutex_);
        current_ = next;
        lastStatus_ =
            enabled
                ? "VCAM ON."
                : "VCAM OFF — real camera fail-open.";
    }

    return true;
}

bool ProductControlOwner::selectFromTemporaryPath(
    const std::string& temporarySourcePath,
    ProductMediaKind kind,
    std::string* errorMessage) {
    return selectFromTemporaryPath(
        temporarySourcePath,
        kind,
        CommitGate{},
        errorMessage);
}

bool ProductControlOwner::selectFromTemporaryPath(
    const std::string& temporarySourcePath,
    ProductMediaKind kind,
    const CommitGate& commitGate,
    std::string* errorMessage) {
    ProductControlSnapshot before;
    {
        std::lock_guard<std::mutex>
            lock(mutex_);
        before = current_;
    }

    const std::uint64_t generation =
        nextGeneration(
            before.selectionGeneration);

    std::string stagedPath;
    std::string stagingError;
    if (!stager_.stageAndValidate(
            temporarySourcePath,
            kind,
            generation,
            &stagedPath,
            &stagingError)) {
        {
            std::lock_guard<std::mutex>
                lock(mutex_);
            lastStatus_ =
                stagingError.empty()
                    ? "Media candidate rejected."
                    : stagingError;
        }

        if (errorMessage != nullptr) {
            *errorMessage =
                stagingError;
        }
        return false;
    }

    ProductControlSnapshot next =
        before;
    next.mediaKind = kind;
    next.mediaPath = stagedPath;
    next.selectionGeneration =
        generation;
    next.playbackIntent =
        ProductPlaybackIntent::Playing;

    if (kind ==
        ProductMediaKind::Photo) {
        next.loopEnabled = false;
    }

    bool commitAttempted = false;

    const CommitAction commitAction =
        [&]() {
            commitAttempted = true;
            return commit(
                next,
                before.mediaPath,
                stagedPath);
        };

    const bool committed =
        commitGate
            ? commitGate(commitAction)
            : commitAction();

    if (!committed) {
        if (!commitAttempted) {
            (void)stager_.removeOwnedPath(
                stagedPath);

            const std::string superseded =
                "Media selection superseded by newer request.";

            {
                std::lock_guard<std::mutex>
                    lock(mutex_);
                lastStatus_ =
                    superseded;
            }

            if (errorMessage != nullptr) {
                *errorMessage =
                    superseded;
            }
        } else if (
            errorMessage != nullptr) {
            *errorMessage =
                "Unable to commit staged media.";
        }

        return false;
    }

    {
        std::lock_guard<std::mutex>
            lock(mutex_);
        lastStatus_ =
            kind == ProductMediaKind::Video
                ? "Local video selected."
                : "Local photo selected.";
    }

    if (errorMessage != nullptr) {
        errorMessage->clear();
    }

    return true;
}

bool ProductControlOwner::clearMedia() {
    ProductControlSnapshot before;
    {
        std::lock_guard<std::mutex>
            lock(mutex_);
        before = current_;
    }

    ProductControlSnapshot next =
        before;
    next.mediaKind =
        ProductMediaKind::None;
    next.mediaPath.clear();
    next.selectionGeneration =
        nextGeneration(
            before.selectionGeneration);
    next.loopEnabled = false;
    next.playbackIntent =
        ProductPlaybackIntent::Stopped;

    if (!commit(
            next,
            before.mediaPath,
            {})) {
        return false;
    }

    std::lock_guard<std::mutex>
        lock(mutex_);
    lastStatus_ =
        "Media cleared.";
    return true;
}

bool ProductControlOwner::setLoopEnabled(
    bool enabled) {
    ProductControlSnapshot next;
    {
        std::lock_guard<std::mutex>
            lock(mutex_);
        next = current_;
    }

    if (next.mediaKind !=
        ProductMediaKind::Video) {
        std::lock_guard<std::mutex>
            lock(mutex_);
        lastStatus_ =
            "Loop applies only to video.";
        return false;
    }

    next.loopEnabled = enabled;
    if (!store_.save(next)) {
        return false;
    }

    std::lock_guard<std::mutex>
        lock(mutex_);
    current_ = next;
    lastStatus_ =
        enabled
            ? "Video loop enabled."
            : "Video loop disabled.";
    return true;
}

bool ProductControlOwner::setPlaybackIntent(
    ProductPlaybackIntent intent) {
    ProductControlSnapshot next;
    {
        std::lock_guard<std::mutex>
            lock(mutex_);
        next = current_;
    }

    if (!next.hasMedia()) {
        std::lock_guard<std::mutex>
            lock(mutex_);
        lastStatus_ =
            "Select media before playback.";
        return false;
    }

    next.playbackIntent = intent;
    if (!store_.save(next)) {
        return false;
    }

    std::lock_guard<std::mutex>
        lock(mutex_);
    current_ = next;

    switch (intent) {
        case ProductPlaybackIntent::Playing:
            lastStatus_ =
                "Playback requested.";
            break;
        case ProductPlaybackIntent::Paused:
            lastStatus_ =
                "Playback paused.";
            break;
        case ProductPlaybackIntent::Stopped:
            lastStatus_ =
                "Playback stopped.";
            break;
    }

    return true;
}

const std::string&
ProductControlOwner::lastStatus() const noexcept {
    return lastStatus_;
}

const std::string&
ProductControlOwner::mediaDirectory() const noexcept {
    return stager_.mediaDirectory();
}

bool ProductControlOwner::commit(
    const ProductControlSnapshot& next,
    const std::string& oldPath,
    const std::string& newPathOnFailure) {
    if (!store_.save(next)) {
        if (!newPathOnFailure.empty()) {
            stager_.removeOwnedPath(
                newPathOnFailure);
        }

        std::lock_guard<std::mutex>
            lock(mutex_);
        lastStatus_ =
            "Unable to persist VCAM control state.";
        return false;
    }

    {
        std::lock_guard<std::mutex>
            lock(mutex_);
        current_ = next;
    }

    if (!oldPath.empty() &&
        oldPath != next.mediaPath) {
        stager_.removeOwnedPath(
            oldPath);
    }

    return true;
}

std::uint64_t
ProductControlOwner::nextGeneration(
    std::uint64_t current) noexcept {
    if (current ==
        std::numeric_limits<
            std::uint64_t>::max()) {
        return 1;
    }
    return current + 1;
}

}  // namespace vcam::product
