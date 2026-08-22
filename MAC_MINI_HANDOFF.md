# Mac mini handoff

## Host boundary

This branch was prepared on **Robert's Mac Studio** (`Mac13,1`, Apple M1 Max),
not on the destination Mac mini. Do not treat any earlier claim of Mac mini
installation or visual acceptance as valid.

The canonical `main` checkout and production configuration were not edited by
this worktree. However, `/Applications/SonoGlass.app` on the Mac Studio was
incorrectly replaced during the failed deployment attempt. Do not use that
installation as evidence for the Mac mini.

## What is in this branch

- macOS app-icon resources and Xcode asset-catalog wiring
- `.icns` copying for the script-built local app bundle
- a local, placeholder-only signing-entitlements file (no certificate, key, or
  credential material)
- mini-player frame restoration and active-screen clamping
- a panel-level mouse-drag implementation intended to avoid SwiftUI consuming
  background drag events
- launch behavior that presents the floating mini player immediately

## Verification performed

- `swift test`: 32 tests passed in 11 suites on the Mac Studio
- Release build completed with Xcode 26.6 and the macOS 26.5 SDK
- strict code-signature verification passed for the Mac Studio build
- no Mac mini installation or user acceptance was completed

## Required Mac mini acceptance

The Mac mini session must build and install from this branch on the Mac mini,
then verify all of the following on that physical machine:

1. Launchpad shows the custom SonoGlass icon, not the generic app placeholder.
2. The floating mini player can be dragged with a real mouse from its
   non-control surface and remains at the new position after relaunch.
3. Playback controls remain clickable after the drag change.
4. Sonos discovery and control work on the Mac mini's local network.
5. Any Local Network, Keychain, or signing prompt is handled by Robert; no
   credentials should be copied from the Mac Studio.

The icon and drag behaviors are **not accepted** until those checks pass on the
Mac mini.
