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
