#include "SharedMediaStager.h"

#include "FrameEngineState.h"
#include "LocalPhotoReader.h"
#include "LocalVideoReader.h"

#import <Foundation/Foundation.h>

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
        chmod(
            staged.c_str(),
            0644);

        std::string validationError;
        if (!validate(
                staged,
                kind,
                &validationError)) {
            [manager
                removeItemAtPath:destination
                           error:nil];
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

    @autoreleasepool {
        NSString* nsPath =
            NSStringFromStd(path);
        if (nsPath == nil) {
            return false;
        }

        if (![[NSFileManager defaultManager]
                fileExistsAtPath:nsPath]) {
            return true;
        }

        return [[NSFileManager defaultManager]
            removeItemAtPath:nsPath
                       error:nil];
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
    const std::string& path) const noexcept {
    if (path.size() <=
        mediaDirectory_.size()) {
        return false;
    }

    if (path.compare(
            0,
            mediaDirectory_.size(),
            mediaDirectory_) != 0) {
        return false;
    }

    return path[
        mediaDirectory_.size()] == '/';
}

}  // namespace vcam::product
