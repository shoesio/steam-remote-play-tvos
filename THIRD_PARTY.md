# Third-party attribution

- IHSlib (https://github.com/mariotaku/ihslib), commit
  `263d4ca2a7ec8ca99e8a36e4f1bc2154d6007898`: Steam protocol reference and
  public-universe RSA authorization key. LGPL-3.0-or-later; see `LICENSES`.
- IHSplay (https://github.com/mariotaku/ihsplay) and Locomo
  (https://github.com/beebono/locomo): protocol and orchestration references.
- SteamTracking protobuf definitions (https://github.com/SteamTracking/Protobufs):
  discovery and Remote Play message definitions.
- PyroWave (https://github.com/Themaister/pyrowave): MIT-licensed codec code;
  source files retain copyright and SPDX notices.
- MoltenVK and the bundled PyroWave runtime provide GPU codec support.
- Codec bridge declarations include Moonlight-derived material. No Moonlight
  session transport is linked; session transport uses Steam Remote Play.
- Valve Steam Link was inspected as a protocol reference. No Valve executable
  is included. Apple Security, CommonCrypto and CryptoKit implement cryptography.

Runtime and source license notices require a full audit before redistribution.
