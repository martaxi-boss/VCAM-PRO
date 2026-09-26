#include "SharedMediaStager.h"

#include "FrameEngineState.h"
#include "LocalPhotoReader.h"
#include "LocalVideoReader.h"

#import <Foundation/Foundation.h>

#include <cerrno>
#include <cctype>
#include <sys/stat.h>

#include <string>
#include <utility>

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

bool SameCanonicalPath(
    NSString* left,
    NSString* right) {
    if (left == nil ||
        right == nil) {
        return false;
    }

    return
        [[left
            stringByResolvingSymlinksInPath]
            isEqualToString:
                [right
                    stringByResolvingSymlinksInPath]];
}

bool IsRegularNonSymlink(
    const std::string& path) {
    struct stat info {};
    if (lstat(
            path.c_str(),
            &info) != 0) {
        return false;
    }

    return
        S_ISREG(info.st_mode) &&
        !S_ISLNK(info.st_mode);
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

}  // namespace

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
            NSStringFromStd(
                mediaDirectory_);

        BOOL isDirectory = NO;
        if (sourcePath == nil ||
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

        if (InspectMediaRoot(
                mediaDirectory_) !=
            MediaRootState::ValidDirectory) {
            if (errorMessage != nullptr) {
                *errorMessage =
                    "VCAM media root must be a real directory.";
            }
            return false;
        }

        chmod(
            mediaDirectory_.c_str(),
            0755);

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

        NSString* destination =
            [directory
                stringByAppendingPathComponent:
                    filename];

        if (InspectMediaRoot(
                mediaDirectory_) !=
            MediaRootState::ValidDirectory) {
            if (errorMessage != nullptr) {
                *errorMessage =
                    "VCAM media root changed before staging.";
            }
            return false;
        }

        NSError* copyError = nil;
        if (![manager
                copyItemAtPath:sourcePath
                         toPath:destination
                          error:&copyError]) {
            if (errorMessage != nullptr) {
                *errorMessage =
                    "Unable to stage local media candidate.";
            }
            return false;
        }

        const std::string staged =
            StdFromNSString(destination);

        if (InspectMediaRoot(
                mediaDirectory_) !=
            MediaRootState::ValidDirectory) {
            if (errorMessage != nullptr) {
                *errorMessage =
                    "VCAM media root changed during staging.";
            }
            return false;
        }

        chmod(
            staged.c_str(),
            0644);

        std::string validationError;
        if (!validate(
                staged,
                kind,
                &validationError)) {
            (void)removeOwnedPath(
                staged);
            if (errorMessage != nullptr) {
                *errorMessage =
                    validationError.empty()
                        ? "Media validation failed."
                        : validationError;
            }
            return false;
        }

        *stagedPath = staged;
        return true;
    }
}

bool SharedMediaStager::removeOwnedPath(
    const std::string& path) const {
    if (!isOwnedPath(path)) {
        return false;
    }

    struct stat info {};
    if (lstat(
            path.c_str(),
            &info) != 0) {
        return errno == ENOENT;
    }

    if (!S_ISREG(info.st_mode) ||
        S_ISLNK(info.st_mode)) {
        return false;
    }

    if (InspectMediaRoot(
            mediaDirectory_) !=
        MediaRootState::ValidDirectory) {
        return false;
    }

    @autoreleasepool {
        NSString* nsPath =
            StandardizedLocalPath(path);

        return
            nsPath != nil &&
            [[NSFileManager defaultManager]
                removeItemAtPath:nsPath
                           error:nil];
    }
}

bool SharedMediaStager::isExistingOwnedMediaPath(
    const std::string& path) const {
    return
        isOwnedPath(path) &&
        IsRegularNonSymlink(path);
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

        NSString* directory =
            StandardizedLocalPath(
                mediaDirectory_);

        if (directory == nil) {
            if (errorMessage != nullptr) {
                *errorMessage =
                    "Invalid VCAM media directory.";
            }
            return false;
        }

        BOOL isDirectory = NO;
        NSFileManager* manager =
            [NSFileManager defaultManager];

        if (![manager
                fileExistsAtPath:directory
                     isDirectory:&isDirectory]) {
            if (errorMessage != nullptr) {
                errorMessage->clear();
            }
            return true;
        }

        if (!isDirectory) {
            if (errorMessage != nullptr) {
                *errorMessage =
                    "VCAM media root is not a directory.";
            }
            return false;
        }

        NSString* trustedActive = nil;
        if (!activeOwnedPath.empty() &&
            isExistingOwnedMediaPath(
                activeOwnedPath)) {
            trustedActive =
                StandardizedLocalPath(
                    activeOwnedPath);
        }

        if (InspectMediaRoot(
                mediaDirectory_) !=
            MediaRootState::ValidDirectory) {
            if (errorMessage != nullptr) {
                *errorMessage =
                    "VCAM media root changed before recovery.";
            }
            return false;
        }

        NSError* enumerateError = nil;
        NSArray<NSString*>* entries =
            [manager
                contentsOfDirectoryAtPath:
                    directory
                                  error:
                                      &enumerateError];

        if (entries == nil) {
            if (errorMessage != nullptr) {
                *errorMessage =
                    "Unable to enumerate VCAM media storage.";
            }
            return false;
        }

        for (NSString* entry in entries) {
            if (!IsGeneratedMediaFilename(
                    entry)) {
                continue;
            }

            NSString* candidate =
                [directory
                    stringByAppendingPathComponent:
                        entry];

            if (trustedActive != nil &&
                SameCanonicalPath(
                    candidate,
                    trustedActive)) {
                continue;
            }

            const std::string candidatePath =
                StdFromNSString(candidate);

            if (isExistingOwnedMediaPath(
                    candidatePath)) {
                (void)removeOwnedPath(
                    candidatePath);
            }
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
    @autoreleasepool {
        if (InspectMediaRoot(
                mediaDirectory_) !=
            MediaRootState::ValidDirectory) {
            return false;
        }

        NSString* root =
            StandardizedLocalPath(
                mediaDirectory_);
        NSString* candidate =
            StandardizedLocalPath(path);

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

        if (!IsGeneratedMediaFilename(
                candidate.lastPathComponent)) {
            return false;
        }

        NSString* canonicalRoot =
            [root
                stringByResolvingSymlinksInPath];
        NSString* canonicalCandidate =
            [candidate
                stringByResolvingSymlinksInPath];

        if (canonicalRoot == nil ||
            canonicalCandidate == nil ||
            [canonicalCandidate
                isEqualToString:
                    canonicalRoot]) {
            return false;
        }

        NSString* canonicalParent =
            [canonicalCandidate
                stringByDeletingLastPathComponent];

        return
            [canonicalParent
                isEqualToString:
                    canonicalRoot];
    }
}

}  // namespace vcam::product
