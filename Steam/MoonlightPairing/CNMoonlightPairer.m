#import "CNMoonlightPairer.h"
#import "CNMoonlightCryptoManager.h"

#import <Security/Security.h>

static NSString * const CNMoonlightPairerErrorDomain = @"CloudNow.MoonlightPairer";
// Steam is a separate Moonlight client and must not collide with Stream's
// paired identity on Sunshine. This stable value is unique to the Steam app.
static NSString * const CNMoonlightUniqueID = @"535445414D54564F";

@interface CNMoonlightPairXML : NSObject <NSXMLParserDelegate>
@property (nonatomic) NSInteger statusCode;
@property (nonatomic, copy) NSString *statusMessage;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *values;
@property (nonatomic, copy) NSString *currentElement;
@property (nonatomic, strong) NSMutableString *currentValue;
@end

@implementation CNMoonlightPairXML

- (instancetype)init {
    self = [super init];
    if (self) {
        _statusCode = -1;
        _statusMessage = @"Sunshine did not return a status.";
        _values = [NSMutableDictionary dictionary];
        _currentValue = [NSMutableString string];
    }
    return self;
}

- (void)parser:(NSXMLParser *)parser
didStartElement:(NSString *)elementName
  namespaceURI:(NSString *)namespaceURI
 qualifiedName:(NSString *)qName
    attributes:(NSDictionary<NSString *,NSString *> *)attributeDict {
    if (_statusCode == -1 && attributeDict[@"status_code"]) {
        _statusCode = [attributeDict[@"status_code"] integerValue];
        _statusMessage = attributeDict[@"status_message"] ?: (_statusCode == 200 ? @"OK" : _statusMessage);
    }
    _currentElement = elementName;
    [_currentValue setString:@""];
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
    [_currentValue appendString:string];
}

