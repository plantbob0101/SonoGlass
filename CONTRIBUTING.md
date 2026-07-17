# Contributing to SonoGlass

Thanks for your interest! This is a personal project shared in the hope it's
useful — issues and PRs are welcome, but responses may be sporadic.

## Ground rules

- **No secrets in commits.** Never commit Pandora/Apple credentials, your
  developer Team ID, household IDs, or auth tokens. All of those live in the
  macOS/visionOS Keychain at runtime, never in source.
- **Local protocols only.** SonoGlass deliberately uses no Sonos cloud account.
  Keep new features on the local-network / documented-API path.
- **Test against real hardware when you can.** Much of this talks to live
  speakers; the unit tests cover parsers and crypto, not the network layer.

## Building

macOS app (no Xcode needed):

```sh
scripts/make_app.sh          # ad-hoc signed → dist/SonoGlass.app
scripts/run_tests.sh         # unit tests
```

macOS with Apple Music Favorites, or the visionOS app (needs Xcode + an Apple
Developer account with MusicKit enabled on your App ID):

```sh
TEAM=<your-team-id> scripts/make_app_signed.sh          # signed Mac app
# visionOS: xcodegen && xcodebuild -scheme SonoGlassVision ... (see CHANGELOG)
```

The signed script only publishes a hardened Release bundle and fails closed if
Xcode injects the development-only `get-task-allow` entitlement. Do not weaken
that check for a distributable artifact; use Xcode's Debug configuration for
local debugging instead.

You'll need to change the bundle identifier (`com.sonoglass.app`) to your own
before signing — Apple App IDs are unique per developer account.

## Where things live

- `Sources/SonosKit` — discovery, SOAP/UPnP, topology, eventing, `SonosSystem`
- `Sources/PandoraKit` — Pandora v5 + listener GraphQL + SMAPI clients, crypto
- `Sources/App` — shared SwiftUI + macOS app shell
- `Sources/VisionApp` — the visionOS spatial UI
- `Sources/DiagCLI`, `Sources/ProbeCLI` — diagnostic tools; start here when a
  provider changes its API

## Diagnosing protocol breakage

If Pandora or Sonos changes something, the CLIs reproduce each API call in
isolation:

```sh
swift run sonoglass-diag <speaker-ip>
swift run pandora-probe <speaker-ip> <subcommand>
```

See `CHANGELOG.md` for the full map of which API does what and why the working
paths were chosen.

## Running on Vision Pro

There's no App Store listing — you build and sideload with your own Apple ID
(free or paid), which is the standard path for open-source visionOS apps:

1. **Enable Developer Mode** on the Vision Pro: Settings → Privacy & Security
   → Developer Mode (it reboots the device).
2. **Pair it with your Mac**: open Xcode → Window → Devices and Simulators;
   put the headset on and accept the pairing prompt.
3. **Make the app yours**: in `project.yml`, change
   `PRODUCT_BUNDLE_IDENTIFIER` (both targets) from `com.sonoglass.app` to your
   own reverse-DNS id, then run `xcodegen`.
4. **Build & install**:
   ```sh
   xcodegen
   xcodebuild -project SonoGlass.xcodeproj -scheme SonoGlassVision \
     -destination 'generic/platform=visionOS' \
     -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
     DEVELOPMENT_TEAM=<your-team-id> build
   xcrun devicectl list devices        # find your headset's identifier
   xcrun devicectl device install app --device <identifier> \
     <path-to>/SonoGlassVision.app
   ```
   (Or just open the project in Xcode, select the SonoGlassVision scheme and
   your headset, and press Run.)

**Free vs. paid Apple ID:** with a free account the install expires after
7 days (rebuild/reinstall to renew) and Apple Music Favorites won't authorize
(MusicKit requires a paid membership + the MusicKit App Service enabled on
your App ID). Everything else — Sonos control, Pandora thumbs, grouping,
per-room volume, the in-app Pandora browser — needs no accounts at all.

**Gotcha:** after reinstalling over a running app, visionOS may keep the old
process alive behind the open window. Close the window, wait a few seconds,
and reopen. The build number in ⚙️ → Diagnostics tells you what's actually
running.
