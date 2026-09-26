#include "SharedControlStore.h"

#import <Foundation/Foundation.h>

#include <notify.h>
#include <sys/stat.h>

#include <utility>

namespace vcam::product {

namespace {

char kSharedControlNotificationQueueKey;

NSString* NSStringFromStd(
    const std::string& value) {
    return [[NSString alloc]
        initWithBytes:value.data()
               length:value.size()
             encoding:NSUTF8StringEncoding];
}

bool IsNumber(
    id value) {
    return
        value != nil &&
        [value isKindOfClass:
            [NSNumber class]];
}

bool IsString(
    id value) {
    return
        value != nil &&
        [value isKindOfClass:
            [NSString class]];
}

bool ParseBoolField(
    id value,
    bool* typeConfused) {
    if (value == nil) {
        return false;
    }

    if (!IsNumber(value)) {
        if (typeConfused != nullptr) {
            *typeConfused = true;
        }
        return false;
    }

    return
        [(NSNumber*)value boolValue];
}

ProductMediaKind ParseMediaKind(
    id value,
    bool* typeConfused,
    bool* recognized) {
    if (recognized != nullptr) {
        *recognized = true;
    }

    if (value == nil) {
        return ProductMediaKind::None;
    }

    if (!IsString(value)) {
        if (typeConfused != nullptr) {
            *typeConfused = true;
        }
        return ProductMediaKind::None;
    }

    NSString* string =
        (NSString*)value;

    if ([string
            isEqualToString:@"photo"]) {
        return ProductMediaKind::Photo;
    }

    if ([string
            isEqualToString:@"video"]) {
        return ProductMediaKind::Video;
    }

    if ([string
            isEqualToString:@"none"]) {
        return ProductMediaKind::None;
    }

    if (recognized != nullptr) {
        *recognized = false;
    }
    return ProductMediaKind::None;
}

NSString* MediaKindString(
    ProductMediaKind kind) {
    switch (kind) {
        case ProductMediaKind::Photo:
            return @"photo";
        case ProductMediaKind::Video:
            return @"video";
        case ProductMediaKind::None:
            return @"none";
    }
    return @"none";
}

ProductPlaybackIntent ParsePlayback(
    id value,
    bool* typeConfused,
    bool* recognized) {
    if (recognized != nullptr) {
        *recognized = true;
    }

    if (value == nil) {
        return ProductPlaybackIntent::Stopped;
    }

    if (!IsString(value)) {
        if (typeConfused != nullptr) {
            *typeConfused = true;
        }
        return ProductPlaybackIntent::Stopped;
    }

    NSString* string =
        (NSString*)value;

    if ([string
            isEqualToString:@"playing"]) {
        return ProductPlaybackIntent::Playing;
    }

    if ([string
            isEqualToString:@"paused"]) {
        return ProductPlaybackIntent::Paused;
    }

    if ([string
            isEqualToString:@"stopped"]) {
        return ProductPlaybackIntent::Stopped;
    }

    if (recognized != nullptr) {
        *recognized = false;
    }
    return ProductPlaybackIntent::Stopped;
}

NSString* PlaybackString(
    ProductPlaybackIntent intent) {
    switch (intent) {
        case ProductPlaybackIntent::Playing:
            return @"playing";
        case ProductPlaybackIntent::Paused:
            return @"paused";
        case ProductPlaybackIntent::Stopped:
            return @"stopped";
    }
    return @"stopped";
}

std::string ParseStringField(
    id value,
    bool* typeConfused) {
    if (value == nil) {
        return {};
    }

    if (!IsString(value)) {
        if (typeConfused != nullptr) {
            *typeConfused = true;
        }
        return {};
    }

    const char* utf8 =
        [(NSString*)value UTF8String];

    return utf8 == nullptr
        ? std::string{}
        : std::string(utf8);
}

bool ParseUnsignedGeneration(
    id value,
    std::uint64_t* generation,
    bool* typeConfused) {
    if (generation == nullptr) {
        return false;
    }

    *generation = 0;

    if (value == nil) {
        return true;
    }

    if (!IsNumber(value)) {
        if (typeConfused != nullptr) {
            *typeConfused = true;
        }
        return false;
    }

    NSNumber* number =
        (NSNumber*)value;

    if (CFGetTypeID(
            (__bridge CFTypeRef)number) ==
        CFBooleanGetTypeID()) {
        if (typeConfused != nullptr) {
            *typeConfused = true;
        }
        return false;
    }

    const char* type =
        number.objCType;

    if (type == nullptr ||
        type[0] == '\0') {
        if (typeConfused != nullptr) {
            *typeConfused = true;
        }
        return false;
    }

    switch (type[0]) {
        case 'c':
        case 's':
        case 'i':
        case 'l':
        case 'q': {
            const long long signedValue =
                number.longLongValue;
            if (signedValue < 0) {
                if (typeConfused != nullptr) {
                    *typeConfused = true;
                }
                return false;
            }

            *generation =
                static_cast<std::uint64_t>(
                    signedValue);
            return true;
        }

        case 'C':
        case 'S':
        case 'I':
        case 'L':
        case 'Q':
            *generation =
                static_cast<std::uint64_t>(
                    number.unsignedLongLongValue);
            return true;

        default:
            if (typeConfused != nullptr) {
                *typeConfused = true;
            }
            return false;
    }
}

bool HasCompleteSchema(
    NSDictionary* dict) {
    if (dict == nil) {
        return false;
    }

    return
        dict[@"enabled"] != nil &&
        dict[@"mediaKind"] != nil &&
        dict[@"mediaPath"] != nil &&
        dict[@"selectionGeneration"] != nil &&
        dict[@"loopEnabled"] != nil &&
        dict[@"playbackIntent"] != nil;
}

bool IsCanonicalSnapshotEncoding(
    const ProductControlSnapshot& snapshot,
    bool typeConfused,
    bool mediaKindRecognized,
    bool playbackRecognized,
    bool generationValid,
    bool schemaComplete) {
    if (typeConfused ||
        !mediaKindRecognized ||
        !playbackRecognized ||
        !generationValid ||
        !schemaComplete) {
        return false;
    }

    if (snapshot.mediaKind ==
        ProductMediaKind::None) {
        return
            snapshot.mediaPath.empty() &&
            !snapshot.loopEnabled &&
            snapshot.playbackIntent ==
                ProductPlaybackIntent::Stopped;
    }

    if (snapshot.mediaPath.empty() ||
        snapshot.selectionGeneration == 0) {
        return false;
    }

    if (snapshot.mediaKind ==
        ProductMediaKind::Photo &&
        snapshot.loopEnabled) {
        return false;
    }

    return
        snapshot.mediaKind ==
            ProductMediaKind::Photo ||
        snapshot.mediaKind ==
            ProductMediaKind::Video;
}

void NormalizeSnapshot(
    ProductControlSnapshot* snapshot,
    bool typeConfused,
    bool mediaKindRecognized,
    bool playbackRecognized) {
    if (snapshot == nullptr) {
        return;
    }

    if (typeConfused) {
        const std::uint64_t generation =
            snapshot->selectionGeneration;

        *snapshot =
            ProductControlSnapshot{};
        snapshot->selectionGeneration =
            generation;
        return;
    }

    if (!mediaKindRecognized) {
        snapshot->mediaKind =
            ProductMediaKind::None;
    }

    if (!playbackRecognized) {
        snapshot->playbackIntent =
            ProductPlaybackIntent::Stopped;
    }

    const bool hasCompleteIdentity =
        (snapshot->mediaKind ==
             ProductMediaKind::Photo ||
         snapshot->mediaKind ==
             ProductMediaKind::Video) &&
        !snapshot->mediaPath.empty() &&
        snapshot->selectionGeneration != 0;

    if (!hasCompleteIdentity) {
        snapshot->mediaKind =
            ProductMediaKind::None;
        snapshot->mediaPath.clear();
        snapshot->loopEnabled = false;
        snapshot->playbackIntent =
            ProductPlaybackIntent::Stopped;
        return;
    }

    if (snapshot->mediaKind ==
        ProductMediaKind::Photo) {
        snapshot->loopEnabled = false;
    }
}

}  // namespace

SharedControlStore::SharedControlStore(
    std::string controlPath,
    std::string notificationName)
    : controlPath_(std::move(controlPath)),
      notificationName_(
          std::move(notificationName)) {}

SharedControlStore::~SharedControlStore() {
    stopObserving();
}

bool SharedControlStore::load(
    ProductControlSnapshot* snapshot) const {
    if (snapshot == nullptr) {
        return false;
    }

    (void)loadWithProvenance(
        snapshot);
    return true;
}

SharedControlLoadProvenance
SharedControlStore::loadWithProvenance(
    ProductControlSnapshot* snapshot) const {
    if (snapshot == nullptr) {
        return
            SharedControlLoadProvenance::
                InvalidOrUnreadable;
    }

    diskReadCount_.fetch_add(
        1,
        std::memory_order_relaxed);

    @autoreleasepool {
        *snapshot =
            ProductControlSnapshot{};

        NSString* path =
            NSStringFromStd(controlPath_);

        if (path == nil) {
            return
                SharedControlLoadProvenance::
                    InvalidOrUnreadable;
        }

        BOOL isDirectory = NO;
        const BOOL exists =
            [[NSFileManager defaultManager]
                fileExistsAtPath:path
                     isDirectory:&isDirectory];

        if (!exists) {
            return
                SharedControlLoadProvenance::
                    Absent;
        }

        if (isDirectory) {
            return
                SharedControlLoadProvenance::
                    InvalidOrUnreadable;
        }

        NSData* data =
            [NSData
                dataWithContentsOfFile:path
                               options:0
                                 error:nil];

        if (data == nil) {
            return
                SharedControlLoadProvenance::
                    InvalidOrUnreadable;
        }

        NSError* plistError = nil;
        id root =
            [NSPropertyListSerialization
                propertyListWithData:data
                             options:
                                 NSPropertyListImmutable
                              format:nil
                               error:&plistError];

        if (root == nil ||
            plistError != nil ||
            ![root isKindOfClass:
                [NSDictionary class]]) {
            return
                SharedControlLoadProvenance::
                    InvalidOrUnreadable;
        }

        NSDictionary* dict =
            (NSDictionary*)root;

        bool typeConfused = false;
        bool mediaKindRecognized = true;
        bool playbackRecognized = true;

        ProductControlSnapshot result;

        result.enabled =
            ParseBoolField(
                dict[@"enabled"],
                &typeConfused);

        result.mediaKind =
            ParseMediaKind(
                dict[@"mediaKind"],
                &typeConfused,
                &mediaKindRecognized);

        result.mediaPath =
            ParseStringField(
                dict[@"mediaPath"],
                &typeConfused);

        const bool generationValid =
            ParseUnsignedGeneration(
                dict[@"selectionGeneration"],
                &result.selectionGeneration,
                &typeConfused);

        result.loopEnabled =
            ParseBoolField(
                dict[@"loopEnabled"],
                &typeConfused);

        result.playbackIntent =
            ParsePlayback(
                dict[@"playbackIntent"],
                &typeConfused,
                &playbackRecognized);

        const bool trusted =
            IsCanonicalSnapshotEncoding(
                result,
                typeConfused,
                mediaKindRecognized,
                playbackRecognized,
                generationValid,
                HasCompleteSchema(dict));

        NormalizeSnapshot(
            &result,
            typeConfused,
            mediaKindRecognized,
            playbackRecognized);

        *snapshot =
            std::move(result);

        return trusted
            ? SharedControlLoadProvenance::Valid
            : SharedControlLoadProvenance::
                InvalidOrUnreadable;
    }
}

bool SharedControlStore::save(
    const ProductControlSnapshot& snapshot,
    bool postChangeNotification) {
    @autoreleasepool {
        NSString* path =
            NSStringFromStd(controlPath_);
        NSString* directory =
            [path stringByDeletingLastPathComponent];

        NSError* directoryError = nil;
        if (![[NSFileManager defaultManager]
                createDirectoryAtPath:directory
          withIntermediateDirectories:YES
                           attributes:nil
                                error:&directoryError]) {
            return false;
        }

        NSString* mediaPath =
            NSStringFromStd(
                snapshot.mediaPath);

        NSString* storedMediaPath =
            mediaPath != nil
                ? mediaPath
                : @"";

        NSDictionary* dict = @{
            @"enabled" :
                @(snapshot.enabled),
            @"mediaKind" :
                MediaKindString(
                    snapshot.mediaKind),
            @"mediaPath" :
                storedMediaPath,
            @"selectionGeneration" :
                @(snapshot.selectionGeneration),
            @"loopEnabled" :
                @(snapshot.loopEnabled),
            @"playbackIntent" :
                PlaybackString(
                    snapshot.playbackIntent),
        };

        if (![dict writeToFile:path
                    atomically:YES]) {
            return false;
        }

        chmod(
            controlPath_.c_str(),
            0644);

        diskWriteCount_.fetch_add(
            1,
            std::memory_order_relaxed);

        if (postChangeNotification) {
            notify_post(
                notificationName_.c_str());
        }

        return true;
    }
}

bool SharedControlStore::startObserving(
    ChangeCallback callback) {
    if (!callback) {
        return false;
    }

    {
        std::lock_guard<std::mutex>
            lock(callbackMutex_);
        callback_ = std::move(callback);
    }

    if (observing_) {
        return true;
    }

    if (notificationQueue_ == nullptr) {
        notificationQueue_ =
            dispatch_queue_create(
                "com.vcampro.control-notifications",
                DISPATCH_QUEUE_SERIAL);
        if (notificationQueue_ == nullptr) {
            std::lock_guard<std::mutex>
                lock(callbackMutex_);
            callback_ = {};
            return false;
        }

        dispatch_queue_set_specific(
            notificationQueue_,
            &kSharedControlNotificationQueueKey,
            this,
            nullptr);
    }

    int token = 0;
    const uint32_t status =
        notify_register_dispatch(
            notificationName_.c_str(),
            &token,
            notificationQueue_,
            ^(int deliveredToken) {
                (void)deliveredToken;
                this->handleDarwinChange();
            });

    if (status != NOTIFY_STATUS_OK) {
        std::lock_guard<std::mutex>
            lock(callbackMutex_);
        callback_ = {};
        return false;
    }

    notifyToken_ = token;
    observing_ = true;
    return true;
}

void SharedControlStore::stopObserving() {
    if (observing_) {
        (void)notify_cancel(
            notifyToken_);
        notifyToken_ = 0;
        observing_ = false;

        if (notificationQueue_ != nullptr &&
            dispatch_get_specific(
                &kSharedControlNotificationQueueKey) !=
                this) {
            dispatch_sync(
                notificationQueue_,
                ^{});
        }
    }

    std::lock_guard<std::mutex>
        lock(callbackMutex_);
    callback_ = {};
}

const std::string&
SharedControlStore::controlPath() const noexcept {
    return controlPath_;
}

const std::string&
SharedControlStore::notificationName() const noexcept {
    return notificationName_;
}

std::uint64_t
SharedControlStore::diskReadCount() const noexcept {
    return diskReadCount_.load(
        std::memory_order_relaxed);
}

std::uint64_t
SharedControlStore::diskWriteCount() const noexcept {
    return diskWriteCount_.load(
        std::memory_order_relaxed);
}

void SharedControlStore::handleDarwinChange() {
    ProductControlSnapshot snapshot;

    const auto provenance =
        loadWithProvenance(
            &snapshot);

    if (provenance ==
        SharedControlLoadProvenance::
            InvalidOrUnreadable) {
        snapshot =
            ProductControlSnapshot{};
    }

    ChangeCallback callback;
    {
        std::lock_guard<std::mutex>
            lock(callbackMutex_);
        callback = callback_;
    }

    if (callback) {
        callback(snapshot);
    }
}

}  // namespace vcam::product
