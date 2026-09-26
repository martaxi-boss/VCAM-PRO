#include "SharedMediaStager.h"

#include "FrameEngineState.h"
#include "LocalPhotoReader.h"
#include "LocalVideoReader.h"

#import <Foundation/Foundation.h>

#include <cerrno>
#include <cctype>
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <string>
#include <utility>

#if defined(VCAM_TESTING)
#include <mutex>
#endif

namespace vcam::product {

namespace {

NSString* NSStringFromStd(
    const std::string& value) {
    return [[NSString alloc]
        initWithBytes:value.data()
               length:value.size()
             encoding:NSUTF8StringEncoding];
}

std::string StdFromNSString(
    NSString* value) {
    const char* utf8 =
        value.UTF8String;
    return utf8 == nullptr
        ? std::string{}
        : std::string(utf8);
}

bool IsHexCharacter(
    unichar value) {
    return
        (value >= '0' && value <= '9') ||
        (value >= 'a' && value <= 'f') ||
        (value >= 'A' && value <= 'F');
}

bool IsGeneratedMediaFilename(
    NSString* filename) {
    if (filename == nil ||
        ![filename hasPrefix:@"media-"]) {
        return false;
    }

    const NSUInteger prefixLength = 6;
    if (filename.length <= prefixLength) {
        return false;
    }

    NSRange remaining =
        NSMakeRange(
            prefixLength,
            filename.length - prefixLength);
    NSRange separator =
        [filename
            rangeOfString:@"-"
                  options:0
                    range:remaining];

    if (separator.location ==
            NSNotFound ||
        separator.location ==
            prefixLength) {
        return false;
    }

    NSString* generation =
        [filename
            substringWithRange:
                NSMakeRange(
                    prefixLength,
                    separator.location -
                        prefixLength)];

    for (NSUInteger index = 0;
         index < generation.length;
         ++index) {
        const unichar value =
            [generation
                characterAtIndex:index];

        if (value < '0' ||
            value > '9') {
            return false;
        }
    }

    if (generation.longLongValue <= 0) {
        return false;
    }

    const NSUInteger uuidStart =
        NSMaxRange(separator);
    constexpr NSUInteger uuidLength = 36;

    if (filename.length <=
        uuidStart + uuidLength + 1) {
        return false;
    }

    NSString* uuid =
        [filename
            substringWithRange:
                NSMakeRange(
                    uuidStart,
                    uuidLength)];

    for (NSUInteger index = 0;
         index < uuid.length;
         ++index) {
        const bool hyphen =
            index == 8 ||
            index == 13 ||
            index == 18 ||
            index == 23;
        const unichar value =
            [uuid characterAtIndex:index];

        if (hyphen) {
            if (value != '-') {
                return false;
            }
        } else if (!IsHexCharacter(value)) {
            return false;
        }
    }

    if ([filename
            characterAtIndex:
                uuidStart + uuidLength] !=
        '.') {
        return false;
    }

    NSString* extension =
        [filename
            substringFromIndex:
                uuidStart +
                uuidLength +
                1];

    if (extension.length == 0 ||
        [extension containsString:@"/"] ||
        [extension containsString:@"\\"]) {
        return false;
    }

    return true;
}

NSString* StandardizedLocalPath(
    const std::string& value) {
    if (value.empty() ||
        value.find("://") !=
            std::string::npos) {
        return nil;
    }

    NSString* path =
        NSStringFromStd(value);

    if (path == nil ||
        !path.isAbsolutePath) {
        return nil;
    }

    return
        [path stringByStandardizingPath];
}

enum class MediaRootState : std::uint8_t {
    Missing = 0,
    ValidDirectory,
    Invalid,
};

MediaRootState InspectMediaRoot(
    const std::string& path) {
    NSString* standardized =
        StandardizedLocalPath(path);
    if (standardized == nil) {
        return MediaRootState::Invalid;
    }

    const std::string exactRoot =
        StdFromNSString(standardized);
    if (exactRoot.empty()) {
        return MediaRootState::Invalid;
    }

    struct stat info {};
    if (lstat(
            exactRoot.c_str(),
            &info) != 0) {
        return errno == ENOENT
            ? MediaRootState::Missing
            : MediaRootState::Invalid;
    }

    if (S_ISLNK(info.st_mode) ||
        !S_ISDIR(info.st_mode)) {
        return MediaRootState::Invalid;
    }

    return MediaRootState::ValidDirectory;
}

class ScopedFd final {
public:
    ScopedFd() = default;

