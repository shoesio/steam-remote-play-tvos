#include "SteamCrypto.h"
#include <CommonCrypto/CommonCryptor.h>
#include <string.h>
#if defined(__aarch64__)
#include <arm_acle.h>
__attribute__((target("crc")))
#endif
uint32_t steam_crc32c(const uint8_t *input, size_t count) {
    uint32_t crc = UINT32_MAX;
#if defined(__aarch64__)
    while (count >= 8) {
        uint64_t word;
        memcpy(&word, input, sizeof(word));
        crc = __crc32cd(crc, word);
        input += 8; count -= 8;
    }
    while (count--) crc = __crc32cb(crc, *input++);
#else
    while (count--) {
        crc ^= *input++;
        for (int bit = 0; bit < 8; ++bit) crc = (crc >> 1) ^ ((crc & 1) ? 0x82f63b78 : 0);
    }
#endif
    return ~crc;
}

int steam_encrypt(const uint8_t *input, size_t count, const uint8_t key[32],
                  const uint8_t iv[16], uint8_t *output, size_t *output_count) {
    if (!key || !iv || !output || !output_count || *output_count < 32) return kCCParamError;
    size_t written = 0;
    CCCryptorStatus result = CCCrypt(kCCEncrypt, kCCAlgorithmAES, kCCOptionECBMode,
        key, 32, NULL, iv, 16, output, 16, &written);
    if (result != kCCSuccess || written != 16) return result ? result : kCCDecodeError;
    result = CCCrypt(kCCEncrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding,
        key, 32, iv, input, count, output + 16, *output_count - 16, &written);
    if (result == kCCSuccess) *output_count = written + 16;
    return result;
}

int steam_decrypt(const uint8_t *input, size_t count, const uint8_t key[32],
                  uint8_t *output, size_t *output_count) {
    if (!input || !key || !output || !output_count || count < 32 || count % 16) return kCCParamError;
    uint8_t iv[16];
    size_t written = 0;
    CCCryptorStatus result = CCCrypt(kCCDecrypt, kCCAlgorithmAES, kCCOptionECBMode,
        key, 32, NULL, input, 16, iv, 16, &written);
    if (result != kCCSuccess || written != 16) return result ? result : kCCDecodeError;
    result = CCCrypt(kCCDecrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding,
        key, 32, iv, input + 16, count - 16, output, *output_count, &written);
    if (result == kCCSuccess) *output_count = written;
    return result;
}

#include <CommonCrypto/CommonHMAC.h>
#include <string.h>
int steam_frame_decrypt(const uint8_t *input, size_t count, const uint8_t *key,
                        size_t key_count, uint8_t *output, size_t *output_count) {
    if (!input || !key || !output || !output_count || count < 32 || count % 16 ||
        (key_count != 16 && key_count != 32)) return kCCParamError;
    size_t written = 0;
    CCCryptorStatus result = CCCrypt(kCCDecrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding,
        key, key_count, input, input + 16, count - 16, output, *output_count, &written);
    if (result != kCCSuccess || written < 8) return result ? result : kCCDecodeError;
    uint8_t hash[16];
    CCHmac(kCCHmacAlgMD5, key, key_count, output, written, hash);
    unsigned mismatch = 0;
    for (unsigned i = 0; i < 16; ++i) mismatch |= hash[i] ^ input[i];
    if (mismatch) {
        memset(output, 0, written);
        return kCCDecodeError;
    }
    *output_count = written;
    return kCCSuccess;
}

int steam_frame_encrypt(const uint8_t *input, size_t count, const uint8_t *key,
                        size_t key_count, uint8_t *output, size_t *output_count) {
    if (!input || !key || !output || !output_count || count < 8 || *output_count < count + 32 ||
        (key_count != 16 && key_count != 32)) return kCCParamError;
    CCHmac(kCCHmacAlgMD5, key, key_count, input, count, output);
    size_t written = 0;
    CCCryptorStatus result = CCCrypt(kCCEncrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding,
        key, key_count, output, input, count, output + 16, *output_count - 16, &written);
    if (result == kCCSuccess) *output_count = written + 16;
    return result;
}
