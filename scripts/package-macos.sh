#!/usr/bin/env bash
set -euo pipefail

APP_NAME="MoMoWhisper"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_TEMPLATE="$ROOT_DIR/packaging/macos/Info.plist.template"
ENTITLEMENTS="$ROOT_DIR/packaging/macos/MoMoWhisper.entitlements"
ICON_PATH="$ROOT_DIR/Resources/AppIcon.icns"

BUNDLE_ID="${MOMO_WHISPER_BUNDLE_ID:-com.jordannn02.MoMoWhisper}"
VERSION="${MOMO_WHISPER_VERSION:-0.1.0}"
BUILD_NUMBER="${MOMO_WHISPER_BUILD_NUMBER:-1}"
SIGN_IDENTITY="${MOMO_WHISPER_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${MOMO_WHISPER_NOTARY_PROFILE:-}"
BUILD_JOBS="${MOMO_WHISPER_JOBS:-4}"
OUTPUT_DIR="${MOMO_WHISPER_OUTPUT_DIR:-$ROOT_DIR/dist/macos}"
REQUESTED_ARCH="arm64"

usage() {
  printf '%s\n' "Usage: scripts/package-macos.sh [--universal] [--output-dir DIR]"
  printf '%s\n' ""
  printf '%s\n' "Environment:"
  printf '%s\n' "  MOMO_WHISPER_VERSION          CFBundleShortVersionString (default: 0.1.0)"
  printf '%s\n' "  MOMO_WHISPER_BUILD_NUMBER     CFBundleVersion (default: 1)"
  printf '%s\n' "  MOMO_WHISPER_SIGN_IDENTITY    Developer ID Application identity; empty means ad-hoc"
  printf '%s\n' "  MOMO_WHISPER_NOTARY_PROFILE   notarytool Keychain profile; requires Developer ID"
  printf '%s\n' "  MOMO_WHISPER_OUTPUT_DIR       Artifact directory (default: dist/macos)"
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[macOS package] %s\n' "$*"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --universal)
      REQUESTED_ARCH="universal"
      shift
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || fail "--output-dir requires a value"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -f "$ROOT_DIR/Package.swift" ]] || fail "Package.swift not found at $ROOT_DIR"
[[ -f "$INFO_TEMPLATE" ]] || fail "Info.plist template not found: $INFO_TEMPLATE"
[[ -f "$ENTITLEMENTS" ]] || fail "entitlements file not found: $ENTITLEMENTS"
[[ -f "$ICON_PATH" ]] || fail "AppIcon.icns not found: $ICON_PATH"
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9.-]+$ ]] || fail "invalid bundle identifier: $BUNDLE_ID"
[[ "$VERSION" =~ ^[0-9]+([.][0-9]+){1,2}$ ]] || fail "version must contain two or three numeric components"
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || fail "build number must be numeric"
[[ "$BUILD_JOBS" =~ ^[1-9][0-9]*$ ]] || fail "MOMO_WHISPER_JOBS must be a positive integer"

if [[ -n "$NOTARY_PROFILE" && -z "$SIGN_IDENTITY" ]]; then
  fail "MOMO_WHISPER_NOTARY_PROFILE requires MOMO_WHISPER_SIGN_IDENTITY"
fi

if [[ -n "$NOTARY_PROFILE" && "$REQUESTED_ARCH" != "universal" ]]; then
  fail "notarized public artifacts must be universal; rerun with --universal"
fi

for command_name in swift plutil codesign lipo ditto hdiutil shasum security xcrun; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required command not found: $command_name"
done

