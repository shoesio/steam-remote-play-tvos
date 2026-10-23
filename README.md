# Steam Solarflare for Apple TV

Private development repository for the tvOS Steam streaming client, using
Solarflare's PyroWave video path and the existing GPU renderer.

Includes the tvOS app, Settings bundle, Top Shelf extension, ambient lighting,
HomeKit power controls, Moonlight pairing/session code and surround audio.

## Open and build

Open `SolarflareSteam.xcodeproj` in Xcode and select the `Steam` scheme and an
Apple TV destination. Configure your own signing team and provisioning.

The current project references a **local external dependency** at
`../../punktfunk/clients/apple`. That Punktfunk checkout (including its native
framework) is required; this repository alone is not yet a standalone build.
Keep the existing relative folder layout, or update the local package reference
in Xcode to your Punktfunk checkout.

Swift package dependencies are resolved by Xcode. Bundled PyroWave/MoltenVK
runtime files live in `Runtime/PyroWave`; the embed script signs them at build
time. Third-party source and its existing license files remain in `ThirdParty`.

Build caches, personal Xcode state, provisioning profiles and private signing
keys are excluded. Configure host, pairing and HomeKit settings on the device.

This repository preserves the current project as it stands; some legacy code
and host maintenance scripts are retained. Those scripts can contain
machine-specific paths and should be reviewed before use on another host.
