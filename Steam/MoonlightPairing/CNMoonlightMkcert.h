//
//  mkcert.h
//  Moonlight
//
//  Created by Diego Waxemberg on 10/16/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#ifndef CloudNow_CNMoonlightMkcert_h
#define CloudNow_CNMoonlightMkcert_h

#include <openssl/x509v3.h>
#include <openssl/pkcs12.h>

typedef struct CNMoonlightCertKeyPair {
    X509 *x509;
    EVP_PKEY *pkey;
    PKCS12 *p12;
} CNMoonlightCertKeyPair;

struct CNMoonlightCertKeyPair CNMoonlightGenerateCertKeyPair(void);
void CNMoonlightFreeCertKeyPair(CNMoonlightCertKeyPair);
#endif