if [[ "$OUTPUT_DIR" != /* ]]; then
  OUTPUT_DIR="$ROOT_DIR/$OUTPUT_DIR"
fi
mkdir -p "$OUTPUT_DIR"

if [[ ! -d "${TMPDIR:-}" ]]; then
  export TMPDIR="/tmp"
fi
WORK_DIR="$(mktemp -d "$TMPDIR/momowhisper-macos.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

build_arch() {
  local arch="$1"
  local triple="$2"
  local scratch="$WORK_DIR/build-$arch"
  local binary

  log "building release product for $arch" >&2
  if ! swift build \
    --package-path "$ROOT_DIR" \
    --scratch-path "$scratch" \
    --configuration release \
    --product "$APP_NAME" \
    --triple "$triple" \
    -j "$BUILD_JOBS" >&2; then
    return 1
  fi

  binary="$(find "$scratch" -type f -path "*/release/$APP_NAME" -perm -111 -print -quit)"
  [[ -n "$binary" ]] || return 1
  printf '%s\n' "$binary"
}

ARM64_BINARY="$(build_arch arm64 arm64-apple-macosx14.0)" || fail "arm64 release build failed"
ARCH_LABEL="arm64"
X86_BUILD_STATUS="not-requested"
X86_64_BINARY=""

if [[ "$REQUESTED_ARCH" == "universal" ]]; then
  X86_64_BINARY="$(build_arch x86_64 x86_64-apple-macosx14.0)" || \
    fail "x86_64 release build failed; universal packaging is fail-closed"
  ARCH_LABEL="universal"
  X86_BUILD_STATUS="succeeded"
fi

APP_BUNDLE="$WORK_DIR/$APP_NAME.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

if [[ "$ARCH_LABEL" == "universal" ]]; then
  lipo -create "$ARM64_BINARY" "$X86_64_BINARY" -output "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
  chmod 755 "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
else
  install -m 755 "$ARM64_BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
fi

install -m 644 "$ICON_PATH" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
install -m 644 "$INFO_TEMPLATE" "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP_BUNDLE/Contents/Info.plist"
plutil -lint "$APP_BUNDLE/Contents/Info.plist" >/dev/null

if [[ -n "$SIGN_IDENTITY" ]]; then
  log "signing app with the supplied Developer ID identity"
  codesign \
    --force \
    --options runtime \
    --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" \
    "$APP_BUNDLE"
  SIGN_DETAILS="$(codesign -dvv "$APP_BUNDLE" 2>&1)"
  grep -q '^Authority=Developer ID Application:' <<<"$SIGN_DETAILS" || \
    fail "the supplied identity did not produce a Developer ID Application signature"
  SIGNING_DESCRIPTION="Developer ID Application (NOT NOTARIZED)"
else
  log "no Developer ID supplied; applying ad-hoc hardened-runtime signature"
  codesign \
    --force \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign - \
    "$APP_BUNDLE"
  SIGNING_LABEL="unsigned"
  SIGNING_DESCRIPTION="ad-hoc (NOT FOR PUBLIC DISTRIBUTION)"
fi

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

STAGED_ZIP_PATH="$WORK_DIR/$APP_NAME.zip"
STAGED_DMG_PATH="$WORK_DIR/$APP_NAME.dmg"
NOTARIZED="no"
PUBLIC_READY="no"

if [[ -n "$NOTARY_PROFILE" ]]; then
  NOTARY_ZIP="$WORK_DIR/notary-submission.zip"
  log "submitting signed app to Apple notary service using profile '$NOTARY_PROFILE'"
  ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$NOTARY_ZIP"
  xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_BUNDLE"
  xcrun stapler validate "$APP_BUNDLE"
fi

ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$STAGED_ZIP_PATH"

DMG_STAGE="$WORK_DIR/dmg-root"
mkdir -p "$DMG_STAGE"
ditto "$APP_BUNDLE" "$DMG_STAGE/$APP_NAME.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGE" \
  -ov \
  -format UDZO \
  "$STAGED_DMG_PATH" >/dev/null

if [[ -n "$SIGN_IDENTITY" ]]; then
  log "signing DMG with Developer ID"
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$STAGED_DMG_PATH"
fi

if [[ -n "$NOTARY_PROFILE" ]]; then
  log "submitting DMG to Apple notary service"
  xcrun notarytool submit "$STAGED_DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$STAGED_DMG_PATH"
  xcrun stapler validate "$STAGED_DMG_PATH"
  NOTARIZED="yes"
  PUBLIC_READY="yes"
  SIGNING_LABEL="developer-id-notarized"
  SIGNING_DESCRIPTION="Developer ID Application (notarized)"
elif [[ -n "$SIGN_IDENTITY" ]]; then
  SIGNING_LABEL="developer-id-unnotarized"
else
  SIGNING_LABEL="unsigned"
fi

BASE_NAME="$APP_NAME-$VERSION-macOS-$ARCH_LABEL-$SIGNING_LABEL"
ZIP_PATH="$OUTPUT_DIR/$BASE_NAME.zip"
DMG_PATH="$OUTPUT_DIR/$BASE_NAME.dmg"
CHECKSUM_PATH="$OUTPUT_DIR/$BASE_NAME.sha256"
METADATA_PATH="$OUTPUT_DIR/$BASE_NAME-release-metadata.txt"

rm -f "$ZIP_PATH" "$DMG_PATH" "$CHECKSUM_PATH" "$METADATA_PATH"
install -m 644 "$STAGED_ZIP_PATH" "$ZIP_PATH"
install -m 644 "$STAGED_DMG_PATH" "$DMG_PATH"

(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$(basename "$DMG_PATH")" "$(basename "$ZIP_PATH")"
) > "$CHECKSUM_PATH"

printf '%s\n' \
  "App: $APP_NAME" \
  "Version: $VERSION" \
  "Build: $BUILD_NUMBER" \
  "BundleIdentifier: $BUNDLE_ID" \
  "RequestedArchitecture: $REQUESTED_ARCH" \
  "ProducedArchitecture: $ARCH_LABEL" \
  "X86BuildStatus: $X86_BUILD_STATUS" \
  "Signing: $SIGNING_DESCRIPTION" \
  "Notarized: $NOTARIZED" \
  "PublicDistributionReady: $PUBLIC_READY" \
  > "$METADATA_PATH"

log "artifacts created"
printf '  %s\n' "$DMG_PATH" "$ZIP_PATH" "$CHECKSUM_PATH" "$METADATA_PATH"

if [[ "$PUBLIC_READY" != "yes" ]]; then
  printf '%s\n' "warning: artifacts are not ready for public distribution until Developer ID signing and notarization succeed" >&2
fi
