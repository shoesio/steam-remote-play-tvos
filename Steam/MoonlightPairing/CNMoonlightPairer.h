#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CNMoonlightPairingResult : NSObject

@property (nonatomic, readonly) BOOL alreadyPaired;
@property (nonatomic, readonly, nullable) NSData *serverCertificateDER;
@property (nonatomic, readonly, nullable) NSString *hostName;
@property (nonatomic, readonly, nullable) NSString *uniqueId;
@property (nonatomic, readonly) NSInteger httpsPort;

- (instancetype)initWithAlreadyPaired:(BOOL)alreadyPaired
                 serverCertificateDER:(nullable NSData *)serverCertificateDER
                              hostName:(nullable NSString *)hostName
                             uniqueId:(nullable NSString *)uniqueId
                             httpsPort:(NSInteger)httpsPort;

@end

@interface CNMoonlightPairer : NSObject

- (instancetype)initWithAddress:(NSString *)address
                       httpPort:(NSInteger)httpPort
                      httpsPort:(NSInteger)httpsPort
                     deviceName:(NSString *)deviceName;

- (nullable CNMoonlightPairingResult *)pairWithPIN:(NSString *)pin error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
