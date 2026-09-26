#include "SharedControlStore.h"

#import <Foundation/Foundation.h>

#include <notify.h>
#include <unistd.h>

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <iostream>
#include <mutex>
#include <string>

namespace {

using vcam::product::ProductControlSnapshot;
using vcam::product::ProductMediaKind;
using vcam::product::ProductPlaybackIntent;
using vcam::product::SharedControlStore;

int gTests = 0;
int gFailures = 0;

#define CHECK(condition) \
    do { \
        if (!(condition)) { \
            std::cerr \
                << "CHECK failed at " \
                << __FILE__ << ":" \
                << __LINE__ << ": " \
                << #condition \
                << std::endl; \
            return false; \
        } \
    } while (false)

std::string ToStd(
    NSString* value) {
    const char* utf8 =
        value.UTF8String;

    return utf8 == nullptr
        ? std::string{}
        : std::string(utf8);
}

std::string TempRoot() {
    return ToStd(
        [NSTemporaryDirectory()
            stringByAppendingPathComponent:
                [NSString
                    stringWithFormat:
                        @"vcam-store-hardening-%@-%d",
                        NSUUID.UUID.UUIDString,
                        getpid()]]);
}

bool CreateDirectory(
    const std::string& path) {
    return [[NSFileManager defaultManager]
        createDirectoryAtPath:
            [NSString
                stringWithUTF8String:
                    path.c_str()]
  withIntermediateDirectories:YES
                   attributes:nil
                        error:nil];
}

void RemoveTree(
    const std::string& root) {
    [[NSFileManager defaultManager]
        removeItemAtPath:
            [NSString
                stringWithUTF8String:
                    root.c_str()]
                   error:nil];
}

NSMutableDictionary*
ValidVideoDictionary() {
    return
        [@{
            @"enabled" : @YES,
            @"mediaKind" : @"video",
            @"mediaPath" : @"/tmp/valid.mov",
            @"selectionGeneration" : @7,
            @"loopEnabled" : @YES,
            @"playbackIntent" : @"playing"
        } mutableCopy];
}

bool WritePlistObject(
    const std::string& path,
    id root) {
    NSString* nsPath =
        [NSString
            stringWithUTF8String:
                path.c_str()];

    return
        nsPath != nil &&
        [root writeToFile:nsPath
               atomically:YES];
}

bool WriteMalformedBytes(
    const std::string& path) {
    static const unsigned char bytes[] = {
        0x00, 0xff, 0x13, 0x37,
        'n', 'o', 't', '-', 'p',
        'l', 'i', 's', 't'
    };

    NSData* data =
        [NSData
            dataWithBytes:bytes
                   length:sizeof(bytes)];

    return [data
        writeToFile:
            [NSString
                stringWithUTF8String:
                    path.c_str()]
           atomically:YES];
}

bool IsNoMediaSafe(
    const ProductControlSnapshot& snapshot) {
    return
        snapshot.mediaKind ==
            ProductMediaKind::None &&
        snapshot.mediaPath.empty() &&
        !snapshot.loopEnabled &&
        snapshot.playbackIntent ==
            ProductPlaybackIntent::Stopped;
}

bool IsDisabledNoMediaSafe(
    const ProductControlSnapshot& snapshot) {
    return
        !snapshot.enabled &&
        IsNoMediaSafe(snapshot);
}

bool Load(
    const std::string& path,
    ProductControlSnapshot* snapshot) {
    SharedControlStore store(
        path,
        "com.vcampro.test.store-hardening.load");
    return store.load(snapshot);
}

bool TestAbsentPlistSafeDefault() {
    const std::string root =
        TempRoot();
    CHECK(CreateDirectory(root));

    ProductControlSnapshot snapshot;
    CHECK(Load(
        root + "/absent.plist",
        &snapshot));

    CHECK(IsDisabledNoMediaSafe(
        snapshot));
    CHECK(
        snapshot.selectionGeneration ==
        0);

    RemoveTree(root);
    return true;
}

bool TestMalformedBytesSafeDefault() {
    const std::string root =
        TempRoot();
    CHECK(CreateDirectory(root));

    const std::string path =
        root + "/control.plist";
    CHECK(WriteMalformedBytes(path));

    ProductControlSnapshot snapshot;
    CHECK(Load(path, &snapshot));
    CHECK(IsDisabledNoMediaSafe(
        snapshot));

    RemoveTree(root);
    return true;
}

bool TestWrongRootSafeDefault() {
    const std::string root =
        TempRoot();
    CHECK(CreateDirectory(root));

    const std::string path =
        root + "/control.plist";

    CHECK(WritePlistObject(
        path,
        @[@"not", @"a", @"dictionary"]));

    ProductControlSnapshot snapshot;
    CHECK(Load(path, &snapshot));
    CHECK(IsDisabledNoMediaSafe(
        snapshot));

    RemoveTree(root);
    return true;
}

bool TestWrongEnabledType() {
    const std::string root =
        TempRoot();
    CHECK(CreateDirectory(root));

    const std::string path =
        root + "/control.plist";
    NSMutableDictionary* dict =
        ValidVideoDictionary();
    dict[@"enabled"] =
        @"yes";

    CHECK(WritePlistObject(
        path,
        dict));

    ProductControlSnapshot snapshot;
    CHECK(Load(path, &snapshot));
    CHECK(IsDisabledNoMediaSafe(
        snapshot));
    CHECK(
        snapshot.selectionGeneration ==
        7);

    RemoveTree(root);
    return true;
}

bool TestWrongMediaKindType() {
    const std::string root =
        TempRoot();
    CHECK(CreateDirectory(root));

    const std::string path =
        root + "/control.plist";
    NSMutableDictionary* dict =
        ValidVideoDictionary();
    dict[@"mediaKind"] =
        @[@"video"];

    CHECK(WritePlistObject(
        path,
        dict));

    ProductControlSnapshot snapshot;
    CHECK(Load(path, &snapshot));
    CHECK(IsDisabledNoMediaSafe(
        snapshot));
    CHECK(
        snapshot.selectionGeneration ==
        7);

    RemoveTree(root);
    return true;
}

bool TestWrongMediaPathType() {
    const std::string root =
        TempRoot();
    CHECK(CreateDirectory(root));

    const std::string path =
        root + "/control.plist";
    NSMutableDictionary* dict =
        ValidVideoDictionary();
    dict[@"mediaPath"] =
        @{@"path" : @"/tmp/valid.mov"};

    CHECK(WritePlistObject(
        path,
        dict));

    ProductControlSnapshot snapshot;
    CHECK(Load(path, &snapshot));
    CHECK(IsDisabledNoMediaSafe(
        snapshot));

    RemoveTree(root);
    return true;
}

bool TestWrongGenerationType() {
    const std::string root =
        TempRoot();
    CHECK(CreateDirectory(root));

    const std::string path =
        root + "/control.plist";
    NSMutableDictionary* dict =
        ValidVideoDictionary();
    dict[@"selectionGeneration"] =
        @[@"7"];

    CHECK(WritePlistObject(
        path,
        dict));

    ProductControlSnapshot snapshot;
    CHECK(Load(path, &snapshot));
    CHECK(IsDisabledNoMediaSafe(
        snapshot));
    CHECK(
        snapshot.selectionGeneration ==
        0);

    RemoveTree(root);
    return true;
}

bool TestWrongLoopType() {
    const std::string root =
        TempRoot();
    CHECK(CreateDirectory(root));

    const std::string path =
        root + "/control.plist";
    NSMutableDictionary* dict =
        ValidVideoDictionary();
    dict[@"loopEnabled"] =
        @{@"value" : @YES};

    CHECK(WritePlistObject(
        path,
        dict));

    ProductControlSnapshot snapshot;
    CHECK(Load(path, &snapshot));
    CHECK(IsDisabledNoMediaSafe(
        snapshot));

    RemoveTree(root);
    return true;
}

bool TestWrongPlaybackType() {
    const std::string root =
        TempRoot();
    CHECK(CreateDirectory(root));

    const std::string path =
        root + "/control.plist";
    NSMutableDictionary* dict =
        ValidVideoDictionary();
    dict[@"playbackIntent"] =
        @[@"playing"];

    CHECK(WritePlistObject(
        path,
        dict));

    ProductControlSnapshot snapshot;
    CHECK(Load(path, &snapshot));
    CHECK(IsDisabledNoMediaSafe(
        snapshot));

    RemoveTree(root);
    return true;
}

bool TestUnknownMediaKind() {
    const std::string root =
        TempRoot();
    CHECK(CreateDirectory(root));

    const std::string path =
        root + "/control.plist";
    NSMutableDictionary* dict =
        ValidVideoDictionary();
    dict[@"mediaKind"] =
        @"other";

    CHECK(WritePlistObject(
        path,
        dict));

    ProductControlSnapshot snapshot;
    CHECK(Load(path, &snapshot));
    CHECK(snapshot.enabled);
    CHECK(IsNoMediaSafe(snapshot));
    CHECK(
        snapshot.selectionGeneration ==
        7);

    RemoveTree(root);
    return true;
}

bool TestUnknownPlayback() {
    const std::string root =
        TempRoot();
    CHECK(CreateDirectory(root));

    const std::string path =
        root + "/control.plist";
    NSMutableDictionary* dict =
        ValidVideoDictionary();
    dict[@"playbackIntent"] =
        @"mystery";

    CHECK(WritePlistObject(
        path,
        dict));

    ProductControlSnapshot snapshot;
    CHECK(Load(path, &snapshot));
    CHECK(snapshot.enabled);
    CHECK(
        snapshot.mediaKind ==
        ProductMediaKind::Video);
    CHECK(
        snapshot.playbackIntent ==
        ProductPlaybackIntent::Stopped);

    RemoveTree(root);
    return true;
}

bool TestIncompleteMediaIdentityNormalized() {
    const std::string root =
        TempRoot();
    CHECK(CreateDirectory(root));

    const std::string path =
        root + "/control.plist";
    NSMutableDictionary* dict =
        ValidVideoDictionary();
    dict[@"mediaPath"] =
        @"";

    CHECK(WritePlistObject(
        path,
        dict));

    ProductControlSnapshot snapshot;
    CHECK(Load(path, &snapshot));
    CHECK(snapshot.enabled);
    CHECK(IsNoMediaSafe(snapshot));
    CHECK(
        snapshot.selectionGeneration ==
        7);

    RemoveTree(root);
    return true;
}

bool TestPhotoForcesLoopFalse() {
    const std::string root =
        TempRoot();
    CHECK(CreateDirectory(root));

    const std::string path =
        root + "/control.plist";
    NSMutableDictionary* dict =
        ValidVideoDictionary();
    dict[@"mediaKind"] =
        @"photo";
    dict[@"mediaPath"] =
        @"/tmp/valid.png";
    dict[@"loopEnabled"] =
        @YES;

    CHECK(WritePlistObject(
        path,
        dict));

    ProductControlSnapshot snapshot;
    CHECK(Load(path, &snapshot));
    CHECK(
        snapshot.mediaKind ==
        ProductMediaKind::Photo);
    CHECK(!snapshot.loopEnabled);
    CHECK(
        snapshot.playbackIntent ==
        ProductPlaybackIntent::Playing);

    RemoveTree(root);
    return true;
}

bool TestNoMediaForcesPlaybackStopped() {
    const std::string root =
        TempRoot();
    CHECK(CreateDirectory(root));

    const std::string path =
        root + "/control.plist";

    NSDictionary* dict = @{
        @"enabled" : @YES,
        @"mediaKind" : @"none",
        @"mediaPath" : @"",
        @"selectionGeneration" : @11,
        @"loopEnabled" : @YES,
        @"playbackIntent" : @"playing"
    };

    CHECK(WritePlistObject(
        path,
        dict));

    ProductControlSnapshot snapshot;
    CHECK(Load(path, &snapshot));
    CHECK(snapshot.enabled);
    CHECK(IsNoMediaSafe(snapshot));
    CHECK(
        snapshot.selectionGeneration ==
        11);

    RemoveTree(root);
    return true;
}

bool TestValidSnapshotRoundTrip() {
    const std::string root =
        TempRoot();
    CHECK(CreateDirectory(root));

    const std::string path =
        root + "/control.plist";

    SharedControlStore store(
        path,
        "com.vcampro.test.store-hardening.roundtrip");

    ProductControlSnapshot input;
    input.enabled = true;
    input.mediaKind =
        ProductMediaKind::Video;
    input.mediaPath =
        root + "/movie.mov";
    input.selectionGeneration = 42;
    input.loopEnabled = true;
    input.playbackIntent =
        ProductPlaybackIntent::Paused;

    CHECK(store.save(
        input,
        false));

    ProductControlSnapshot output;
    CHECK(store.load(&output));

    CHECK(
        output.enabled ==
        input.enabled);
    CHECK(
        output.mediaKind ==
        input.mediaKind);
    CHECK(
        output.mediaPath ==
        input.mediaPath);
    CHECK(
        output.selectionGeneration ==
        input.selectionGeneration);
    CHECK(
        output.loopEnabled ==
        input.loopEnabled);
    CHECK(
        output.playbackIntent ==
        input.playbackIntent);

    RemoveTree(root);
    return true;
}

bool TestObserverCorruptionFailOpen() {
    const std::string root =
        TempRoot();
    CHECK(CreateDirectory(root));

    const std::string path =
        root + "/control.plist";
    const std::string notification =
        "com.vcampro.test.store-hardening." +
        std::to_string(getpid()) +
        "." +
        ToStd(NSUUID.UUID.UUIDString);

    SharedControlStore store(
        path,
        notification);

    std::mutex mutex;
    std::condition_variable cv;
    int callbacks = 0;
    ProductControlSnapshot observed;

    CHECK(store.startObserving(
        [&](const ProductControlSnapshot&
                snapshot) {
            {
                std::lock_guard<std::mutex>
                    lock(mutex);
                observed = snapshot;
                ++callbacks;
            }
            cv.notify_all();
        }));

    ProductControlSnapshot valid;
    valid.enabled = true;
    valid.mediaKind =
        ProductMediaKind::Photo;
    valid.mediaPath =
        root + "/photo.png";
    valid.selectionGeneration = 9;
    valid.playbackIntent =
        ProductPlaybackIntent::Playing;

    CHECK(store.save(valid));

    {
        std::unique_lock<std::mutex>
            lock(mutex);

        CHECK(cv.wait_for(
            lock,
            std::chrono::seconds(3),
            [&] {
                return callbacks >= 1;
            }));

        CHECK(observed.enabled);
        CHECK(observed.hasMedia());
    }

    CHECK(WriteMalformedBytes(path));
    CHECK(
        notify_post(
            notification.c_str()) ==
        NOTIFY_STATUS_OK);

    {
        std::unique_lock<std::mutex>
            lock(mutex);

        CHECK(cv.wait_for(
            lock,
            std::chrono::seconds(3),
            [&] {
                return callbacks >= 2;
            }));

        CHECK(IsDisabledNoMediaSafe(
            observed));
    }

    store.stopObserving();
    RemoveTree(root);
    return true;
}

void Run(
    const char* name,
    const std::function<bool()>& test) {
    ++gTests;

    const bool passed =
        test();

    std::cout
        << (passed ? "PASS " : "FAIL ")
        << name
        << std::endl;

    if (!passed) {
        ++gFailures;
    }
}

}  // namespace

