#import <UIKit/UIKit.h>

#import "Gate1HandoffProtocol.h"

#include "Gate1Paths.h"

@interface Gate1ViewController : UIViewController
@property(nonatomic, strong) UILabel* statusLabel;
@property(nonatomic, strong) UITextView* detailsView;
@property(nonatomic, strong) UIButton* runButton;
@property(nonatomic, strong) UIButton* shareButton;
@property(nonatomic, strong) NSXPCConnection* handoffConnection;
@property(nonatomic, assign) BOOL runInFlight;
@end

@implementation Gate1ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font =
        [UIFont boldSystemFontOfSize:28.0];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 2;

    self.detailsView = [[UITextView alloc] init];
    self.detailsView.translatesAutoresizingMaskIntoConstraints = NO;
    self.detailsView.editable = NO;
    self.detailsView.font =
        [UIFont monospacedSystemFontOfSize:13.0
                                   weight:UIFontWeightRegular];

    self.runButton =
        [UIButton buttonWithType:UIButtonTypeSystem];
    self.runButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.runButton setTitle:@"Run Gate 1"
                    forState:UIControlStateNormal];
    self.runButton.titleLabel.font =
        [UIFont boldSystemFontOfSize:18.0];
    [self.runButton addTarget:self
                       action:@selector(runGate1)
             forControlEvents:UIControlEventTouchUpInside];

    self.shareButton =
        [UIButton buttonWithType:UIButtonTypeSystem];
    self.shareButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.shareButton setTitle:@"Share Evidence"
                      forState:UIControlStateNormal];
    self.shareButton.titleLabel.font =
        [UIFont boldSystemFontOfSize:18.0];
    [self.shareButton addTarget:self
                         action:@selector(shareEvidence)
               forControlEvents:UIControlEventTouchUpInside];

    [self.view addSubview:self.statusLabel];
    [self.view addSubview:self.detailsView];
    [self.view addSubview:self.runButton];
    [self.view addSubview:self.shareButton];

    UILayoutGuide* safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.statusLabel.topAnchor constraintEqualToAnchor:safe.topAnchor
                                                  constant:24.0],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor
                                                      constant:16.0],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor
                                                       constant:-16.0],
        [self.detailsView.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor
                                                   constant:20.0],
        [self.detailsView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor
                                                       constant:12.0],
        [self.detailsView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor
                                                        constant:-12.0],
        [self.runButton.topAnchor constraintEqualToAnchor:self.detailsView.bottomAnchor
                                                 constant:12.0],
        [self.runButton.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [self.runButton.heightAnchor constraintEqualToConstant:50.0],
        [self.shareButton.topAnchor constraintEqualToAnchor:self.runButton.bottomAnchor
                                                   constant:8.0],
        [self.shareButton.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [self.shareButton.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor
                                                      constant:-20.0],
        [self.shareButton.heightAnchor constraintEqualToConstant:50.0],
    ]];

    [self reloadResult];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (!self.runInFlight) {
        [self reloadResult];
    }
}

- (void)setRunningUI {
    self.runInFlight = YES;
    self.runButton.enabled = NO;
    self.shareButton.enabled = NO;
    self.statusLabel.text = @"RUNNING_GATE_1";
    self.detailsView.text =
        @"reason=OWNER_REQUESTED_GATE_1_RUN\n"
         "gate2_attempted=NO\n";
}

- (void)finishHandoffFailure:(NSString*)reason {
    if (!self.runInFlight) return;
    self.runInFlight = NO;
    self.runButton.enabled = YES;
    self.shareButton.enabled = NO;
    self.statusLabel.text = @"GATE_1_NOT_PROVEN";
    self.detailsView.text =
        [NSString stringWithFormat:
            @"reason=%@\n"
             "gate2_attempted=NO\n",
            reason];
    [self.handoffConnection invalidate];
    self.handoffConnection = nil;
}

