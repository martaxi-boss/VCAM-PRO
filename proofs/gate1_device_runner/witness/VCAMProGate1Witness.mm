#import <Foundation/Foundation.h>
#import <OSLog/OSLog.h>

#include "Gate1Paths.h"
#include "WitnessProtocol.h"

#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <unistd.h>

namespace {

using namespace vcam::gate1;

std::uint64_t MonotonicNs() {
    static mach_timebase_info_data_t info = [] {
        mach_timebase_info_data_t value{};
        (void)mach_timebase_info(&value);
        return value;
    }();

    const std::uint64_t ticks = mach_absolute_time();
    return (ticks * info.numer) / info.denom;
}

std::string ReadText(const char* path) {
    @autoreleasepool {
        NSError* error = nil;
        NSString* value =
            [NSString stringWithContentsOfFile:@(path)
                                      encoding:NSUTF8StringEncoding
                                         error:&error];
        if (value == nil || error != nil) return {};
        return std::string([value UTF8String]);
    }
}

void WriteWitness(
    const RunRequest& request,
    pid_t pid,
    std::uint64_t observedAtNs) {
    WitnessRecord record;
    record.schema = "vcam-pro-gate1-witness/1";
    record.nonce = request.nonce;
    record.marker = ExpectedMarkerForPid(pid);
    record.process = "mediaserverd";
    record.pid = pid;
    record.witnessVersion = kWitnessVersion;
    record.observedAtNs = observedAtNs;

    const std::string rendered = RenderWitnessRecord(record);
    if (rendered.empty()) return;

    @autoreleasepool {
        NSString* text =
            [[NSString alloc] initWithBytes:rendered.data()
                                    length:rendered.size()
                                  encoding:NSUTF8StringEncoding];
        if (text == nil) return;
        NSError* error = nil;
        (void)[text writeToFile:@(kWitnessEvidencePath)
                     atomically:YES
                       encoding:NSUTF8StringEncoding
                          error:&error];
    }
}

void ObserveMarker(RunRequest request) {
    @autoreleasepool {
        const pid_t pid = getpid();
        const NSString* expected =
            [NSString stringWithUTF8String:
                ExpectedMarkerForPid(pid).c_str()];

        NSError* storeError = nil;
        OSLogStore* store =
            [OSLogStore storeWithScope:OSLogStoreCurrentProcessIdentifier
                                 error:&storeError];
        if (store == nil || storeError != nil) return;

        NSPredicate* predicate =
            [NSPredicate predicateWithFormat:@"composedMessage == %@",
                                               expected];

        NSError* enumError = nil;
        OSLogEnumerator* enumerator =
            [store entriesEnumeratorWithOptions:0
                                       position:nil
                                      predicate:predicate
                                          error:&enumError];
        if (enumerator == nil || enumError != nil) return;

        NSUInteger inspected = 0;
        for (OSLogEntry* entry in enumerator) {
            if (++inspected > 64) break;
            if (![entry conformsToProtocol:@protocol(OSLogEntryFromProcess)]) {
                continue;
            }

            id<OSLogEntryFromProcess> source =
                (id<OSLogEntryFromProcess>)entry;
            if (source.processIdentifier != pid) continue;
            if (![source.process isEqualToString:@"mediaserverd"]) continue;
            if (![entry.composedMessage isEqualToString:expected]) continue;

            WriteWitness(request, pid, MonotonicNs());
            return;
        }
    }
}

}  // namespace

__attribute__((constructor))
static void VCAMProGate1WitnessStart(void) {
    const char* process = getprogname();
    if (process == nullptr ||
        strcmp(process, "mediaserverd") != 0) {
        return;
    }

    const std::string requestText =
        ReadText(vcam::gate1::kRunRequestPath);
    if (requestText.empty()) return;

    vcam::gate1::RunRequest request;
    if (!vcam::gate1::ParseRunRequest(requestText, &request)) {
        return;
    }

    constexpr std::uint64_t kMaxRequestAgeNs =
        30ULL * 1000ULL * 1000ULL * 1000ULL;
    if (vcam::gate1::ValidateRunRequest(
            request,
            MonotonicNs(),
            kMaxRequestAgeNs) !=
        vcam::gate1::ProtocolStatus::Ok) {
        return;
    }

    dispatch_queue_t queue =
        dispatch_queue_create(
            "com.vcampro.gate1.witness",
            DISPATCH_QUEUE_SERIAL);

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
        queue,
        ^{
            ObserveMarker(request);
        });
}