- (void)parser:(NSXMLParser *)parser
 didEndElement:(NSString *)elementName
  namespaceURI:(NSString *)namespaceURI
 qualifiedName:(NSString *)qName {
    NSString *value = [_currentValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (value.length > 0) {
        _values[elementName] = value;
    }
    _currentElement = nil;
    [_currentValue setString:@""];
}

- (NSString *)stringForTag:(NSString *)tag {
    return _values[tag];
}

- (NSInteger)integerForTag:(NSString *)tag fallback:(NSInteger)fallback {
    NSString *value = [self stringForTag:tag];
    return value.length > 0 ? value.integerValue : fallback;
}

@end

@implementation CNMoonlightPairingResult

- (instancetype)initWithAlreadyPaired:(BOOL)alreadyPaired
                 serverCertificateDER:(NSData *)serverCertificateDER
                              hostName:(NSString *)hostName
                             uniqueId:(NSString *)uniqueId
                             httpsPort:(NSInteger)httpsPort {
    self = [super init];
    if (self) {
        _alreadyPaired = alreadyPaired;
        _serverCertificateDER = serverCertificateDER;
        _hostName = hostName;
        _uniqueId = uniqueId;
        _httpsPort = httpsPort;
    }
    return self;
}

@end

@interface CNMoonlightPairer () <NSURLSessionDelegate>
@property (nonatomic, copy) NSString *address;
@property (nonatomic) NSInteger httpPort;
@property (nonatomic) NSInteger httpsPort;
@property (nonatomic, copy) NSString *deviceName;
@property (nonatomic, strong, nullable) NSData *serverCertificateDER;
@end

@implementation CNMoonlightPairer

- (instancetype)initWithAddress:(NSString *)address
                       httpPort:(NSInteger)httpPort
                      httpsPort:(NSInteger)httpsPort
                     deviceName:(NSString *)deviceName {
    self = [super init];
    if (self) {
        _address = [address copy];
        _httpPort = httpPort;
        _httpsPort = httpsPort;
        _deviceName = [deviceName copy];
    }
    return self;
}

- (CNMoonlightPairingResult *)pairWithPIN:(NSString *)pin error:(NSError **)error {
    [CNMoonlightCryptoManager generateKeyPairUsingSSL];

    NSData *clientCert = [CNMoonlightCryptoManager readCertFromFile];
    if (!clientCert) {
        [self setError:error message:@"CloudNow could not create a Moonlight client certificate." code:1];
        return nil;
    }

    CNMoonlightPairXML *serverInfo = [self fetchXML:[self httpURLWithPath:@"/serverinfo" query:nil] timeout:5 error:error];
    if (!serverInfo) {
        return nil;
    }
    if (serverInfo.statusCode != 200) {
        [self setError:error message:serverInfo.statusMessage code:serverInfo.statusCode];
        return nil;
    }

    NSString *hostName = [serverInfo stringForTag:@"hostname"];
    NSString *uniqueId = [serverInfo stringForTag:@"uniqueid"];
    NSString *appVersion = [serverInfo stringForTag:@"appversion"];
    NSString *state = [serverInfo stringForTag:@"state"];
    NSInteger reportedHttpsPort = [serverInfo integerForTag:@"HttpsPort" fallback:_httpsPort];
    if (reportedHttpsPort > 0) {
        _httpsPort = reportedHttpsPort;
    }

    if ([[serverInfo stringForTag:@"PairStatus"] isEqualToString:@"1"]) {
        return [[CNMoonlightPairingResult alloc] initWithAlreadyPaired:YES
                                                  serverCertificateDER:nil
                                                               hostName:hostName
                                                              uniqueId:uniqueId
                                                              httpsPort:_httpsPort];
    }

    if (appVersion.length == 0) {
        [self setError:error message:@"Sunshine did not report an app version." code:2];
        return nil;
    }

    NSInteger serverMajorVersion = [[appVersion substringToIndex:1] integerValue];
    NSData *salt = [self randomBytes:16];
    NSMutableData *saltedPIN = [NSMutableData dataWithData:salt];
    [saltedPIN appendData:[pin dataUsingEncoding:NSUTF8StringEncoding]];

    CNMoonlightPairXML *pairResponse = [self fetchXML:[self httpURLWithPath:@"/pair" query:@{
        @"uniqueid": CNMoonlightUniqueID,
        @"devicename": _deviceName,
        @"updateState": @"1",
        @"phrase": @"getservercert",
        @"salt": [self hexForData:salt],
        @"clientcert": [self hexForData:clientCert]
    }] timeout:180 error:error];
    if (![self verifyPairedResponse:pairResponse error:error fallback:[state hasSuffix:@"_SERVER_BUSY"] ? @"Sunshine is busy. Quit the running stream on the host, then try pairing again." : @"Pairing was declined by Sunshine."]) {
        return nil;
    }

    NSString *plainCert = [pairResponse stringForTag:@"plaincert"];
    if (plainCert.length == 0) {
        [self setError:error message:@"Another Sunshine pairing attempt is already in progress." code:3];
        return nil;
    }

    NSData *plainCertData = [self dataForHex:plainCert];
    NSData *serverCertDER = [CNMoonlightCryptoManager pemToDer:plainCertData];
    if (!serverCertDER) {
        [self setError:error message:@"CloudNow could not read Sunshine's server certificate." code:4];
        return nil;
    }
    _serverCertificateDER = serverCertDER;

    CNMoonlightCryptoManager *crypto = [[CNMoonlightCryptoManager alloc] init];
    NSData *aesKey = serverMajorVersion >= 7 ? [crypto createAESKeyFromSaltSHA256:saltedPIN] : [crypto createAESKeyFromSaltSHA1:saltedPIN];
    NSInteger hashLength = serverMajorVersion >= 7 ? 32 : 20;

    NSData *randomChallenge = [self randomBytes:16];
    NSData *encryptedChallenge = [crypto aesEncrypt:randomChallenge withKey:aesKey];

    CNMoonlightPairXML *challengeResponse = [self fetchXML:[self httpURLWithPath:@"/pair" query:@{
        @"uniqueid": CNMoonlightUniqueID,
        @"devicename": _deviceName,
        @"updateState": @"1",
        @"clientchallenge": [self hexForData:encryptedChallenge]
    }] timeout:5 error:error];
    if (![self verifyPairedResponse:challengeResponse error:error fallback:@"Pairing stage 2 failed."]) {
        return nil;
    }

    NSData *encryptedServerChallenge = [self dataForHex:[challengeResponse stringForTag:@"challengeresponse"]];
    NSData *decryptedServerChallenge = [crypto aesDecrypt:encryptedServerChallenge withKey:aesKey];
    if (decryptedServerChallenge.length < hashLength + 16) {
        [self setError:error message:@"Sunshine returned an incomplete pairing challenge." code:5];
        return nil;
    }

    NSData *serverResponse = [decryptedServerChallenge subdataWithRange:NSMakeRange(0, hashLength)];
    NSData *serverChallenge = [decryptedServerChallenge subdataWithRange:NSMakeRange(hashLength, 16)];
    NSData *clientSecret = [self randomBytes:16];

    NSMutableData *challengeHashInput = [NSMutableData dataWithData:serverChallenge];
    [challengeHashInput appendData:[CNMoonlightCryptoManager getSignatureFromCert:clientCert]];
    [challengeHashInput appendData:clientSecret];
    NSData *challengeHash = serverMajorVersion >= 7 ? [crypto SHA256HashData:challengeHashInput] : [crypto SHA1HashData:challengeHashInput];
    NSMutableData *paddedHash = [NSMutableData dataWithData:challengeHash];
    [paddedHash setLength:32];

    CNMoonlightPairXML *secretResponse = [self fetchXML:[self httpURLWithPath:@"/pair" query:@{
        @"uniqueid": CNMoonlightUniqueID,
        @"devicename": _deviceName,
        @"updateState": @"1",
        @"serverchallengeresp": [self hexForData:[crypto aesEncrypt:paddedHash withKey:aesKey]]
    }] timeout:5 error:error];
    if (![self verifyPairedResponse:secretResponse error:error fallback:@"Pairing stage 3 failed."]) {
        return nil;
    }

    NSData *serverSecretResponse = [self dataForHex:[secretResponse stringForTag:@"pairingsecret"]];
    if (serverSecretResponse.length <= 16) {
        [self setError:error message:@"Sunshine returned an incomplete pairing secret." code:6];
        return nil;
    }

    NSData *serverSecret = [serverSecretResponse subdataWithRange:NSMakeRange(0, 16)];
    NSData *serverSignature = [serverSecretResponse subdataWithRange:NSMakeRange(16, serverSecretResponse.length - 16)];
    if (![crypto verifySignature:serverSecret withSignature:serverSignature andCert:plainCertData]) {
        [self setError:error message:@"Sunshine's server certificate did not verify." code:7];
        return nil;
    }

    NSMutableData *serverHashInput = [NSMutableData dataWithData:randomChallenge];
    [serverHashInput appendData:[CNMoonlightCryptoManager getSignatureFromCert:plainCertData]];
    [serverHashInput appendData:serverSecret];
    NSData *serverHash = serverMajorVersion >= 7 ? [crypto SHA256HashData:serverHashInput] : [crypto SHA1HashData:serverHashInput];
    if (![serverHash isEqualToData:serverResponse]) {
        [self setError:error message:@"Sunshine rejected the PIN." code:8];
        return nil;
    }

    NSMutableData *clientPairingSecret = [NSMutableData dataWithData:clientSecret];
    [clientPairingSecret appendData:[crypto signData:clientSecret withKey:[CNMoonlightCryptoManager readKeyFromFile]]];

    CNMoonlightPairXML *clientSecretResponse = [self fetchXML:[self httpURLWithPath:@"/pair" query:@{
        @"uniqueid": CNMoonlightUniqueID,
        @"devicename": _deviceName,
        @"updateState": @"1",
        @"clientpairingsecret": [self hexForData:clientPairingSecret]
    }] timeout:5 error:error];
    if (![self verifyPairedResponse:clientSecretResponse error:error fallback:@"Pairing stage 4 failed."]) {
        return nil;
    }

    CNMoonlightPairXML *pairChallenge = [self fetchXML:[self httpsURLWithPath:@"/pair" query:@{
        @"uniqueid": CNMoonlightUniqueID,
        @"devicename": _deviceName,
        @"updateState": @"1",
        @"phrase": @"pairchallenge"
    }] timeout:5 error:error];
    if (![self verifyPairedResponse:pairChallenge error:error fallback:@"Pairing stage 5 failed."]) {
        return nil;
    }

    return [[CNMoonlightPairingResult alloc] initWithAlreadyPaired:NO
                                              serverCertificateDER:serverCertDER
                                                           hostName:hostName
                                                          uniqueId:uniqueId
                                                          httpsPort:_httpsPort];
}

- (BOOL)verifyPairedResponse:(CNMoonlightPairXML *)response error:(NSError **)error fallback:(NSString *)fallback {
    if (!response) {
        return NO;
    }
    if (response.statusCode != 200) {
        [self setError:error message:response.statusMessage ?: fallback code:response.statusCode];
        return NO;
    }
    if (![[response stringForTag:@"paired"] isEqualToString:@"1"]) {
        [self setError:error message:fallback code:9];
        return NO;
    }
    return YES;
}

- (CNMoonlightPairXML *)fetchXML:(NSURL *)url timeout:(NSTimeInterval)timeout error:(NSError **)error {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = timeout;
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];

    __block NSData *responseData = nil;
    __block NSError *responseError = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *taskError) {
        responseData = data;
        responseError = taskError;
        dispatch_semaphore_signal(semaphore);
    }] resume];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    [session invalidateAndCancel];

    if (responseError) {
        [self setError:error message:responseError.localizedDescription code:responseError.code];
        return nil;
    }
    if (!responseData) {
        [self setError:error message:@"Sunshine returned an empty response." code:10];
        return nil;
    }

    NSString *xmlString = [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding];
    if (xmlString) {
        xmlString = [xmlString stringByReplacingOccurrencesOfString:@"UTF-16" withString:@"UTF-8" options:NSCaseInsensitiveSearch range:NSMakeRange(0, xmlString.length)];
        responseData = [xmlString dataUsingEncoding:NSUTF8StringEncoding];
    }

    CNMoonlightPairXML *xml = [[CNMoonlightPairXML alloc] init];
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:responseData];
    parser.delegate = xml;
    if (![parser parse]) {
        [self setError:error message:@"CloudNow could not read Sunshine's pairing response." code:11];
        return nil;
    }
    return xml;
}

