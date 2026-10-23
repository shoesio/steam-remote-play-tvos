#import "CNWakeOnLAN.h"

#import <arpa/inet.h>
#import <netdb.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>

@implementation CNWakeOnLAN

+ (BOOL)sendMagicPacketToMACAddress:(NSString *)macAddress
                               host:(NSString *)host
                           basePort:(NSInteger)basePort {
    NSData *payload = [self payloadForMACAddress:macAddress];
    if (payload == nil || host.length == 0) {
        return NO;
    }

    NSMutableOrderedSet<NSString *> *addresses = [NSMutableOrderedSet orderedSetWithObjects:host, @"255.255.255.255", nil];
    NSArray<NSString *> *octets = [host componentsSeparatedByString:@"."];
    if (octets.count == 4) {
        BOOL validIPv4 = YES;
        for (NSString *octet in octets) {
            NSScanner *scanner = [NSScanner scannerWithString:octet];
            NSInteger value = -1;
            validIPv4 &= [scanner scanInteger:&value] && scanner.isAtEnd && value >= 0 && value <= 255;
        }
        if (validIPv4) {
            NSString *directedBroadcast = [NSString stringWithFormat:@"%@.%@.%@.255", octets[0], octets[1], octets[2]];
            [addresses addObject:directedBroadcast];
        }
    }
    const NSInteger standardPorts[] = {9, 47009};
    const NSInteger gameStreamPorts[] = {47998, 47999, 48000, 48002, 48010};
    BOOL sentAny = NO;

    for (NSString *address in addresses) {
        struct addrinfo hints = {0};
        hints.ai_family = AF_INET;
        hints.ai_socktype = SOCK_DGRAM;
        hints.ai_protocol = IPPROTO_UDP;

        struct addrinfo *results = NULL;
        if (getaddrinfo(address.UTF8String, NULL, &hints, &results) != 0 || results == NULL) {
            continue;
        }

        for (struct addrinfo *result = results; result != NULL; result = result->ai_next) {
            int socketFD = socket(result->ai_family, SOCK_DGRAM, IPPROTO_UDP);
            if (socketFD < 0) {
                continue;
            }

            int enabled = 1;
            setsockopt(socketFD, SOL_SOCKET, SO_BROADCAST, &enabled, sizeof(enabled));

            struct sockaddr_in destination = *(const struct sockaddr_in *)result->ai_addr;
            for (NSUInteger index = 0; index < sizeof(standardPorts) / sizeof(standardPorts[0]); index++) {
                destination.sin_port = htons((uint16_t)standardPorts[index]);
                sentAny |= sendto(socketFD, payload.bytes, payload.length, 0,
                                  (const struct sockaddr *)&destination, sizeof(destination)) == (ssize_t)payload.length;
            }
            for (NSUInteger index = 0; index < sizeof(gameStreamPorts) / sizeof(gameStreamPorts[0]); index++) {
                NSInteger port = gameStreamPorts[index] - 47989 + basePort;
                if (port < 1 || port > UINT16_MAX) {
                    continue;
                }
                destination.sin_port = htons((uint16_t)port);
                sentAny |= sendto(socketFD, payload.bytes, payload.length, 0,
                                  (const struct sockaddr *)&destination, sizeof(destination)) == (ssize_t)payload.length;
            }
            close(socketFD);
        }
        freeaddrinfo(results);
    }

    return sentAny;
}

+ (nullable NSData *)payloadForMACAddress:(NSString *)macAddress {
    NSCharacterSet *separators = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet];
    NSString *compact = [[macAddress componentsSeparatedByCharactersInSet:separators] componentsJoinedByString:@""];
    if (compact.length != 12) {
        return nil;
    }

    uint8_t mac[6] = {0};
    for (NSUInteger index = 0; index < 6; index++) {
        NSString *pair = [compact substringWithRange:NSMakeRange(index * 2, 2)];
        unsigned value = 0;
        NSScanner *scanner = [NSScanner scannerWithString:pair];
        if (![scanner scanHexInt:&value]) {
            return nil;
        }
        mac[index] = (uint8_t)value;
    }

    NSMutableData *payload = [NSMutableData dataWithLength:102];
    uint8_t *bytes = payload.mutableBytes;
    memset(bytes, 0xFF, 6);
    for (NSUInteger repetition = 0; repetition < 16; repetition++) {
        memcpy(bytes + 6 + repetition * sizeof(mac), mac, sizeof(mac));
    }
    return payload;
}

@end
