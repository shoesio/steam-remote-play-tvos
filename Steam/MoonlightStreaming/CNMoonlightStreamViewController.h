#import <GameController/GameController.h>
#import "CNMoonlightVideoView.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^CNMoonlightVideoViewReadyHandler)(CNMoonlightVideoView *videoView);

@interface CNMoonlightStreamViewController : GCEventViewController

@property (nonatomic, readonly) CNMoonlightVideoView *videoView;
@property (nonatomic, copy, nullable) CNMoonlightVideoViewReadyHandler videoViewReadyHandler;

@end

NS_ASSUME_NONNULL_END
