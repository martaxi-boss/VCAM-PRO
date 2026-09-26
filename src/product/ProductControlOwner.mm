#include "ProductControlOwner.h"

#include <limits>
#include <utility>

namespace vcam::product {

namespace {

bool SameMediaIdentity(
    const ProductControlSnapshot& left,
    const ProductControlSnapshot& right) noexcept {
    return
        left.mediaKind ==
            right.mediaKind &&
        left.mediaPath ==
            right.mediaPath &&
        left.selectionGeneration ==
            right.selectionGeneration;
}

}  // namespace

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
    std::lock_guard<std::mutex>
        lock(mutex_);

    ProductControlSnapshot snapshot;
    if (!store_.load(&snapshot)) {
        lastStatus_ =
            "Unable to read VCAM control state.";
        return false;
    }

    current_ = std::move(snapshot);
    playbackIntentRevision_ =
        nextGeneration(
            playbackIntentRevision_);
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
    std::lock_guard<std::mutex>
        lock(mutex_);

    ProductControlSnapshot next =
        current_;
    next.enabled = enabled;

    if (!store_.save(next)) {
        lastStatus_ =
            "Unable to update VCAM enabled state.";
        return false;
    }

    current_ = next;
    lastStatus_ =
        enabled
            ? "VCAM ON."
            : "VCAM OFF — real camera fail-open.";
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
    std::uint64_t
        startPlaybackIntentRevision = 0;

    {
        std::lock_guard<std::mutex>
            lock(mutex_);
        before = current_;
        startPlaybackIntentRevision =
            playbackIntentRevision_;
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

    bool commitActionInvoked = false;
    bool mediaIdentityRejected = false;
    bool persistenceFailed = false;
    bool ownerCommitted = false;
    std::string oldPathToRemove;

    const CommitAction commitAction =
        [&]() {
            commitActionInvoked = true;

            std::lock_guard<std::mutex>
                lock(mutex_);

            if (!SameMediaIdentity(
                    current_,
                    before)) {
                mediaIdentityRejected = true;
                lastStatus_ =
                    "Media selection superseded by newer media state.";
                return false;
            }

            ProductControlSnapshot next =
                current_;

            oldPathToRemove =
                current_.mediaPath;

            next.mediaKind = kind;
            next.mediaPath = stagedPath;
            next.selectionGeneration =
                generation;

            if (kind ==
                ProductMediaKind::Photo) {
                next.loopEnabled = false;
            }

            if (playbackIntentRevision_ ==
                startPlaybackIntentRevision) {
                next.playbackIntent =
                    ProductPlaybackIntent::Playing;
            }

            if (!store_.save(next)) {
                persistenceFailed = true;
                lastStatus_ =
                    "Unable to persist VCAM control state.";
                return false;
            }

            current_ = next;
            ownerCommitted = true;
            lastStatus_ =
                kind == ProductMediaKind::Video
                    ? "Local video selected."
                    : "Local photo selected.";
            return true;
        };

    const bool gateResult =
        commitGate
            ? commitGate(commitAction)
            : commitAction();

    if (!gateResult ||
        !ownerCommitted) {
        if (!ownerCommitted) {
            (void)stager_.removeOwnedPath(
                stagedPath);
        }

        if (errorMessage != nullptr) {
            if (!commitActionInvoked) {
                *errorMessage =
                    "Media selection superseded by newer request.";
            } else if (mediaIdentityRejected) {
                *errorMessage =
                    "Media selection superseded by newer media state.";
            } else if (persistenceFailed) {
                *errorMessage =
                    "Unable to persist VCAM control state.";
            } else {
                *errorMessage =
                    "Unable to commit staged media.";
            }
        }

        return false;
    }

    if (!oldPathToRemove.empty() &&
        oldPathToRemove != stagedPath) {
        (void)stager_.removeOwnedPath(
            oldPathToRemove);
    }

    if (errorMessage != nullptr) {
        errorMessage->clear();
    }

    return true;
}

bool ProductControlOwner::clearMedia() {
    std::string oldPath;

    {
        std::lock_guard<std::mutex>
            lock(mutex_);

        ProductControlSnapshot next =
            current_;

        oldPath =
            current_.mediaPath;

        next.mediaKind =
            ProductMediaKind::None;
        next.mediaPath.clear();
        next.selectionGeneration =
            nextGeneration(
                current_.selectionGeneration);
        next.loopEnabled = false;
        next.playbackIntent =
            ProductPlaybackIntent::Stopped;

        if (!store_.save(next)) {
            lastStatus_ =
                "Unable to persist cleared media state.";
            return false;
        }

        current_ = next;
        playbackIntentRevision_ =
            nextGeneration(
                playbackIntentRevision_);
        lastStatus_ =
            "Media cleared.";
    }

    if (!oldPath.empty()) {
        (void)stager_.removeOwnedPath(
            oldPath);
    }

    return true;
}

bool ProductControlOwner::setLoopEnabled(
    bool enabled) {
    std::lock_guard<std::mutex>
        lock(mutex_);

    if (current_.mediaKind !=
        ProductMediaKind::Video) {
        lastStatus_ =
            "Loop applies only to video.";
        return false;
    }

    ProductControlSnapshot next =
        current_;
    next.loopEnabled = enabled;

    if (!store_.save(next)) {
        lastStatus_ =
            "Unable to update video loop state.";
        return false;
    }

    current_ = next;
    lastStatus_ =
        enabled
            ? "Video loop enabled."
            : "Video loop disabled.";
    return true;
}

bool ProductControlOwner::setPlaybackIntent(
    ProductPlaybackIntent intent) {
    std::lock_guard<std::mutex>
        lock(mutex_);

    if (!current_.hasMedia()) {
        lastStatus_ =
            "Select media before playback.";
        return false;
    }

    ProductControlSnapshot next =
        current_;
    next.playbackIntent = intent;

    if (!store_.save(next)) {
        lastStatus_ =
            "Unable to update playback state.";
        return false;
    }

    current_ = next;
    playbackIntentRevision_ =
        nextGeneration(
            playbackIntentRevision_);

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

std::string
ProductControlOwner::lastStatus() const {
    std::lock_guard<std::mutex>
        lock(mutex_);
    return lastStatus_;
}

const std::string&
ProductControlOwner::mediaDirectory() const noexcept {
    return stager_.mediaDirectory();
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
