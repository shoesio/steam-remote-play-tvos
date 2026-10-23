#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CNWakeOnLAN : NSObject

+ (BOOL)sendMagicPacketToMACAddress:(NSString *)macAddress
                               host:(NSString *)host
                           basePort:(NSInteger)basePort NS_SWIFT_NAME(send(macAddress:host:basePort:));

@end

NS_ASSUME_NONNULL_END
