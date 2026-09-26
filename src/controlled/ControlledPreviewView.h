#pragma once

#import <UIKit/UIKit.h>

#ifdef __cplusplus
namespace vcam::controlled {
class ControlledRuntime;
}
#endif

NS_ASSUME_NONNULL_BEGIN

@interface VCAMControlledPreviewView : UIView

#ifdef __cplusplus
- (instancetype)initWithRuntime:
    (vcam::controlled::ControlledRuntime*)runtime
    NS_DESIGNATED_INITIALIZER;
#endif

- (instancetype)initWithFrame:(CGRect)frame
    NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder*)coder
    NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
