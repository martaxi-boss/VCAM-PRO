#import <UIKit/UIKit.h>

#include "Gate1Paths.h"

#include <cerrno>
#include <spawn.h>
#include <sys/wait.h>

extern char** environ;

@interface Gate1ViewController : UIViewController
@property(nonatomic, strong) UILabel* statusLabel;
@property(nonatomic, strong) UITextView* detailsView;
@property(nonatomic, strong) UIButton* runButton;
@property(nonatomic, strong) UIButton* shareButton;
@property(nonatomic, assign) BOOL runInFlight;
@property(nonatomic, assign) BOOL fileEvidenceAvailable;
@end

@implementation Gate1ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.runInFlight = NO;
    self.fileEvidenceAvailable = NO;

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
        [UIFont boldSystemFontOfSize:20.0];
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
        [self.shareButton.heightAnchor constraintEqualToConstant:46.0],
    ]];

    [self reloadResult];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (!self.runInFlight) {
        [self reloadResult];
    }
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
        self.fileEvidenceAvailable = NO;
        self.shareButton.enabled = YES;
        return;
    }

    NSString* first =
        [[text componentsSeparatedByCharactersInSet:
            NSCharacterSet.newlineCharacterSet] firstObject];
    self.statusLabel.text =
        first.length > 0 ? first : @"GATE_1_NOT_PROVEN";
    self.detailsView.text = text;
    self.fileEvidenceAvailable = YES;
    self.shareButton.enabled = YES;
}

- (void)showHandoffFailure:(int)code {
    self.statusLabel.text = @"GATE_1_NOT_PROVEN";
    self.detailsView.text =
        [NSString stringWithFormat:
            @"reason=POST_INSTALL_PRIVILEGE_HANDOFF_FAILED\n"
             "handoff_status=%d\n"
             "intentional_restart_requests=0\n"
             "gate2_attempted=NO\n",
             code];
    self.fileEvidenceAvailable = NO;
    self.shareButton.enabled = YES;
}

- (void)runGate1 {
    if (self.runInFlight) return;

    self.runInFlight = YES;
    self.fileEvidenceAvailable = NO;
    self.runButton.enabled = NO;
    self.shareButton.enabled = NO;
    self.statusLabel.text = @"GATE_1_RUNNING";
    self.detailsView.text =
        @"reason=OWNER_REQUESTED_EXPLICIT_RUN\n"
         "gate2_attempted=NO\n";

    dispatch_async(
        dispatch_get_global_queue(
            QOS_CLASS_USER_INITIATED,
            0),
        ^{
            pid_t child = -1;
            char* argv[] = {
                const_cast<char*>(vcam::gate1::kCoordinatorPath),
                nullptr,
            };

            const int spawnStatus =
                posix_spawn(
                    &child,
                    vcam::gate1::kCoordinatorPath,
                    nullptr,
                    nullptr,
                    argv,
                    environ);

            int handoffStatus =
                spawnStatus == 0 ? 255 : spawnStatus;

            if (spawnStatus == 0 && child > 0) {
                int status = 0;
                pid_t waited = -1;
                do {
                    waited = waitpid(child, &status, 0);
                } while (waited < 0 && errno == EINTR);

                if (waited == child && WIFEXITED(status)) {
                    handoffStatus = WEXITSTATUS(status);
                } else if (waited == child && WIFSIGNALED(status)) {
                    handoffStatus = 128 + WTERMSIG(status);
                } else {
                    handoffStatus = 254;
                }
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                self.runInFlight = NO;
                self.runButton.enabled = YES;

                if (handoffStatus == 0) {
                    [self reloadResult];
                } else {
                    [self showHandoffFailure:handoffStatus];
                }
            });
        });
}

- (void)shareEvidence {
    NSMutableArray* items = [NSMutableArray array];

    if (self.fileEvidenceAvailable) {
        NSURL* textURL =
            [NSURL fileURLWithPath:
                @(vcam::gate1::kResultTextPath)];
        NSURL* jsonURL =
            [NSURL fileURLWithPath:
                @(vcam::gate1::kResultJsonPath)];

        if ([[NSFileManager defaultManager]
                fileExistsAtPath:textURL.path]) {
            [items addObject:textURL];
        }
        if ([[NSFileManager defaultManager]
                fileExistsAtPath:jsonURL.path]) {
            [items addObject:jsonURL];
        }
    }

    if (items.count == 0 && self.detailsView.text.length > 0) {
        [items addObject:self.detailsView.text];
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
