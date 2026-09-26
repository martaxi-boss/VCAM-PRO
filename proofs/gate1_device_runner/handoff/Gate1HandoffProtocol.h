#pragma once

#import <Foundation/Foundation.h>

#define VCAM_GATE1_MACH_SERVICE_NAME @"com.vcampro.gate1.handoff"

@protocol VCAMGate1HandoffProtocol
- (void)runGate1WithReply:(void (^)(NSString* result))reply;
@end
