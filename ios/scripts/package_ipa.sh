#!/usr/bin/env bash
# Packages the archived app into an unsigned IPA for external signing
# (KravaSigner, Sideloadly, AltStore, Xcode) and verifies its structure.
#
#   ios/scripts/package_ipa.sh <path/to/App.xcarchive> <output-dir> <build-number> <expected-bundle-id>
#
# Produces in <output-dir>:
#   WezCryptSecureStudio-<version>-<build>-unsigned.ipa
#   BUILD-INFO.txt   (bundle metadata, architectures, file count, IPA size)
#   SHA256SUMS.txt
#
# The IPA is a plain zip of Payload/WezCryptSecureStudio.app built with `zip -X`
# after stripping extended attributes. `ditto --sequesterRsrc` is NOT used: on
# recent macOS it stores build-time xattrs as AppleDouble entries
# (__MACOSX/..., ._AppIcon60x60@2x.png) that look like empty files when the
# archive is opened on iOS and confuse some signing tools.
# Runs on macOS only (PlistBuddy, lipo, vtool, codesign).
set -euo pipefail

ARCHIVE="${1:?xcarchive path}"
OUT="${2:?output directory}"
BUILD="${3:?build number}"
EXPECTED_ID="${4:?expected bundle id}"
APP_NAME="WezCryptSecureStudio"
MIN_BINARY_BYTES=$((500 * 1024))
MIN_IPA_BYTES=$((200 * 1024))

fail() { echo "::error::IPA verification failed: $*" >&2; exit 1; }
log() { echo "[package] $*"; }

APP_SRC="$ARCHIVE/Products/Applications/$APP_NAME.app"
[[ -d "$APP_SRC" ]] || fail "archive has no $APP_NAME.app (looked in $APP_SRC)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Payload" "$OUT"
OUT="$(cd "$OUT" && pwd)"

log "copying app bundle"
ditto --norsrc --noextattr --noacl "$APP_SRC" "$WORK/Payload/$APP_NAME.app"
APP="$WORK/Payload/$APP_NAME.app"
# Remove any signature remnants so the external signer starts from a clean bundle.
rm -rf "$APP/_CodeSignature" "$APP/embedded.mobileprovision"
xattr -cr "$WORK/Payload"
find "$WORK/Payload" \( -name '.DS_Store' -o -name '._*' \) -delete

INFO="$APP/Info.plist"
BIN="$APP/$APP_NAME"
plist() { /usr/libexec/PlistBuddy -c "Print $1" "$INFO"; }

log "verifying bundle contents"
[[ -f "$INFO" ]] || fail "Info.plist missing"
plutil -lint "$INFO" >/dev/null || fail "Info.plist is not a valid plist"
[[ "$(plist CFBundleExecutable)" == "$APP_NAME" ]] || fail "CFBundleExecutable is not $APP_NAME"
[[ -f "$BIN" ]] || fail "executable $APP_NAME missing"
[[ "$(plist CFBundleIdentifier)" == "$EXPECTED_ID" ]] || fail "bundle id is $(plist CFBundleIdentifier), expected $EXPECTED_ID"
[[ "$(plist DTPlatformName)" == "iphoneos" ]] || fail "DTPlatformName is $(plist DTPlatformName) (simulator build?)"
[[ "$(plist MinimumOSVersion)" == "17.0" ]] || fail "MinimumOSVersion is $(plist MinimumOSVersion)"
[[ "$(lipo -archs "$BIN")" == "arm64" ]] || fail "architectures are '$(lipo -archs "$BIN")', expected arm64"
# LC_BUILD_VERSION platform 2 = iOS device (7 would be the simulator).
if ! otool -l "$BIN" | grep -A4 LC_BUILD_VERSION | grep -Eq '^ *platform (2|IOS)$'; then
  otool -l "$BIN" | grep -A4 LC_BUILD_VERSION || true
  fail "binary is not built for the iOS device platform"
