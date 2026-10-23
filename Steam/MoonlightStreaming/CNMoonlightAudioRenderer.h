#import <Foundation/Foundation.h>

#include "Limelight.h"

NS_ASSUME_NONNULL_BEGIN

@interface CNMoonlightAudioRenderer : NSObject

- (int)setupWithAudioConfiguration:(int)audioConfiguration
                        opusConfig:(const POPUS_MULTISTREAM_CONFIGURATION)opusConfig
                           arFlags:(int)arFlags;
- (void)start;
- (void)stop;
- (void)cleanup;
- (void)decodeAndPlaySample:(char *)sampleData length:(int)sampleLength;

@end

NS_ASSUME_NONNULL_END