- (void)runGate1 {
    if (self.runInFlight) return;
    [self setRunningUI];

    NSXPCConnection* connection =
        [[NSXPCConnection alloc]
            initWithMachServiceName:VCAM_GATE1_MACH_SERVICE_NAME
            options:NSXPCConnectionPrivileged];
    connection.remoteObjectInterface =
        [NSXPCInterface interfaceWithProtocol:
            @protocol(VCAMGate1HandoffProtocol)];

    __weak Gate1ViewController* weakSelf = self;
    connection.interruptionHandler = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf finishHandoffFailure:
                @"PRIVILEGE_HANDOFF_INTERRUPTED"];
        });
    };
    connection.invalidationHandler = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf finishHandoffFailure:
                @"PRIVILEGE_HANDOFF_INVALIDATED"];
        });
    };

    self.handoffConnection = connection;
    [connection resume];

    id<VCAMGate1HandoffProtocol> proxy =
        [connection remoteObjectProxyWithErrorHandler:
            ^(NSError* error) {
                (void)error;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf finishHandoffFailure:
                        @"PRIVILEGE_HANDOFF_UNAVAILABLE"];
                });
            }];

    [proxy runGate1WithReply:^(NSString* result) {
        dispatch_async(dispatch_get_main_queue(), ^{
            Gate1ViewController* strongSelf = weakSelf;
            if (strongSelf == nil || !strongSelf.runInFlight) return;

            strongSelf.runInFlight = NO;
            strongSelf.runButton.enabled = YES;
            [strongSelf.handoffConnection invalidate];
            strongSelf.handoffConnection = nil;

            if ([result isEqualToString:@"COMPLETED"]) {
                [strongSelf reloadResult];
            } else {
                strongSelf.shareButton.enabled = NO;
                strongSelf.statusLabel.text = @"GATE_1_NOT_PROVEN";
                strongSelf.detailsView.text =
                    @"reason=PRIVILEGED_COORDINATOR_FAILED\n"
                     "gate2_attempted=NO\n";
            }
        });
    }];
}

- (void)reloadResult {
    NSError* error = nil;
    NSString* text =
        [NSString stringWithContentsOfFile:
            @(vcam::gate1::kResultTextPath)
                                  encoding:NSUTF8StringEncoding
                                     error:&error];

    self.runButton.enabled = !self.runInFlight;

    if (text == nil || error != nil) {
        self.statusLabel.text = @"GATE_1_NOT_PROVEN";
        self.detailsView.text =
            @"reason=RESULT_FILE_UNAVAILABLE\n"
             "gate2_attempted=NO\n";
        self.shareButton.enabled = NO;
        return;
    }

    NSString* first =
        [[text componentsSeparatedByCharactersInSet:
            NSCharacterSet.newlineCharacterSet] firstObject];
    self.statusLabel.text =
        first.length > 0 ? first : @"GATE_1_NOT_PROVEN";
    self.detailsView.text = text;
    self.shareButton.enabled = YES;
}

- (void)shareEvidence {
    NSURL* textURL =
        [NSURL fileURLWithPath:
            @(vcam::gate1::kResultTextPath)];
    NSURL* jsonURL =
        [NSURL fileURLWithPath:
            @(vcam::gate1::kResultJsonPath)];

    NSMutableArray* items = [NSMutableArray array];
    if ([[NSFileManager defaultManager]
            fileExistsAtPath:textURL.path]) {
        [items addObject:textURL];
    }
    if ([[NSFileManager defaultManager]
            fileExistsAtPath:jsonURL.path]) {
        [items addObject:jsonURL];
    }
    if (items.count == 0) return;

    UIActivityViewController* share =
        [[UIActivityViewController alloc]
            initWithActivityItems:items
            applicationActivities:nil];
    if (share.popoverPresentationController != nil) {
        share.popoverPresentationController.sourceView =
            self.shareButton;
        share.popoverPresentationController.sourceRect =
            self.shareButton.bounds;
    }
    [self presentViewController:share animated:YES completion:nil];
}

@end

@interface Gate1AppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow* window;
@end

@implementation Gate1AppDelegate

- (BOOL)application:(UIApplication*)application
    didFinishLaunchingWithOptions:(NSDictionary*)launchOptions {
    (void)application;
    (void)launchOptions;

    self.window =
        [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController =
        [[Gate1ViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char* argv[]) {
    @autoreleasepool {
        return UIApplicationMain(
            argc,
            argv,
            nil,
            NSStringFromClass([Gate1AppDelegate class]));
    }
}