fi
BIN_BYTES=$(stat -f %z "$BIN")
(( BIN_BYTES >= MIN_BINARY_BYTES )) || fail "executable is only $BIN_BYTES bytes"
[[ -s "$APP/Assets.car" ]] || fail "compiled asset catalog (Assets.car) missing or empty"
[[ -s "$APP/AppIcon60x60@2x.png" ]] || fail "AppIcon60x60@2x.png missing or empty"
EMPTY=$(find "$APP" -type f -size 0)
[[ -z "$EMPTY" ]] || fail "zero-byte files in bundle: $EMPTY"
if codesign -v "$APP" 2>/dev/null; then fail "bundle unexpectedly carries a valid signature"; fi

VERSION="$(plist CFBundleShortVersionString)"
IPA_NAME="$APP_NAME-$VERSION-$BUILD-unsigned.ipa"
IPA="$OUT/$IPA_NAME"
rm -f "$IPA"

log "creating $IPA_NAME"
(cd "$WORK" && /usr/bin/zip -qry -X "$IPA" Payload)

log "verifying archive"
unzip -tq "$IPA" >/dev/null || fail "zip integrity test failed"
ENTRIES="$(unzip -Z1 "$IPA")"
grep -Eq '(^__MACOSX/|/\._|\.DS_Store$)' <<<"$ENTRIES" && fail "archive contains macOS metadata entries"
grep -Evq '^Payload/' <<<"$ENTRIES" && fail "archive has entries outside Payload/"
for required in "Payload/$APP_NAME.app/$APP_NAME" "Payload/$APP_NAME.app/Info.plist" "Payload/$APP_NAME.app/Assets.car" "Payload/$APP_NAME.app/AppIcon60x60@2x.png"; do
  grep -Fxq "$required" <<<"$ENTRIES" || fail "archive is missing $required"
done
# Byte-compare the zipped executable with the bundle copy.
cmp -s <(unzip -p "$IPA" "Payload/$APP_NAME.app/$APP_NAME") "$BIN" || fail "zipped executable differs from the built one"
IPA_BYTES=$(stat -f %z "$IPA")
(( IPA_BYTES >= MIN_IPA_BYTES )) || fail "IPA is only $IPA_BYTES bytes"
FILE_COUNT=$(grep -cv '/$' <<<"$ENTRIES")
IPA_MIB=$(awk -v bytes="$IPA_BYTES" 'BEGIN { printf "%.2f", bytes / 1048576 }')

{
  echo "WezCrypt Secure Studio — build $BUILD (${GITHUB_SHA:-local})"
  echo "IPA:                         $IPA_NAME"
  echo "IPA size:                    $IPA_BYTES bytes ($IPA_MIB MiB)"
  echo "Files in Payload:            $FILE_COUNT"
  echo "Executable size:             $BIN_BYTES bytes"
  echo "CFBundleIdentifier:          $(plist CFBundleIdentifier)"
  echo "CFBundleShortVersionString:  $VERSION"
  echo "CFBundleVersion:             $(plist CFBundleVersion)"
  echo "MinimumOSVersion:            $(plist MinimumOSVersion)"
  echo "DTPlatformName:              $(plist DTPlatformName)"
  echo "Architectures:               $(lipo -archs "$BIN")"
  echo "Signed:                      NO — sign with KravaSigner (or another signer) before installing"
  echo "Xcode:                       $(xcodebuild -version | tr '\n' ' ')"
} > "$OUT/BUILD-INFO.txt"
(cd "$OUT" && shasum -a 256 "$IPA_NAME" BUILD-INFO.txt > SHA256SUMS.txt)

cat "$OUT/BUILD-INFO.txt"
echo "--- Payload ---"
unzip -l "$IPA" | sed -n '4,40p'
echo "--- SHA256SUMS.txt ---"
cat "$OUT/SHA256SUMS.txt"
echo "ipa_name=$IPA_NAME" >> "${GITHUB_OUTPUT:-/dev/null}"
