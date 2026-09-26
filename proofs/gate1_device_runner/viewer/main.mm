#import <UIKit/UIKit.h>

#include "Gate1Paths.h"

@interface Gate1ViewController : UIViewController
@property(nonatomic, strong) UILabel* statusLabel;
@property(nonatomic, strong) UITextView* detailsView;
@property(nonatomic, strong) UIButton* shareButton;
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
        [self.shareButton.topAnchor constraintEqualToAnchor:self.detailsView.bottomAnchor
                                                   constant:12.0],
        [self.shareButton.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [self.shareButton.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor
                                                      constant:-20.0],
        [self.shareButton.heightAnchor constraintEqualToConstant:50.0],
    ]];

    [self reloadResult];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadResult];
}

- (void)reloadResult {
    NSError* error = nil;
    NSString* text =
        [NSString stringWithContentsOfFile:
            @(vcam::gate1::kResultTextPath)
                                  encoding:NSUTF8StringEncoding
                                     error:&error];

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
