#include "ProductControlOwner.h"
#include "SharedControlStore.h"

#import <Foundation/Foundation.h>

#include <atomic>
#include <condition_variable>
#include <functional>
#include <iostream>
#include <mutex>
#include <string>
#include <thread>

namespace {

using vcam::product::ProductControlOwner;
using vcam::product::ProductControlSnapshot;
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
                        @"vcam-status-safety-%@",
                        NSUUID.UUID.UUIDString]]);
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

bool TestStatusSnapshotIsOwnedAndStable() {
    const std::string root =
        TempRoot();
    CHECK(CreateDirectory(root));

    const std::string controlPath =
        root + "/control.plist";

    ProductControlOwner owner(
        controlPath,
        "com.vcampro.test.status.snapshot",
        root + "/Media");

    CHECK(owner.setEnabled(true));

    const std::string first =
        owner.lastStatus();

    CHECK(first == "VCAM ON.");

    CHECK(owner.setEnabled(false));

    const std::string second =
        owner.lastStatus();

    CHECK(
        first ==
        "VCAM ON.");
    CHECK(
        second ==
        "VCAM OFF — real camera fail-open.");
    CHECK(first != second);

    ProductControlSnapshot persisted;
    SharedControlStore store(
        controlPath,
        "com.vcampro.test.status.snapshot.read");

    CHECK(store.load(&persisted));
    CHECK(!persisted.enabled);
    CHECK(
        owner.snapshot().enabled ==
        persisted.enabled);

    RemoveTree(root);
    return true;
}

class StartGate final {
public:
    void wait() {
        std::unique_lock<std::mutex>
            lock(mutex_);

        ++arrived_;
        condition_.notify_all();

        condition_.wait(
            lock,
            [this] {
                return released_;
            });
    }

    void releaseWhenReady(
        int expected) {
        std::unique_lock<std::mutex>
            lock(mutex_);

        condition_.wait(
            lock,
            [this, expected] {
                return arrived_ ==
                    expected;
            });

        released_ = true;
        lock.unlock();
        condition_.notify_all();
    }

private:
    std::mutex mutex_;
    std::condition_variable condition_;
    int arrived_ = 0;
    bool released_ = false;
};

bool IsKnownEnabledStatus(
    const std::string& value) {
    return
        value == "VCAM ON." ||
        value ==
            "VCAM OFF — real camera fail-open.";
}

bool TestConcurrentStatusReadsAndMutations() {
    const std::string root =
        TempRoot();
    CHECK(CreateDirectory(root));

    const std::string controlPath =
        root + "/control.plist";

    ProductControlOwner owner(
        controlPath,
        "com.vcampro.test.status.concurrent",
        root + "/Media");

    CHECK(owner.setEnabled(false));

    StartGate start;
    std::atomic<bool> writerDone{false};
    std::atomic<int> invalidReads{0};
    std::atomic<int> readCount{0};

    std::thread writer(
        [&] {
            start.wait();

            for (int index = 0;
                 index < 250;
                 ++index) {
                const bool enabled =
                    (index % 2) == 0;

                if (!owner.setEnabled(
                        enabled)) {
                    invalidReads.fetch_add(
                        100000,
                        std::memory_order_relaxed);
                    break;
                }
            }

            writerDone.store(
                true,
                std::memory_order_release);
        });

    std::thread reader(
        [&] {
            start.wait();

            do {
                const std::string status =
                    owner.lastStatus();

                if (!IsKnownEnabledStatus(
                        status)) {
                    invalidReads.fetch_add(
                        1,
                        std::memory_order_relaxed);
                }

                readCount.fetch_add(
                    1,
                    std::memory_order_relaxed);
            } while (
                !writerDone.load(
                    std::memory_order_acquire));

            for (int index = 0;
                 index < 64;
                 ++index) {
                const std::string status =
                    owner.lastStatus();

                if (!IsKnownEnabledStatus(
                        status)) {
                    invalidReads.fetch_add(
                        1,
                        std::memory_order_relaxed);
                }

                readCount.fetch_add(
                    1,
                    std::memory_order_relaxed);
            }
        });

    start.releaseWhenReady(2);

    writer.join();
    reader.join();

    CHECK(
        invalidReads.load(
            std::memory_order_relaxed) ==
        0);
    CHECK(
        readCount.load(
            std::memory_order_relaxed) >
        0);

    CHECK(owner.setEnabled(true));

    const ProductControlSnapshot memory =
        owner.snapshot();

    ProductControlSnapshot persisted;
    SharedControlStore store(
        controlPath,
        "com.vcampro.test.status.concurrent.read");

    CHECK(store.load(&persisted));
    CHECK(memory.enabled);
    CHECK(persisted.enabled);
    CHECK(
        owner.lastStatus() ==
        "VCAM ON.");

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
            "status snapshot remains owned and stable",
            TestStatusSnapshotIsOwnedAndStable);
        Run(
            "concurrent status reads and mutations safe",
            TestConcurrentStatusReadsAndMutations);

        std::cout
            << "Product control status tests run: "
            << gTests
            << ", failures: "
            << gFailures
            << std::endl;

        return gFailures == 0
            ? 0
            : 1;
    }
}
