#import "CNMoonlightStreamViewController.h"

@interface CNMoonlightStreamViewController ()
@property (nonatomic, strong, readwrite) CNMoonlightVideoView *videoView;
@end

@implementation CNMoonlightStreamViewController

- (void)loadView {
    self.controllerUserInteractionEnabled = NO;

    CNMoonlightVideoView *videoView = [[CNMoonlightVideoView alloc] initWithFrame:CGRectZero];
    videoView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    videoView.backgroundColor = UIColor.clearColor;
    videoView.clipsToBounds = YES;
    self.videoView = videoView;
    self.view = videoView;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    self.controllerUserInteractionEnabled = NO;
    [self.videoView setNeedsLayout];
    [self.videoView layoutIfNeeded];
    [self.videoView becomeFirstResponder];
    if (self.videoViewReadyHandler) {
        self.videoViewReadyHandler(self.videoView);
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self.videoView setNeedsLayout];
}

@end
