#import <Foundation/Foundation.h>

#import "CNMoonlightVideoView.h"

#include "Limelight.h"

NS_ASSUME_NONNULL_BEGIN

@interface CNMoonlightVideoRenderer : NSObject

- (instancetype)initWithVideoView:(CNMoonlightVideoView *)videoView
                    useFramePacing:(BOOL)useFramePacing
           adaptiveBitrateEnabled:(BOOL)adaptiveBitrateEnabled
                bitrateCeilingKbps:(NSInteger)bitrateCeilingKbps
                         targetFPS:(NSInteger)targetFPS;
- (int)setupWithVideoFormat:(int)videoFormat width:(int)width height:(int)height redrawRate:(int)redrawRate;
- (void)start;
- (void)stop;
- (void)cleanup;
- (int)submitDecodeUnit:(PDECODE_UNIT)decodeUnit;

@end

NS_ASSUME_NONNULL_END
