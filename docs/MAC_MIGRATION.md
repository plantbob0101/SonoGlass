# Moving SonoGlass to another Mac

A development-signed app copied from another Mac can have a valid signature yet
fail before its interface opens because the embedded profile excludes the new
Mac. Rebuild for the destination Mac with a profile that covers its device and
signing certificate. This guide covers local development installation; notarized
distribution and release automation remain separate work.

## Choose the build you need

The ordinary `scripts/make_app.sh` build supports Sonos controls and Pandora. To
keep **Apple Music Favorites**, use `scripts/make_app_signed.sh`, full Xcode,
XcodeGen, and an Apple Developer team with the MusicKit App Service enabled for
`com.sonoglass.app`. Do not replace a MusicKit build with the ordinary ad-hoc build
as a migration workaround if you need Favorites.

Preserve the source checkout, uncommitted work, existing installed app, settings,
and Keychain entries. Keep private keys, credentials, provisioning profiles,
device identifiers, and private diagnostic evidence outside Git. Avoid revoking
an old Mac's certificate during migration: [profiles containing a revoked
certificate become invalid](https://developer.apple.com/help/account/certificates/revoke-a-certificate/),
and the old app/rollback may still depend on it.

## Prepare the destination Mac

1. Verify which Mac you are actually using with `scutil --get ComputerName`,
   `system_profiler SPHardwareDataType`, and `uname -m`. Keep identifiers private.
2. Install/select a compatible full Xcode and install XcodeGen. Check
   `xcodebuild -version` and `xcrun --sdk macosx --show-sdk-version`. A per-command
   `DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer` selects a toolchain without
   changing the system selection. Keep the compiler and SDK from that toolchain.
3. Sign into the intended Apple account in Xcode Settings → Apple Accounts and
   confirm the team. If access is suspended for an updated agreement, the
   [Account Holder must review and accept it](https://developer.apple.com/help/account/access/resolving-access-issues/).
   A signed-in account alone does not prove device/profile coverage.
4. In Xcode's certificate manager, use an existing usable Apple Development
   identity or create one on this Mac when needed. Let Xcode store the private
   key in the login Keychain; do not copy another Mac's private key into Git.
   [Xcode certificate management](https://help.apple.com/xcode/mac/current/en.lproj/dev154b28f09.html).
5. Check `security find-identity -v -p codesigning`. A certificate visible in the
   manager or a matching identity is insufficient: the identity must be **valid**.
   Leave unexpected Keychain or privacy prompts for the Mac's owner to review.

### If a matching identity is not valid

Check certificate expiry and its issuer chain before recreating identities or
changing trust. Xcode normally installs the required [Apple WWDR intermediate](https://developer.apple.com/help/account/certificates/wwdr-intermediate-certificates/).
If that specific intermediate is missing, obtain its public certificate from
[Apple's certificate authority page](https://www.apple.com/certificateauthority/).
Use the issuer appropriate to your signing certificate; do not assume every
identity uses the same WWDR generation.

For example, for a leaf issued by WWDR G3, inspect the official downloaded public
certificate locally:

```sh
openssl x509 -inform DER -in /private/path/AppleWWDRCAG3.cer \
  -noout -subject -issuer -dates -fingerprint -sha256
security verify-cert -c /private/path/AppleWWDRCAG3.cer -p basic
```

Confirm the issuer/generation, validity and Apple chain, and compare the public
certificate fingerprint with trusted Apple certificate metadata or a known-good
chain. Record the fingerprint locally. Only if the required intermediate is
absent, import that verified **public intermediate** into the destination login
Keychain with default system trust:

```sh
security import /private/path/AppleWWDRCAG3.cer \
  -k "$HOME/Library/Keychains/login.keychain-db"
security find-identity -v -p codesigning
```

This is an explicit Keychain change, not a build step. Do not install a new root,
set an Always Trust override, weaken certificate validation, export private keys,
or change Keychain access controls to work around a failed identity. Stop if the
normal Apple chain still fails validation.

## Prepare a bounded development profile

Use the intended team in the authenticated Apple Developer portal:

1. Inspect the existing explicit App ID `com.sonoglass.app`. Under **App Services**,
   confirm **MusicKit** is enabled. Preserve other services. [Apple's MusicKit
   setup](https://developer.apple.com/help/account/services/musickit/).
2. Compare the destination device identifier against registered devices. For an
   **Apple silicon Mac, use its Provisioning UDID**, visible in System Information
   → Hardware; do not substitute the hardware UUID. If absent, an Account Holder
   or Admin can register that Mac with platform macOS and a recognizable name.
   [Apple device registration](https://developer.apple.com/help/account/devices/register-a-single-device/).
3. Create a **new macOS App Development** profile for the existing App ID. For a
   single-Mac migration select only the destination Mac and its intended signing
   certificate; leave older profiles/certificates intact. Give the new profile a
   recognizable device/date name. [Apple profile creation](https://developer.apple.com/help/account/provisioning-profiles/create-a-development-provisioning-profile/).
4. Download and install the profile using Xcode. Inspect the downloaded CMS locally:

   ```sh
   security cms -D -i /private/path/SonoGlass.provisionprofile \
     > /private/path/SonoGlass-profile.plist
   plutil -p /private/path/SonoGlass-profile.plist
   ```

   Check `TeamIdentifier`, `Entitlements.com.apple.application-identifier`,
   `ExpirationDate`, `ProvisionedDevices`, and `DeveloperCertificates`. Match the
   device against this Mac and the certificate fingerprint against the valid
   signing identity. For the bounded migration, expect one device and one
   certificate. MusicKit is an App Service on the App ID; the generated profile
   need not contain a separately named MusicKit entitlement. Keep this decoded
   metadata private. [Xcode-managed profiles do not appear in the portal's
   profile list](https://developer.apple.com/help/account/provisioning-profiles/edit-download-or-delete-profiles/).

Registration and profile generation change the team's development access; review
the exact device, certificate and App ID before submitting. This guide and the
build script do not accept agreements, create identities, import certificates,
register devices or update profiles automatically by default.

## Build with existing signing assets

Use your own team ID, valid certificate SHA-1 (from `security find-identity`),
and installed profile name or UUID. These are caller inputs, not repository
configuration. Run the regression suite, then a manual Release build:

```sh
scripts/run_tests.sh
SIGNING_STYLE=Manual TEAM='<your-team-id>' \
  SIGNING_IDENTITY='<your-valid-certificate-sha1>' \
  PROFILE='<your-installed-profile-name-or-uuid>' \
  DERIVED_DATA=/private/tmp/sonoglass-signed-build \
  DIST_DIR=/private/tmp/sonoglass-signed-dist \
  scripts/make_app_signed.sh
```

Keep `DIST_DIR` as a build-output directory, separate from the installed app.
The script checks the signature, hardened runtime, embedded profile presence and
absence of the debug `get-task-allow` entitlement. It does not install or launch.
Profile coverage and MusicKit App Service checks above remain necessary.

The default is hardened runtime **without App Sandbox**. To deliberately choose
the sandbox variant, add `SANDBOX=1`. App signing options use `SONOGLASS_*` build
settings referenced only by the SonoGlass target in `project.yml`. Do not pass
app-specific `CODE_SIGN_ENTITLEMENTS` or `PROVISIONING_PROFILE_SPECIFIER` globally
to `xcodebuild`: they also reach dependency resource targets such as CryptoSwift.

Automatic signing can use existing assets with `TEAM='<your-team-id>'
scripts/make_app_signed.sh`. Online provisioning is a separate deliberate opt-in:

```sh
# Allows Xcode to create/update signing assets on the selected team.
TEAM='<your-team-id>' ALLOW_PROVISIONING_UPDATES=1 scripts/make_app_signed.sh
# Also allows destination device registration; use only after reviewing scope.
TEAM='<your-team-id>' ALLOW_PROVISIONING_UPDATES=1 ALLOW_DEVICE_REGISTRATION=1 \
  scripts/make_app_signed.sh
```

Both flags default to `0`; Manual mode rejects them. Xcode may create/update more
assets in Automatic mode than the bounded manual profile flow. Use manual mode
when the build must use a particular certificate/profile without portal writes.

## Install, verify and retain rollback

Quit SonoGlass using its own menu. Install the verified build into the existing
location (choose explicitly if there are multiple copies):

```sh
DIST_DIR=/private/tmp/sonoglass-signed-dist scripts/install_app.sh /Applications
codesign --verify --deep --strict /Applications/SonoGlass.app
open /Applications/SonoGlass.app
```

The installer rejects unrelated files and running apps, stages a verified bundle,
checks ZIP integrity of the previous-app backup, and restores the old app if
replacement fails. Retain the printed backup path. An older development backup
may still require its original device/profile/certificate to launch.

For a deliberate rollback, quit SonoGlass, extract the retained ZIP into a
separate build-output directory using `ditto -x -k`, verify the extracted bundle
with `codesign --verify --deep --strict`, and feed that directory to
`scripts/install_app.sh`. Do not extract over the running installed app or erase
settings/Keychain entries. Preserve a backup of the version being replaced.

Open the **speaker icon in the menu bar**; there is no Dock icon. Verify the
installed location/version and actual panel responsiveness. The Mac's owner
should review any Local Network, Media & Apple Music, or Keychain prompt; existing
access on the old Mac does not prove access on this one. Inspect discovered rooms
and now-playing state without changing playback, grouping, volume or saved content.

Record checks separately: build/tests, signature/profile coverage, actual installed
launch, discovery, feature-specific account checks, and the user's confirmation.
A successful build, process launch, or general “working” confirmation is not proof
of a Favorites write. Check the Apple Music star's availability/state on an Apple
Music track if available; do not toggle it solely to prove startup. A real intended
Favorites write or other speaker control needs its own feature acceptance. An
ad-hoc or Apple Development signature is not a notarized distribution release.