    explicit ScopedFd(
        int fd)
        : fd_(fd) {}

    ~ScopedFd() {
        reset();
    }

    ScopedFd(
        const ScopedFd&) = delete;
    ScopedFd& operator=(
        const ScopedFd&) = delete;

    int get() const noexcept {
        return fd_;
    }

    void reset(
        int fd = -1) noexcept {
        if (fd_ >= 0) {
            close(fd_);
        }
        fd_ = fd;
    }

private:
    int fd_ {-1};
};

struct PinnedMediaRoot {
    ScopedFd fd;
    dev_t device {};
    ino_t inode {};
    std::string standardizedPath;
};

bool SameDirectoryIdentity(
    const PinnedMediaRoot& left,
    const PinnedMediaRoot& right) {
    return
        left.device == right.device &&
        left.inode == right.inode;
}

bool PinExistingMediaRoot(
    const std::string& configuredPath,
    PinnedMediaRoot* root) {
    if (root == nullptr) {
        return false;
    }

    NSString* standardized =
        StandardizedLocalPath(
            configuredPath);
    if (standardized == nil) {
        return false;
    }

    const std::string exactRoot =
        StdFromNSString(standardized);
    if (exactRoot.empty()) {
        return false;
    }

    const int fd =
        open(
            exactRoot.c_str(),
            O_RDONLY |
                O_DIRECTORY |
                O_NOFOLLOW |
                O_CLOEXEC);

    if (fd < 0) {
        return false;
    }

    struct stat info {};
    if (fstat(
            fd,
            &info) != 0 ||
        !S_ISDIR(info.st_mode)) {
        close(fd);
        return false;
    }

    root->fd.reset(fd);
    root->device = info.st_dev;
    root->inode = info.st_ino;
    root->standardizedPath =
        exactRoot;
    return true;
}

bool RootPathMatchesPinned(
    const PinnedMediaRoot& root) {
    PinnedMediaRoot fresh;
    if (!PinExistingMediaRoot(
            root.standardizedPath,
            &fresh)) {
        return false;
    }

    return SameDirectoryIdentity(
        root,
        fresh);
}

bool ExtractOwnedBasename(
    const std::string& rootPath,
    const std::string& candidatePath,
    std::string* basename) {
    if (basename == nullptr) {
        return false;
    }

    NSString* root =
        StandardizedLocalPath(
            rootPath);
    NSString* candidate =
        StandardizedLocalPath(
            candidatePath);

    if (root == nil ||
        candidate == nil ||
        [candidate isEqualToString:root]) {
        return false;
    }

    NSString* parent =
        [candidate
            stringByDeletingLastPathComponent];

    if (![parent
            isEqualToString:root]) {
        return false;
    }

    NSString* filename =
        candidate.lastPathComponent;

    if (!IsGeneratedMediaFilename(
            filename)) {
        return false;
    }

    const std::string result =
        StdFromNSString(filename);
    if (result.empty()) {
        return false;
    }

    *basename = result;
    return true;
}

bool IsRegularPinnedEntry(
    int rootFd,
    const std::string& basename) {
    struct stat info {};
    if (fstatat(
            rootFd,
            basename.c_str(),
            &info,
            AT_SYMLINK_NOFOLLOW) != 0) {
        return false;
    }

    return
        S_ISREG(info.st_mode) &&
        !S_ISLNK(info.st_mode);
}

bool RemovePinnedEntry(
    int rootFd,
    const std::string& basename) {
    if (unlinkat(
            rootFd,
            basename.c_str(),
            0) == 0) {
        return true;
    }

    return errno == ENOENT;
}

bool CopySourceIntoPinnedRoot(
    const std::string& sourcePath,
    int rootFd,
    const std::string& basename) {
    ScopedFd source(
        open(
            sourcePath.c_str(),
            O_RDONLY |
                O_CLOEXEC));

    if (source.get() < 0) {
        return false;
    }

    ScopedFd destination(
        openat(
            rootFd,
            basename.c_str(),
            O_WRONLY |
                O_CREAT |
                O_EXCL |
                O_NOFOLLOW |
                O_CLOEXEC,
            0644));

    if (destination.get() < 0) {
        return false;
    }

    char buffer[64 * 1024];

    for (;;) {
        const ssize_t bytesRead =
            read(
                source.get(),
                buffer,
                sizeof(buffer));

        if (bytesRead == 0) {
            break;
        }

        if (bytesRead < 0) {
            if (errno == EINTR) {
                continue;
            }

            (void)RemovePinnedEntry(
                rootFd,
                basename);
            return false;
        }

        ssize_t offset = 0;
        while (offset < bytesRead) {
            const ssize_t bytesWritten =
                write(
                    destination.get(),
                    buffer + offset,
                    static_cast<std::size_t>(
                        bytesRead - offset));

            if (bytesWritten < 0) {
                if (errno == EINTR) {
                    continue;
                }

                (void)RemovePinnedEntry(
                    rootFd,
                    basename);
                return false;
            }

            offset += bytesWritten;
        }
    }

    if (fchmod(
            destination.get(),
            0644) != 0) {
        (void)RemovePinnedEntry(
            rootFd,
            basename);
        return false;
    }

    return true;
}

#if defined(VCAM_TESTING)
std::mutex gTestHookMutex;
SharedMediaStagerTestHook gTestHook;

void RunTestHook(
    SharedMediaStagerTestPoint point) {
    SharedMediaStagerTestHook hook;

    {
        std::lock_guard<std::mutex>
            lock(gTestHookMutex);
        hook = gTestHook;
    }

    if (hook) {
        hook(point);
    }
}
#endif

}  // namespace

#if defined(VCAM_TESTING)
void SetSharedMediaStagerTestHook(
    SharedMediaStagerTestHook hook) {
    std::lock_guard<std::mutex>
        lock(gTestHookMutex);
    gTestHook =
        std::move(hook);
}
#endif

SharedMediaStager::SharedMediaStager(
    std::string mediaDirectory)
    : mediaDirectory_(
          std::move(mediaDirectory)) {}

bool SharedMediaStager::stageAndValidate(
    const std::string& temporarySourcePath,
    ProductMediaKind kind,
    std::uint64_t generation,
    std::string* stagedPath,
    std::string* errorMessage) {
    if (stagedPath != nullptr) {
        stagedPath->clear();
    }

    if (stagedPath == nullptr ||
        kind == ProductMediaKind::None ||
        generation == 0 ||
        temporarySourcePath.empty() ||
        temporarySourcePath.find("://") !=
            std::string::npos) {
        if (errorMessage != nullptr) {
            *errorMessage =
                "Invalid local media candidate.";
        }
        return false;
    }

    @autoreleasepool {
        NSFileManager* manager =
            [NSFileManager defaultManager];

        NSString* sourcePath =
            NSStringFromStd(
                temporarySourcePath);
        NSString* directory =
            StandardizedLocalPath(
                mediaDirectory_);

        BOOL isDirectory = NO;
        if (sourcePath == nil ||
            directory == nil ||
            ![manager
                fileExistsAtPath:sourcePath
                     isDirectory:&isDirectory] ||
            isDirectory) {
            if (errorMessage != nullptr) {
                *errorMessage =
                    "Candidate media file does not exist.";
            }
            return false;
        }

        const auto initialRootState =
            InspectMediaRoot(
                mediaDirectory_);

        if (initialRootState ==
            MediaRootState::Invalid) {
            if (errorMessage != nullptr) {
                *errorMessage =
                    "VCAM media root must be a real directory.";
            }
            return false;
        }

        if (initialRootState ==
            MediaRootState::Missing) {
            NSError* directoryError = nil;
            if (![manager
                    createDirectoryAtPath:directory
              withIntermediateDirectories:YES
                               attributes:nil
                                    error:&directoryError]) {
                if (errorMessage != nullptr) {
                    *errorMessage =
                        "Unable to create shared VCAM media directory.";
                }
                return false;
            }
        }

        PinnedMediaRoot root;
        if (!PinExistingMediaRoot(
                mediaDirectory_,
                &root)) {
            if (errorMessage != nullptr) {
                *errorMessage =
                    "VCAM media root must be a real directory.";
            }
            return false;
        }

        if (fchmod(
                root.fd.get(),
                0755) != 0) {
            if (errorMessage != nullptr) {
                *errorMessage =
                    "Unable to prepare shared VCAM media directory.";
            }
            return false;
        }

        NSString* extension =
            sourcePath.pathExtension;
        if (extension.length == 0) {
            extension =
                kind == ProductMediaKind::Video
                    ? @"mov"
                    : @"image";
        }

        NSString* filename =
            [NSString stringWithFormat:
                @"media-%llu-%@.%@",
                static_cast<unsigned long long>(
                    generation),
                NSUUID.UUID.UUIDString,
                extension];

        const std::string basename =
            StdFromNSString(filename);
        if (basename.empty()) {
            if (errorMessage != nullptr) {
                *errorMessage =
                    "Unable to create VCAM media identity.";
            }
            return false;
        }

#if defined(VCAM_TESTING)
        RunTestHook(
            SharedMediaStagerTestPoint::
                BeforeDestinationCreate);
#endif

        if (!CopySourceIntoPinnedRoot(
                temporarySourcePath,
                root.fd.get(),
                basename)) {
            if (errorMessage != nullptr) {
                *errorMessage =
                    "Unable to stage local media candidate.";
            }
            return false;
        }

        NSString* pinnedRootPath =
            NSStringFromStd(
                root.standardizedPath);
        NSString* destination =
            [pinnedRootPath
                stringByAppendingPathComponent:
                    filename];

        const std::string staged =
            StdFromNSString(destination);

        if (staged.empty() ||
            !RootPathMatchesPinned(root)) {
            (void)RemovePinnedEntry(
                root.fd.get(),
                basename);

            if (errorMessage != nullptr) {
                *errorMessage =
                    "VCAM media root changed during staging.";
            }
            return false;
        }

        std::string validationError;
        if (!validate(
                staged,
                kind,
                &validationError)) {
            (void)RemovePinnedEntry(
                root.fd.get(),
                basename);

            if (errorMessage != nullptr) {
                *errorMessage =
                    validationError.empty()
                        ? "Media validation failed."
                        : validationError;
            }
            return false;
        }

#if defined(VCAM_TESTING)
        RunTestHook(
            SharedMediaStagerTestPoint::
                BeforePublish);
#endif

        if (!RootPathMatchesPinned(root)) {
            (void)RemovePinnedEntry(
                root.fd.get(),
                basename);

            if (errorMessage != nullptr) {
                *errorMessage =
                    "VCAM media root changed before publication.";
            }
            return false;
        }

        *stagedPath = staged;

        if (errorMessage != nullptr) {
            errorMessage->clear();
        }

        return true;
    }
}

bool SharedMediaStager::removeOwnedPath(
    const std::string& path) const {
    PinnedMediaRoot root;
    if (!PinExistingMediaRoot(
            mediaDirectory_,
            &root)) {
        return false;
    }

    std::string basename;
    if (!ExtractOwnedBasename(
            root.standardizedPath,
            path,
            &basename)) {
        return false;
    }

    struct stat info {};
    if (fstatat(
            root.fd.get(),
            basename.c_str(),
            &info,
            AT_SYMLINK_NOFOLLOW) != 0) {
        return errno == ENOENT;
    }

    if (!S_ISREG(info.st_mode) ||
        S_ISLNK(info.st_mode)) {
        return false;
    }

#if defined(VCAM_TESTING)
    RunTestHook(
        SharedMediaStagerTestPoint::
            BeforeDelete);
#endif

    return RemovePinnedEntry(
        root.fd.get(),
        basename);
}

bool SharedMediaStager::isExistingOwnedMediaPath(
    const std::string& path) const {
    PinnedMediaRoot root;
    if (!PinExistingMediaRoot(
            mediaDirectory_,
            &root)) {
        return false;
    }

    std::string basename;
    if (!ExtractOwnedBasename(
            root.standardizedPath,
            path,
            &basename)) {
        return false;
    }

    return
        IsRegularPinnedEntry(
            root.fd.get(),
            basename) &&
        RootPathMatchesPinned(root);
}

bool SharedMediaStager::reconcileOwnedMedia(
    const std::string& activeOwnedPath,
    std::string* errorMessage) const {
    @autoreleasepool {
        const auto rootState =
            InspectMediaRoot(
                mediaDirectory_);

        if (rootState ==
            MediaRootState::Missing) {
            if (errorMessage != nullptr) {
                errorMessage->clear();
            }
            return true;
        }

        if (rootState !=
            MediaRootState::ValidDirectory) {
            if (errorMessage != nullptr) {
                *errorMessage =
                    "VCAM media root must be a real directory.";
            }
            return false;
        }

        PinnedMediaRoot root;
        if (!PinExistingMediaRoot(
                mediaDirectory_,
                &root)) {
            if (errorMessage != nullptr) {
                *errorMessage =
                    "Unable to pin VCAM media storage.";
            }
            return false;
        }

        std::string activeBasename;
        if (!activeOwnedPath.empty()) {
            std::string candidateBasename;
            if (ExtractOwnedBasename(
                    root.standardizedPath,
                    activeOwnedPath,
                    &candidateBasename) &&
                IsRegularPinnedEntry(
                    root.fd.get(),
                    candidateBasename)) {
                activeBasename =
                    candidateBasename;
            }
        }

        const int enumerationFd =
            dup(root.fd.get());
        if (enumerationFd < 0) {
            if (errorMessage != nullptr) {
                *errorMessage =
                    "Unable to enumerate VCAM media storage.";
            }
            return false;
        }

        DIR* directory =
            fdopendir(enumerationFd);
        if (directory == nullptr) {
            close(enumerationFd);

            if (errorMessage != nullptr) {
                *errorMessage =
                    "Unable to enumerate VCAM media storage.";
            }
            return false;
        }

        errno = 0;
        bool enumerationFailed = false;

        for (;;) {
            dirent* entry =
                readdir(directory);

            if (entry == nullptr) {
                enumerationFailed =
                    errno != 0;
                break;
            }

            NSString* entryName =
                [NSString
                    stringWithUTF8String:
                        entry->d_name];

            if (!IsGeneratedMediaFilename(
                    entryName)) {
                continue;
            }

            const std::string basename =
                entry->d_name;

            if (!activeBasename.empty() &&
                basename == activeBasename) {
                continue;
            }

            if (!IsRegularPinnedEntry(
                    root.fd.get(),
                    basename)) {
                continue;
            }

#if defined(VCAM_TESTING)
            RunTestHook(
                SharedMediaStagerTestPoint::
                    BeforeReconcileDelete);
#endif

            (void)RemovePinnedEntry(
                root.fd.get(),
                basename);
        }

        closedir(directory);

        if (enumerationFailed) {
            if (errorMessage != nullptr) {
                *errorMessage =
                    "Unable to enumerate VCAM media storage.";
            }
            return false;
        }

        if (!RootPathMatchesPinned(root)) {
            if (errorMessage != nullptr) {
                *errorMessage =
                    "VCAM media root changed during recovery.";
            }
            return false;
        }

        if (errorMessage != nullptr) {
            errorMessage->clear();
        }
        return true;
    }
}

const std::string&
SharedMediaStager::mediaDirectory() const noexcept {
    return mediaDirectory_;
}

bool SharedMediaStager::validate(
    const std::string& path,
    ProductMediaKind kind,
    std::string* errorMessage) const {
    frame_engine::FrameEngineState state;

    if (kind ==
        ProductMediaKind::Video) {
        media_engine::LocalVideoReader
            reader(state);
        media_engine::LocalVideoReaderConfig
            config;
        config.loopEnabled = false;
        config.outputPixelFormat =
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;

        if (!reader.open(path, config)) {
            if (errorMessage != nullptr) {
                *errorMessage =
                    reader.lastErrorMessage();
            }
            return false;
        }

        reader.stop();
        return true;
    }

    if (kind ==
        ProductMediaKind::Photo) {
        media_engine::LocalPhotoReader
            reader(state);
        media_engine::LocalPhotoReaderConfig
            config;
        config.cadenceNumerator = 30;
        config.cadenceDenominator = 1;
        config.outputPixelFormat =
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;

        if (!reader.open(path, config)) {
            if (errorMessage != nullptr) {
                *errorMessage =
                    reader.lastErrorMessage();
            }
            return false;
        }

        reader.stop();
        return true;
    }

    if (errorMessage != nullptr) {
        *errorMessage =
            "Unsupported media kind.";
    }
    return false;
}

bool SharedMediaStager::isOwnedPath(
    const std::string& path) const {
    PinnedMediaRoot root;
    if (!PinExistingMediaRoot(
            mediaDirectory_,
            &root)) {
        return false;
    }

    std::string basename;
    return
        ExtractOwnedBasename(
            root.standardizedPath,
            path,
            &basename) &&
        RootPathMatchesPinned(root);
}

}  // namespace vcam::product
