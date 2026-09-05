#!/bin/zsh
# Install a verified local build. Reuses an existing install location, otherwise
# defaults to ~/Applications. An optional argument selects the destination.
# Does not launch. Preserves the previous app in a timestamped ZIP backup.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" == --help ]]; then
  print 'Usage: scripts/install_app.sh [destination-directory]'
  print 'Build first with scripts/make_app.sh (or scripts/make_app_signed.sh).'
  exit 0
fi
(( $# <= 1 )) || { print -u2 'Usage: scripts/install_app.sh [destination-directory]'; exit 1; }
APP="${DIST_DIR:-dist}/SonoGlass.app"
if (( $# == 1 )); then
  INSTALL_DIR="$1"
elif [[ -e "$HOME/Applications/SonoGlass.app" && -e /Applications/SonoGlass.app ]]; then
  print -u2 'ERROR: SonoGlass exists in both ~/Applications and /Applications. Pass the directory of the copy you use.'
  exit 1
elif [[ -e /Applications/SonoGlass.app ]]; then
  INSTALL_DIR=/Applications
else
  INSTALL_DIR="$HOME/Applications"
fi
DESTINATION="$INSTALL_DIR/SonoGlass.app"
if [[ ! -d "$APP" ]]; then
  print -u2 "ERROR: $APP does not exist. Run scripts/make_app.sh first."
  exit 1
fi
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
[[ "$BUNDLE_ID" == com.sonoglass.app ]] || { print -u2 'ERROR: Source is not a SonoGlass bundle.'; exit 1; }
codesign --verify --strict "$APP"
if pgrep -x SonoGlass >/dev/null; then
  print -u2 'ERROR: Quit SonoGlass from its menu bar menu before installing the update.'
  exit 1
fi
if [[ -e "$DESTINATION" || -L "$DESTINATION" ]]; then
  [[ -d "$DESTINATION" && ! -L "$DESTINATION" ]] || { print -u2 "ERROR: Refusing to replace $DESTINATION; it is not an app directory."; exit 1; }
  EXISTING_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DESTINATION/Contents/Info.plist" 2>/dev/null || true)
  [[ "$EXISTING_ID" == com.sonoglass.app ]] || { print -u2 "ERROR: Refusing to replace an unrelated app at $DESTINATION."; exit 1; }
fi
mkdir -p "$INSTALL_DIR"
STAGING=$(mktemp -d "$INSTALL_DIR/.sonoglass-install.XXXXXX")
BACKUP=''
cleanup() {
  if [[ -d "$STAGING/Previous-SonoGlass.app" && ! -e "$DESTINATION" ]]; then
    mv "$STAGING/Previous-SonoGlass.app" "$DESTINATION"
  fi
  rm -rf "$STAGING"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
ditto "$APP" "$STAGING/SonoGlass.app"
codesign --verify --strict "$STAGING/SonoGlass.app"
if [[ -d "$DESTINATION" ]]; then
  BACKUP="$INSTALL_DIR/SonoGlass-backup-$(date +%Y%m%d-%H%M%S)-$$.zip"
  ditto -c -k --sequesterRsrc --keepParent "$DESTINATION" "$BACKUP"
  unzip -tq "$BACKUP" >/dev/null
  mv "$DESTINATION" "$STAGING/Previous-SonoGlass.app"
fi
mv "$STAGING/SonoGlass.app" "$DESTINATION"
print "Installed $DESTINATION"
[[ -z "$BACKUP" ]] || print "Previous version saved at $BACKUP"
print 'Open SonoGlass from this location and allow Local Network access when macOS asks.'
