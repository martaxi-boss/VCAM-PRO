#include "SharedControlStore.h"

#import <Foundation/Foundation.h>

#include <notify.h>
#include <sys/stat.h>

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

ProductMediaKind ParseMediaKind(
    NSString* value) {
    if ([value isEqualToString:@"photo"]) {
        return ProductMediaKind::Photo;
    }
    if ([value isEqualToString:@"video"]) {
        return ProductMediaKind::Video;
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
    NSString* value) {
    if ([value isEqualToString:@"playing"]) {
        return ProductPlaybackIntent::Playing;
    }
    if ([value isEqualToString:@"paused"]) {
        return ProductPlaybackIntent::Paused;
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

std::string StdFromNSString(
    NSString* value) {
    if (value == nil) {
        return {};
    }
    const char* utf8 = value.UTF8String;
    return utf8 == nullptr
        ? std::string{}
        : std::string(utf8);
}

}  // namespace

SharedControlStore::SharedControlStore(
    std::string controlPath,
    std::string notificationName)
    : controlPath_(std::move(controlPath)),
      notificationName_(
          std::move(notificationName)) {
    notificationCF_ =
        CFStringCreateWithCString(
            kCFAllocatorDefault,
            notificationName_.c_str(),
            kCFStringEncodingUTF8);
}

SharedControlStore::~SharedControlStore() {
    stopObserving();
    if (notificationCF_ != nullptr) {
        CFRelease(notificationCF_);
        notificationCF_ = nullptr;
    }
}

bool SharedControlStore::load(
    ProductControlSnapshot* snapshot) const {
    if (snapshot == nullptr) {
        return false;
    }

    diskReadCount_.fetch_add(
        1,
        std::memory_order_relaxed);

    @autoreleasepool {
        NSString* path =
            NSStringFromStd(controlPath_);
        NSDictionary* dict =
            [NSDictionary
                dictionaryWithContentsOfFile:path];

        if (dict == nil) {
            *snapshot =
                ProductControlSnapshot{};
            return true;
        }

        ProductControlSnapshot result;
        result.enabled =
            [dict[@"enabled"] boolValue];
        result.mediaKind =
            ParseMediaKind(dict[@"mediaKind"]);
        result.mediaPath =
            StdFromNSString(dict[@"mediaPath"]);
        result.selectionGeneration =
            [dict[@"selectionGeneration"]
                unsignedLongLongValue];
        result.loopEnabled =
            [dict[@"loopEnabled"] boolValue];
        result.playbackIntent =
            ParsePlayback(
                dict[@"playbackIntent"]);

        if (result.mediaKind ==
                ProductMediaKind::None ||
            result.mediaPath.empty() ||
            result.selectionGeneration == 0) {
            result.mediaKind =
                ProductMediaKind::None;
            result.mediaPath.clear();
            result.playbackIntent =
                ProductPlaybackIntent::Stopped;
        }

        *snapshot = std::move(result);
        return true;
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
    if (notificationCF_ == nullptr ||
        !callback) {
        return false;
    }

    {
        std::lock_guard<std::mutex>
            lock(callbackMutex_);
        callback_ = std::move(callback);
    }

    if (!observing_) {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            this,
            &SharedControlStore::DarwinCallback,
            notificationCF_,
            nullptr,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        observing_ = true;
    }

    return true;
}

void SharedControlStore::stopObserving() {
    if (!observing_) {
        return;
    }

    CFNotificationCenterRemoveObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        this,
        notificationCF_,
        nullptr);
    observing_ = false;

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

void SharedControlStore::DarwinCallback(
    CFNotificationCenterRef center,
    void* observer,
    CFStringRef name,
    const void* object,
    CFDictionaryRef userInfo) {
    (void)center;
    (void)name;
    (void)object;
    (void)userInfo;

    auto* store =
        static_cast<SharedControlStore*>(
            observer);
    if (store != nullptr) {
        store->handleDarwinChange();
    }
}

void SharedControlStore::handleDarwinChange() {
    ProductControlSnapshot snapshot;
    if (!load(&snapshot)) {
        return;
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
