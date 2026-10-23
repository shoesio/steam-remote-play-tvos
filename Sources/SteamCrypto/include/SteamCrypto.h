#pragma once
#include <stdint.h>
#include <stddef.h>
uint32_t steam_crc32c(const uint8_t *input, size_t count);

// Steam symmetric envelope: AES-ECB(IV) followed by AES-CBC-PKCS7(payload).
// Returns 0 on success, an Apple CommonCrypto status otherwise.
int steam_encrypt(const uint8_t *input, size_t count, const uint8_t key[32],
                  const uint8_t iv[16], uint8_t *output, size_t *output_count);
int steam_decrypt(const uint8_t *input, size_t count, const uint8_t key[32],
                  uint8_t *output, size_t *output_count);

/* Session control frames carry an authenticated plaintext IV, unlike escrow. */
int steam_frame_decrypt(const uint8_t *input, size_t count, const uint8_t *key,
                        size_t key_count, uint8_t *output, size_t *output_count);
int steam_frame_encrypt(const uint8_t *input, size_t count, const uint8_t *key,
                        size_t key_count, uint8_t *output, size_t *output_count);