- (NSURL *)httpURLWithPath:(NSString *)path query:(NSDictionary<NSString *, NSString *> *)query {
    return [self urlWithScheme:@"http" port:_httpPort path:path query:query];
}

- (NSURL *)httpsURLWithPath:(NSString *)path query:(NSDictionary<NSString *, NSString *> *)query {
    return [self urlWithScheme:@"https" port:_httpsPort path:path query:query];
}

- (NSURL *)urlWithScheme:(NSString *)scheme port:(NSInteger)port path:(NSString *)path query:(NSDictionary<NSString *, NSString *> *)query {
    NSURLComponents *components = [[NSURLComponents alloc] init];
    components.scheme = scheme;
    components.host = _address;
    components.port = @(port);
    components.path = path;
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    for (NSString *key in query) {
        [items addObject:[NSURLQueryItem queryItemWithName:key value:query[key]]];
    }
    components.queryItems = items;
    return components.URL;
}

- (NSData *)randomBytes:(NSUInteger)count {
    NSMutableData *data = [NSMutableData dataWithLength:count];
    int result = SecRandomCopyBytes(kSecRandomDefault, count, data.mutableBytes);
    return result == errSecSuccess ? data : [NSMutableData dataWithLength:count];
}

- (NSString *)hexForData:(NSData *)data {
    const unsigned char *bytes = data.bytes;
    NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger index = 0; index < data.length; index++) {
        [hex appendFormat:@"%02X", bytes[index]];
    }
    return hex;
}

