# Steam Remote Play for tvOS

Apple TV client that connects directly to Steam Remote Play on your PC.

## Features

- Steam host discovery and PIN pairing.
- PyroWave video decoding and GPU presentation.
- Gamepad input and streaming audio.
- Top Shelf recently played games with direct launch links and library actions.
- HomeKit power-on and preferences in tvOS Settings.

## Build

Open `SteamTV.xcodeproj`, select the SteamTV scheme and your Apple TV, and
configure signing for the app and Top Shelf extension. The app uses shared
App Group and Keychain entitlements; configure those consistently for both targets.

The checked-in app is version 0.1, build 13. Runtime libraries are included in
`Runtime`; protocol code and tests are under `Sources` and `Tests`.

Run protocol tests with `swift test` from this directory.

## Use

Enable Remote Play in Steam on the PC. Configure the host and optional HomeKit
power switch in tvOS Settings, open the app, and complete PIN pairing when asked.
Put the app in the Apple TV Home Screen's top row to access its Top Shelf games.

See [THIRD_PARTY.md](THIRD_PARTY.md) for dependency attribution.
