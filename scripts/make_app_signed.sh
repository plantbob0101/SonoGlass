#!/bin/zsh
# Optional team-signed build for MusicKit (Apple Music favorites).
#   TEAM=<team-id> scripts/make_app_signed.sh  # existing signing assets only
#   SIGNING_STYLE=Manual TEAM=<team-id> SIGNING_IDENTITY=<identity> \
#     PROFILE=<profile-name-or-uuid> scripts/make_app_signed.sh
# See docs/MAC_MIGRATION.md for provisioning and explicit automatic-signing opt-ins.
# Requires full Xcode, XcodeGen, and an account/profile for com.sonoglass.app
# with the MusicKit service enabled at developer.apple.com.
set -euo pipefail
cd "$(dirname "$0")/.."

SANDBOX="${SANDBOX:-0}"
DERIVED_DATA="${DERIVED_DATA:-.build/xcode}"
DIST_DIR="${DIST_DIR:-dist}"
TEAM="${TEAM:-${DEVELOPMENT_TEAM:-}}"
SIGNING_STYLE="${SIGNING_STYLE:-Automatic}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Apple Development}"
PROFILE="${PROFILE:-}"
ALLOW_PROVISIONING_UPDATES="${ALLOW_PROVISIONING_UPDATES:-0}"
ALLOW_DEVICE_REGISTRATION="${ALLOW_DEVICE_REGISTRATION:-0}"
[[ "$SANDBOX" == 0 || "$SANDBOX" == 1 ]] || { print -u2 'ERROR: SANDBOX must be 0 or 1.'; exit 1; }
[[ -n "$TEAM" ]] || { print -u2 'ERROR: Set TEAM to your Apple Developer team ID.'; exit 1; }
[[ "$SIGNING_STYLE" == Manual || "$SIGNING_STYLE" == Automatic ]] || { print -u2 'ERROR: SIGNING_STYLE must be Manual or Automatic.'; exit 1; }
[[ "$ALLOW_PROVISIONING_UPDATES" == 0 || "$ALLOW_PROVISIONING_UPDATES" == 1 ]] || { print -u2 'ERROR: ALLOW_PROVISIONING_UPDATES must be 0 or 1.'; exit 1; }
[[ "$ALLOW_DEVICE_REGISTRATION" == 0 || "$ALLOW_DEVICE_REGISTRATION" == 1 ]] || { print -u2 'ERROR: ALLOW_DEVICE_REGISTRATION must be 0 or 1.'; exit 1; }
if [[ "$SIGNING_STYLE" == Manual ]]; then
  [[ -n "$PROFILE" ]] || { print -u2 'ERROR: Manual signing requires PROFILE (installed profile name or UUID).'; exit 1; }
  [[ "$ALLOW_PROVISIONING_UPDATES" == 0 && "$ALLOW_DEVICE_REGISTRATION" == 0 ]] || { print -u2 'ERROR: Manual signing uses existing assets; automatic provisioning flags are not allowed.'; exit 1; }
elif [[ -n "$PROFILE" ]]; then
  print -u2 'ERROR: Set SIGNING_STYLE=Manual when selecting PROFILE.'
  exit 1
fi
if [[ "$ALLOW_DEVICE_REGISTRATION" == 1 && "$ALLOW_PROVISIONING_UPDATES" != 1 ]]; then
  print -u2 'ERROR: Device registration requires ALLOW_PROVISIONING_UPDATES=1 too.'
  exit 1
fi
command -v xcodegen >/dev/null || { print -u2 'ERROR: Install XcodeGen first (brew install xcodegen).'; exit 1; }
xcodebuild -version >/dev/null || { print -u2 'ERROR: Select a licensed full Xcode installation using DEVELOPER_DIR.'; exit 1; }
xcodegen

ARGS=(-project SonoGlass.xcodeproj -scheme SonoGlass -configuration Release
      -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA"
      "SONOGLASS_TEAM=$TEAM" "SONOGLASS_SIGNING_STYLE=$SIGNING_STYLE"
      "SONOGLASS_SIGNING_IDENTITY=$SIGNING_IDENTITY" "SONOGLASS_PROFILE=$PROFILE")
[[ "$ALLOW_PROVISIONING_UPDATES" == 0 ]] || ARGS+=(-allowProvisioningUpdates)
[[ "$ALLOW_DEVICE_REGISTRATION" == 0 ]] || ARGS+=(-allowProvisioningDeviceRegistration)
if [[ "$SANDBOX" == 1 ]]; then
  ARGS+=(SONOGLASS_ENTITLEMENTS=Resources/SonoGlass-signed.entitlements SONOGLASS_SANDBOX=YES)
else
  ARGS+=(SONOGLASS_ENTITLEMENTS=Resources/SonoGlass-local.entitlements SONOGLASS_SANDBOX=NO)
fi
ARGS+=(build)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
if ! xcodebuild "${ARGS[@]}" > "$WORK/build.log" 2>&1; then
  tail -80 "$WORK/build.log" >&2
  print -u2 'ERROR: Team-signed build failed. Check the Xcode account, team and MusicKit-enabled App ID.'
  exit 1
fi

APP="$DERIVED_DATA/Build/Products/Release/SonoGlass.app"
[[ -d "$APP" ]] || { print -u2 'ERROR: Xcode did not produce SonoGlass.app.'; exit 1; }
codesign --verify --strict "$APP"
SIGNATURE_DETAILS=$(codesign -dv --verbose=4 "$APP" 2>&1)
if [[ "$SIGNATURE_DETAILS" != *"runtime"* ]]; then
  print -u2 'ERROR: refusing to publish an app without hardened runtime.'
  exit 1
fi
if [[ ! -f "$APP/Contents/embedded.provisionprofile" ]]; then
  print -u2 'ERROR: MusicKit requires an embedded provisioning profile. Check the team and App ID.'
  exit 1
fi
# The :- form requests plist XML; plain - can emit a human-readable dictionary
# on newer macOS versions, which PlistBuddy cannot safely validate.
codesign -d --entitlements :- "$APP" > "$WORK/entitlements.plist" 2>/dev/null
plutil -lint "$WORK/entitlements.plist" >/dev/null
GET_TASK_ALLOW=$(/usr/libexec/PlistBuddy \
  -c 'Print :com.apple.security.get-task-allow' "$WORK/entitlements.plist" 2>/dev/null || true)
if [[ "$GET_TASK_ALLOW" == true ]]; then
  print -u2 'ERROR: refusing to publish a development-debuggable app (get-task-allow=true).'
  exit 1
fi

mkdir -p "$DIST_DIR"
STAGING=$(mktemp -d "$DIST_DIR/.sonoglass-signed.XXXXXX")
trap 'rm -rf "$WORK" "$STAGING"' EXIT
ditto "$APP" "$STAGING/SonoGlass.app"
codesign --verify --strict "$STAGING/SonoGlass.app"
rm -rf "$DIST_DIR/SonoGlass.app"
mv "$STAGING/SonoGlass.app" "$DIST_DIR/SonoGlass.app"
print "Built $DIST_DIR/SonoGlass.app (team-signed, hardened runtime, App Sandbox=$SANDBOX)"
print -r -- "$SIGNATURE_DETAILS" | sed -n '/^Authority=/p; /^TeamIdentifier=/p'
