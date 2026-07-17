# SonoGlass — Engineering Log

What was built, in order, and **why** — including the dead ends, because the
dead ends are where the knowledge is. Newest last. (Commit hashes refer to
this repo's history.)

***REMOVED BY PRIVACY REWRITE***

**Goal:** replace the abandoned official Sonos desktop app with a native macOS
menu bar controller whose killer feature is Pandora thumbs — which no shipping
third-party Mac controller has.

- Scaffolded the full app in one pass: `SonosKit` (SSDP + Bonjour discovery,
  SOAP client, DIDL/topology parsers, GENA event listener + polling safety
  net, the `SonosSystem` actor), `PandoraKit` (Pandora JSON API v5 client with
  Blowfish crypto, Keychain storage), SwiftUI popover with
  Now Playing / Favorites / Stations tabs, floating glass mini player
  (non-activating `NSPanel`), Settings, unit tests.
- **Why SwiftPM instead of Xcode:** the Mac had no usable Xcode at the time
  (only Command Line Tools). `scripts/make_app.sh` assembles and ad-hoc-signs
  the bundle.
- **Toolchain landmines** (documented in README): the macOS 27 beta SDK
  macro-izes SwiftUI property wrappers with plugins that only ship inside full
  Xcode → pinned the macOS 26.5 SDK. CLT hides `Testing.framework` →
  `run_tests.sh` passes explicit framework/plugin/rpath flags.
***REMOVED BY PRIVACY REWRITE***
  transport, volume, favorites/playlists/stations playback, events.

***REMOVED BY PRIVACY REWRITE***

The spec assumed track URIs carried Pandora v5 `trackToken`s. Modern firmware
doesn't: cloud-queue URIs (`VC1::ST::ST:{station}::TR:{track}::…`) carry only
catalog ids. Four approaches were tested live, in order:

1. **v5 tuner API** (`station.addFeedback`) — rejects catalog ids
   ("Could not decode track token"). *Dead end.*
2. **Listener GraphQL** (`setFeedback` on pandora.com) — works only to
   *update* existing feedback; new thumbs demand a `trackToken`
   ("Current index or trackToken must be provided"). The one early "success"
   was an update to a track thumbed years ago — a misleading false positive.
   *Dead end (kept for diagnostics).*
***REMOVED BY PRIVACY REWRITE***
   full device-link flow was built and works (gotcha: `getDeviceAuthToken`
   must echo the service-generated `linkDeviceId` from `getAppLink`, or it
   returns NOT_LINKED_RETRY forever). But Pandora's `rateItem` endpoint is a
   **stub**: it answers success and persists nothing (`getExtendedMetadata`
   rating stays 0). *Dead end (code kept — powers the `pandora-probe` CLI).*
***REMOVED BY PRIVACY REWRITE***
   programmed-radio spec, ratings are POSTed *by the player* to the service.
   `wss://{ip}:1443/websocket/api` (public sample API key) exposes
   `playbackMetadata:1 → rate` with the current queue `itemId`; the player
   rates through its own Pandora session. **This is what the official app
   does, and it works — no Pandora credentials or linking needed at all.**
   Verified end-to-end: rating flips to `THUMBSUP/POSITIVE` server-side and
   appears in the account's per-station feedback and the iPhone app.

Verification quirk worth remembering: Pandora's own surfaces disagree —
the iPhone app shows the full feedback store, the v5 per-station lists are
capped, and the pandora.com profile "Thumbs Up" page misses even thumbs made
on pandora.com itself.

***REMOVED BY PRIVACY REWRITE***

- Icon briefly pinned to the two-speaker glyph by request, then restored:
  it's a group-size indicator (one speaker = single room, two = multi-room
  group; fills while playing).

***REMOVED BY PRIVACY REWRITE***

The first version read as a flat die-cut sticker. Fixes: kill the window's
hard shadow and float the glass card in a transparent margin with layered
ambient + contact shadows (margin must fully contain them or the window edge
clips them square — that was a real bug); specular rim gradient (bright
top-left refraction → faint dark bottom edge = perceived thickness); soft top
sheen; Apple's `clear` glass variant instead of frosted; 30 pt continuous
corners.

***REMOVED BY PRIVACY REWRITE***

- ☆ button (popover + mini player) toggles the song's Favorite via MusicKit
  (`PUT/DELETE /v1/me/ratings/songs/{id}`), prefilled from the current rating.
  Catalog id parsed straight from the Sonos track URI
  (`x-sonos-http:song%3a{id}.mp4?sid=204`).