int main() {
    @autoreleasepool {
        Run(
            "absent plist safe default",
            TestAbsentPlistSafeDefault);
        Run(
            "malformed bytes safe default",
            TestMalformedBytesSafeDefault);
        Run(
            "wrong root safe default",
            TestWrongRootSafeDefault);
        Run(
            "wrong enabled type safe",
            TestWrongEnabledType);
        Run(
            "wrong media kind type safe",
            TestWrongMediaKindType);
        Run(
            "wrong media path type safe",
            TestWrongMediaPathType);
        Run(
            "wrong generation type safe",
            TestWrongGenerationType);
        Run(
            "wrong loop type safe",
            TestWrongLoopType);
        Run(
            "wrong playback type safe",
            TestWrongPlaybackType);
        Run(
            "unknown media kind normalized",
            TestUnknownMediaKind);
        Run(
            "unknown playback normalized",
            TestUnknownPlayback);
        Run(
            "incomplete media identity normalized",
            TestIncompleteMediaIdentityNormalized);
        Run(
            "photo forces loop false",
            TestPhotoForcesLoopFalse);
        Run(
            "no media forces playback stopped",
            TestNoMediaForcesPlaybackStopped);
        Run(
            "valid snapshot round trip",
            TestValidSnapshotRoundTrip);
        Run(
            "observer corruption fail open",
            TestObserverCorruptionFailOpen);

        std::cout
            << "Shared control store hardening tests run: "
            << gTests
            << ", failures: "
            << gFailures
            << std::endl;

        return gFailures == 0
            ? 0
            : 1;
    }
}
