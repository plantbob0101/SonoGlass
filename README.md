# SonoGlass

A native macOS menu bar app that controls Sonos speakers over the **local network only**
(UPnP/SOAP — no Sonos account, no Sonos cloud API), with first-class **Pandora thumbs
up / thumbs down**, a floating always-on-top **mini player**, and browsing/playback of
**Sonos Favorites, Sonos Playlists, and your Pandora station list**.

Favorites live on the speakers; Pandora stations and thumbs use your Pandora
credentials (Keychain). No Sonos login exists anywhere in this app.

## Building

No Xcode required — Command Line Tools are enough.

```sh
scripts/make_app.sh            # release build → dist/SonoGlass.app (sandboxed, ad-hoc signed)
open dist/SonoGlass.app
```

Variants:

```sh
SANDBOX=0 scripts/make_app.sh  # build without App Sandbox (try this if discovery fails)
CONFIG=debug scripts/make_app.sh
scripts/run_tests.sh           # unit tests (16 tests)
swift run sonoglass-diag [ip]  # CLI protocol smoke test against your real speakers
```

**Toolchain note:** the build pins the **macOS 26.5 SDK**
(`/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`). The macOS 27 beta SDK
turns SwiftUI property wrappers into compiler macros whose plugins only ship inside
full Xcode, so plain CLT builds fail against it. If you install Xcode 27 later you can
drop the pin. `scripts/run_tests.sh` uses SwiftPM's native build system and passes
explicit framework/plugin/rpath flags for CLT's out-of-the-way `Testing.framework`.

## First launch

1. The menu bar shows a speaker icon (no Dock icon — it's an `LSUIElement` app).
2. macOS asks for **Local Network** permission on first discovery. If you declined it:
   System Settings → Privacy & Security → Local Network → enable SonoGlass, then
   hit **Retry** in the popover.
3. If multicast discovery still finds nothing (unusual networks, VLANs), enter one
   speaker's IP under Settings → Advanced — one reachable player bootstraps the whole
   household, because topology is read from the player itself.

## Pandora

- Settings → Pandora: e-mail + password, **Verify & Save** does a live login and
  reports Pandora's actual error message on failure.
- Credentials are stored in the **login Keychain** (`SonoGlass.Pandora`), never in
  UserDefaults. "Remove account" deletes them.
- While a Pandora station plays, thumbs appear in the popover and mini player:
  - 👍 calls `station.addFeedback(isPositive: true)` — icon fills for the rest of the track.
  - 👎 calls `addFeedback(isPositive: false)` and then skips (Pandora convention).
  - Previous is hidden for Pandora radio (can't rewind); Next stays (it's a skip).
- The **Stations** tab lists your full station list (`user.getStationList`) in
  Pandora's order (QuickMix/Thumbprint first). Selecting one plays it on the current
  group — via the matching Sonos Favorite's stored metadata when one exists, otherwise
  via a constructed `x-sonosapi-radio:` URI + DIDL.

### Debug trick

**Option-click the album art** (popover or mini player) to copy the raw station +
track URIs to the clipboard. If thumbs ever stop parsing on a future firmware, this
shows the exact URI shape in seconds. Settings → Advanced → "Copy diagnostics" grabs
the full picture (groups, transport, URIs, event health).

## How playback of saved content works

- **Favorites (`FV:2`)** and **Playlists (`SQ:`)** are read from any player over
  ContentDirectory `Browse` — this is the same mechanism "guest mode" controllers use.
- Every favorite carries `r:resMD`, the exact DIDL metadata Sonos stored for it; it is
  passed through verbatim (never hand-built).
- Stream-type favorites (`x-sonosapi-stream/radio/hls`, `x-rincon-mp3radio`,
  `hls-radio`, `aac`) → `SetAVTransportURI` + `Play` on the group coordinator.
- Container-type favorites (`x-rincon-cpcontainer`, `file:` saved queues) → replace
  queue (`RemoveAllTracksFromQueue` → `AddURIToQueue` → point transport at
  `x-rincon-queue:{coordinator}#0` → `Seek` → `Play`).
- Unknown schemes try the stream path first, then fall back to the container path.

## Live updates

UPnP GENA subscriptions (AVTransport + rendering control + topology) deliver push
events to a local HTTP listener; subscriptions renew at half their granted timeout.
A polling safety net runs regardless — every 5 s normally, dropping to 1 s
automatically if eventing is unhealthy (Settings → Advanced shows which mode is
active). The UI never silently goes stale.

## Repo layout

```
Sources/App/        @main, AppState, SwiftUI popover/mini player/settings (UI/ subfolder)
Sources/SonosKit/   SSDP+Bonjour discovery, SOAP client, DIDL/topology parsers,
                    GENA eventing, SonosSystem actor
Sources/PandoraKit/ Pandora JSON API v5 client, Blowfish crypto, token parser, Keychain
Sources/DiagCLI/    sonoglass-diag — protocol smoke test CLI
Tests/              unit tests (token parsing, crypto, DIDL, topology, classifier)
Resources/          Info.plist, entitlements
scripts/            make_app.sh, run_tests.sh
```

## Phase 2 — not built yet (deliberately)

1. **Apple Music love/dislike.** Sketch: Apple Music track URIs look like
   `x-sonos-http:song%3a{catalogSongId}.mp4?sid=204...`. Extract the catalog id, then
   MusicKit (`MusicAuthorization.request()` + `MusicDataRequest`) to
   `PUT /v1/me/ratings/songs/{id}` with `{"type":"rating","attributes":{"value":1}}`
   (or `-1`). Needs a provisioning profile with MusicKit enabled. Verify the live URI
   shape with the Option-click copier first.
2. Media-key / global keyboard shortcuts.
3. Grouping editor, sleep timer, current-queue view (`Q:0`), widgets,
   Shortcuts/AppleScript.
4. Deep service catalog browse/search (SMAPI device-link auth — fragile; favorites +
   stations cover daily use).
5. Sonos cloud OAuth for out-of-home control.
6. Multiple Pandora accounts / households.