- **Why a second build path:** MusicKit refuses ad-hoc-signed apps. Added
  XcodeGen `project.yml` + `scripts/make_app_signed.sh` (automatic signing,
  `TEAM=<your-team-id>`). Two tricks were required: app-identifier entitlements to
  force an embedded provisioning profile, and
  `-allowProvisioningDeviceRegistration` so xcodebuild could register the Mac.
  Stale dev certificates (keys lost with previous machines) had to be revoked
  once so Xcode could mint a fresh one.
- User-confirmed working on multiple songs.

***REMOVED BY PRIVACY REWRITE***

**Why:** the user's discovery loop was Pandora-on-Sonos → Shazam the speaker →
find the song in Apple Music → favorite/add. SonoGlass already *knows* the
song, so the microphone step is absurd. Design: thumbs stay the quick gesture;
two buttons are the "I *really* like this" gestures — one feeds the permanent
Apple Music library, one enriches Pandora.

- **↗ on Apple Music tracks** — opens the song in the Music app, highlighted
  (`music://music.apple.com/us/song/{id}`, the same deep link Shazam uses).
- **↗ on Pandora tracks** — MusicKit catalog search for the exact
  title + artist (artist-verified match) → opens the result in Music.
- **🌐 on Pandora tracks** — opens the track's canonical backstage page on
  pandora.com (collect, similar artists). Resolved via listener GraphQL
  `entity(id:"TR:n"){ ... on Track { url } }` (the field is `url`/`urlPath` —
  *not* `shareableUrlPath`); falls back to a pandora.com search page.
  Website chosen over the Pandora Mac app deliberately: the app is an Electron
  shell with no deep links; the site has the session and full backstage.
***REMOVED BY PRIVACY REWRITE***
  player and popover: pause → glide to reveal the end → pause → glide back.

## Diagnostic tooling (grew throughout; keep these)

- `sonoglass-diag <ip>` — discovery/topology/now-playing/favorites smoke test.
- `pandora-probe` — `link`/`redeem`/`rate`/`soap`/`gql`/`feedback`/`count`:
  drives SMAPI AppLink, raw SMAPI/GraphQL calls, and per-station feedback
  verification. If Pandora's protocol drifts again, start here.
- `wsprobe` pattern (scratch): raw player-websocket experiments — this is how
  the `rate` command was discovered.

***REMOVED BY PRIVACY REWRITE***

- **Group editor** (⧉ next to the room picker): check a room to pull it into
  the current group (`SetAVTransportURI x-rincon:{coordinatorUDN}` on the
  joining player), uncheck to split it out
  (`BecomeCoordinatorOfStandaloneGroup`). Group ids churn on regroup, so the
  app re-reads topology and re-selects by coordinator UDN.
- **Per-room volume trims**: when a group has >1 member, each room gets its
  own mini slider under the master (member `GetVolume` polled alongside group
  volume; per-player `SetVolume` with the same debounce discipline).
- **Bug fixed the same hour:** moving the master slider *reverted* freshly-set
  trims to old proportions. Cause: Sonos scales `SetGroupVolume` against its
  snapshot of the room mix, and we never refreshed it — the official apps call
  `SnapshotGroupVolume` at the start of every drag. Now sent at the start of
  each adjustment burst (>1.5 s gap = new gesture). User-verified fixed.

## 2026-07-15 — Vision Pro (SonoGlassVision)

Native visionOS target sharing the entire protocol stack (SonosKit/PandoraKit/
MusicKit/player-websocket thumbs port unchanged; AppState platform-shimmed).
Spatial glass window: now-playing, thumbs, Apple Music funnel, group volume +
per-room trims, group editor, favorites/stations, layered app icon, on-device
Pandora sign-in + iCloud-synced credentials/session. Discovery via Bonjour +
manual IP (raw SSDP multicast is entitlement-gated on iOS-family platforms).

**Hard-won lesson:** pandora.com's SPA client-side-404s EVERY route (song,
search, artist) in Vision Pro Safari, while identical URLs work via curl and
Mac Safari — platform sniffing on their end. Attempted fixes that failed:
different route shapes, artist-only URLs, collect-via-GraphQL (mutation arg
schema unknown; also wrong UX). The fix that works: an **in-app WKWebView
window masquerading as Windows Chrome** (`customUserAgent` + desktop content
mode) — Pandora serves the full desktop site inside SonoGlass. Login persists
in the default website data store. Also: visionOS keeps stale app processes
alive behind open windows — always close/reopen after installing a build
(diagnosable via the build number in ⚙️ → Diagnostics).
