import Foundation

// Valve's public-universe authorization key, as recorded by IHSlib at
// 263d4ca2a7ec8ca99e8a36e4f1bc2154d6007898 (client/pubkeys.h).
// The SPKI wrapper is removed because Security imports PKCS#1 RSA keys.
// Source attribution and LGPL-3.0 terms are in THIRD_PARTY.md and LICENSES/.
enum SteamPublicKey {
    static let pkcs1 = Data(base64Encoded: "MIIBCAKCAQEAx7iQLqQkm17hJPpGiOpb/QJHtQpiKk2pm1zomiuqs3S4bwOroZ+mX9yGys5GpE61q0IaadEDeMO4ZyPfwjlb6kqznauRJ2Hj40OrmCSwRW5X2rre/aTRwcerKF5kfbEYi8z47+WKdZXM3TGEXAz3W4q0snB9IY721GoRXQhfzHVKdcUN2NAYk2z16WQsZkVjfsO1CUgRuc7tsX0jR4HOVEXC3bOKeHyVhRIWfXovPzR5rCchqt2YEZ7oMvMhxinGVyQ0okL1r/UTB87aCCMu9WRg1PGRyPSISj4qFDYXEAxDz1WtH8fHBSB9hoaXzJsj3u1GB2MvfqVNSYmDPckg5wIBEQ==")!
}