- (NSData *)dataForHex:(NSString *)hex {
    NSMutableData *data = [NSMutableData dataWithCapacity:hex.length / 2];
    for (NSUInteger index = 0; index + 1 < hex.length; index += 2) {
        NSString *byteString = [hex substringWithRange:NSMakeRange(index, 2)];
        unsigned int byteValue = 0;
        [[NSScanner scannerWithString:byteString] scanHexInt:&byteValue];
        unsigned char byte = (unsigned char)byteValue;
        [data appendBytes:&byte length:1];
    }
    return data;
}

- (void)setError:(NSError **)error message:(NSString *)message code:(NSInteger)code {
    if (error) {
        *error = [NSError errorWithDomain:CNMoonlightPairerErrorDomain
                                     code:code
                                 userInfo:@{NSLocalizedDescriptionKey: message ?: @"Moonlight pairing failed."}];
    }
}

- (SecIdentityRef)clientIdentity {
    NSData *p12 = [CNMoonlightCryptoManager readP12FromFile];
    if (!p12) {
        return nil;
    }

    NSDictionary *options = @{(__bridge id)kSecImportExportPassphrase: @"limelight"};
    CFArrayRef items = nil;
    OSStatus status = SecPKCS12Import((__bridge CFDataRef)p12, (__bridge CFDictionaryRef)options, &items);
    if (status != errSecSuccess || CFArrayGetCount(items) == 0) {
        if (items) {
            CFRelease(items);
        }
        return nil;
    }

    CFDictionaryRef identityDictionary = CFArrayGetValueAtIndex(items, 0);
    SecIdentityRef identity = (SecIdentityRef)CFRetain(CFDictionaryGetValue(identityDictionary, kSecImportItemIdentity));
    CFRelease(items);
    return identity;
}

- (void)URLSession:(NSURLSession *)session
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler {
    NSString *method = challenge.protectionSpace.authenticationMethod;
    if ([method isEqualToString:NSURLAuthenticationMethodServerTrust] && _serverCertificateDER) {
        SecTrustRef trust = challenge.protectionSpace.serverTrust;
        SecCertificateRef actualCert = SecTrustGetCertificateAtIndex(trust, 0);
        if (actualCert) {
            CFDataRef actualCertData = SecCertificateCopyData(actualCert);
            BOOL matches = CFEqual(actualCertData, (__bridge CFDataRef)_serverCertificateDER);
            CFRelease(actualCertData);
            if (matches) {
                completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:trust]);
                return;
            }
        }
        completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
        return;
    }

    if ([method isEqualToString:NSURLAuthenticationMethodClientCertificate]) {
        SecIdentityRef identity = [self clientIdentity];
        if (identity) {
            SecCertificateRef certificate = nil;
            SecIdentityCopyCertificate(identity, &certificate);
            NSArray *certificates = certificate ? @[(__bridge_transfer id)certificate] : @[];
            NSURLCredential *credential = [NSURLCredential credentialWithIdentity:identity certificates:certificates persistence:NSURLCredentialPersistenceForSession];
            CFRelease(identity);
            completionHandler(NSURLSessionAuthChallengeUseCredential, credential);
            return;
        }
    }

    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}

@end
