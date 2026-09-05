# SonoGlass 1.1 audit and Mac installation

Audited September 4, 2026. This review covered the Swift app, Sonos networking,
Pandora session handling, diagnostics, packaging, and fresh-Mac setup. The icon,
local signing, and fading mini-player drag handle that previously existed only
in local work or a handoff branch are included in the main release work.

## Fixed findings

| Area | Problem | Result |
| --- | --- | --- |
| Fresh builds | Scripts assumed one machine's exact CLT/SDK path. | Discover the selected Xcode/CLT and SDK; support isolated output paths. |
| Packaging | Icons and a dependency resource bundle could be absent from source builds. | Track the icon assets and copy CryptoSwift resources into the app. |
| Installation | No repeatable update path or backup. | Verify signatures, reuse the installation location, reject unrelated/running apps, preserve a ZIP backup, and restore the previous app if replacement fails. |
| Sonos state | Old network responses could overwrite a newly selected room. | Invalidate stale polls, discovery, subscriptions, and multistep playback after selection changes or shutdown. |
| Controls | Delayed volume changes or thumbs-down fallback could affect the wrong room/track. | Capture the target room and recheck the live track before fallback skip. |
| Eventing | Cancelled startup could strand a continuation; malformed grants could overflow renewal scheduling. | Handle cancellation/ownership, validate private event endpoints, and bound renewal intervals. |
| Websocket | An established but silent connection could wait indefinitely. | Bound command lifetime and propagate cancellation. |
| Pandora login | Failed verification replaced working credentials. | Verify a candidate before committing it to Keychain and app state. |
| Pandora sessions | Cached web sessions were not tied to the configured account; stale failures could retry for a replacement account. | Bind caches to usernames, discard stale authentication results, and guard retries against account changes. |
| Pandora diagnostics | Feedback success depended on JSON whitespace and logged full response bodies. | Parse the response structure, escape GraphQL strings, omit raw public logs, and actually reauthenticate expired collection requests. |
| Mini player | Saved positions could leave the player off screen after display changes. | Restore/clamp the frame and preserve the nonactivating fading drag handle. |
| Apple Music | Background refresh could prompt repeatedly or refetch absent ratings. | Request permission on explicit actions and deduplicate background lookups. |
| Settings | Last-used room was not restored and room choices omitted grouped members. | Persist the selected room and expose all discovered room choices. |

## Verification

- Swift regression suite: **46 tests in 14 suites** on Apple Silicon, using
  Xcode 26.6 and the macOS 26.5 SDK.
- Tests cover parsers, crypto, authenticated/bounded event requests, held-response
  room-switch/shutdown races, delayed controls, session ownership and stale retry.
  Test transports are isolated and do not access the user's Keychain or send
  speaker commands. Listener tests use an ephemeral local port.
- Local Release and sandbox builds, strict code-signature verification, hardened
  runtime, packaged icon/resources, version metadata, shell/plist validation.
- Installation/update and ZIP integrity in temporary folders; actual running-app
  rejection; unrelated-app protection and rollback with a simulated rename failure.
- GitHub Actions checks both Apple Silicon and Intel macOS runners. The pull
  request is the source for the exact commit and CI result.

## Acceptance on each Mac

Follow the README's clone, build, test, and install commands. Then verify:

1. The installed app opens from its printed location and appears in the menu bar.
2. Allow Local Network access and confirm rooms are discovered; test manual private
   IPv4 fallback when the network blocks multicast.
3. Select a room and check real playback, mute, volume, grouping, and saved content.
4. Show the mini player. Confirm its handle appears on hover, dragging works,
   buttons remain clickable, focus behavior is correct, and its position survives
   relaunch and display changes.
5. If used, verify Pandora login/stations and one intended feedback action against
   the actual account. Apple Music Favorites needs the separate provisioned build.

The audit ran on a Mac Studio. It does not certify installation, permissions,
audio, or physical interaction on another Mac or Vision Pro. The visionOS browser
failure-state fix was reviewed; device acceptance remains separate.

## Delivery boundaries

- This is a source release. The ordinary local build is hardened and ad-hoc signed
  without App Sandbox; it does not require developer credentials. Sandbox is an
  explicit build option. No notarized binary is promised by the source installer.
- The team-signing script validates the embedded profile, hardened runtime, and
  absence of `get-task-allow`. A fresh team-provisioned MusicKit build and real
  Apple Music account acceptance were not performed in this audit.
- Sonos local SOAP and device websocket protocols assume a trusted LAN. Private
  IP checks do not authenticate another device on that LAN. Speaker websocket
  certificates retain the existing private-address-only trust policy.
- Once a speaker command has been transmitted it cannot be recalled. Checking the
  current track before `Next` narrows a race but cannot make two speaker requests
  atomic. Provider/firmware changes can still affect unofficial integrations.
- Current source was checked for common private-key/token patterns. Historical
  GitHub pull-reference cleanup from the earlier public-release audit is a
  separate item and is not certified by this review.
