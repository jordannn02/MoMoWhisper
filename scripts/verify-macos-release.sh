#!/usr/bin/env bash
set -euo pipefail

APP_NAME="MoMoWhisper"
EXPECTED_BUNDLE_ID="${MOMO_WHISPER_BUNDLE_ID:-com.jordannn02.MoMoWhisper}"
EXPECTED_ARCH="arm64"
ALLOW_ADHOC=0
ARTIFACT=""

usage() {
  printf '%s\n' "Usage: scripts/verify-macos-release.sh [--allow-adhoc] [--expected-arch arm64|universal] ARTIFACT"
  printf '%s\n' "ARTIFACT may be a MoMoWhisper.app, .dmg, or .zip."
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[macOS verify] %s\n' "$*"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-adhoc)
      ALLOW_ADHOC=1
      shift
      ;;
    --expected-arch)
      [[ $# -ge 2 ]] || fail "--expected-arch requires a value"
      EXPECTED_ARCH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -* )
      fail "unknown argument: $1"
      ;;
    *)
      [[ -z "$ARTIFACT" ]] || fail "only one artifact may be verified at a time"
      ARTIFACT="$1"
      shift
      ;;
  esac
done

[[ -n "$ARTIFACT" ]] || fail "artifact path is required"
[[ -e "$ARTIFACT" ]] || fail "artifact not found: $ARTIFACT"
[[ "$EXPECTED_ARCH" == "arm64" || "$EXPECTED_ARCH" == "universal" ]] || \
  fail "expected architecture must be arm64 or universal"

for command_name in codesign plutil lipo vtool spctl shasum ditto hdiutil xcrun; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required command not found: $command_name"
done

if [[ ! -d "${TMPDIR:-}" ]]; then
  export TMPDIR="/tmp"
fi
WORK_DIR="$(mktemp -d "$TMPDIR/momowhisper-verify.XXXXXX")"
MOUNT_POINT="$WORK_DIR/mount"
MOUNTED=0

cleanup() {
  if [[ "$MOUNTED" == "1" ]]; then
    hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

verify_checksum_if_present() {
  local archive="$1"
  local checksum_file="${archive%.*}.sha256"
  local archive_name
  local expected
  local actual

  [[ -f "$checksum_file" ]] || return 0
  archive_name="$(basename "$archive")"
  expected="$(awk -v name="$archive_name" '$2 == name { print $1; exit }' "$checksum_file")"
  [[ -n "$expected" ]] || fail "checksum file has no entry for $archive_name"
  actual="$(shasum -a 256 "$archive" | awk '{ print $1 }')"
  [[ "$actual" == "$expected" ]] || fail "SHA-256 mismatch for $archive_name"
  log "SHA-256 matches $checksum_file"
}

case "$ARTIFACT" in
  *.app)
    APP_BUNDLE="$ARTIFACT"
    ARTIFACT_KIND="app"
    ;;
  *.dmg)
    ARTIFACT_KIND="dmg"
    verify_checksum_if_present "$ARTIFACT"
    hdiutil verify "$ARTIFACT" >/dev/null
    mkdir -p "$MOUNT_POINT"
    hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_POINT" "$ARTIFACT" >/dev/null
    MOUNTED=1
    APP_BUNDLE="$MOUNT_POINT/$APP_NAME.app"
    ;;
  *.zip)
    ARTIFACT_KIND="zip"
    verify_checksum_if_present "$ARTIFACT"
    mkdir -p "$WORK_DIR/unzip"
    ditto -x -k "$ARTIFACT" "$WORK_DIR/unzip"
    APP_BUNDLE="$WORK_DIR/unzip/$APP_NAME.app"
    ;;
  *)
    fail "unsupported artifact type: $ARTIFACT"
    ;;
esac

[[ -d "$APP_BUNDLE" ]] || fail "$APP_NAME.app not found inside artifact"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
ICON="$APP_BUNDLE/Contents/Resources/AppIcon.icns"

[[ -f "$INFO_PLIST" ]] || fail "Info.plist is missing"
[[ -x "$BINARY" ]] || fail "main executable is missing or not executable"
[[ -f "$ICON" ]] || fail "AppIcon.icns is missing"
plutil -lint "$INFO_PLIST" >/dev/null

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
MINIMUM_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO_PLIST")"

[[ "$BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] || \
  fail "bundle identifier is $BUNDLE_ID, expected $EXPECTED_BUNDLE_ID"
[[ -n "$VERSION" && -n "$BUILD_NUMBER" ]] || fail "version metadata is incomplete"
[[ "$MINIMUM_OS" == "14.0" ]] || fail "LSMinimumSystemVersion is $MINIMUM_OS, expected 14.0"

for usage_key in NSMicrophoneUsageDescription NSSpeechRecognitionUsageDescription NSAudioCaptureUsageDescription; do
  /usr/libexec/PlistBuddy -c "Print :$usage_key" "$INFO_PLIST" >/dev/null || \
    fail "$usage_key is missing from Info.plist"
done

ARCHS="$(lipo -archs "$BINARY")"
grep -qw arm64 <<<"$ARCHS" || fail "binary does not contain arm64: $ARCHS"
if [[ "$EXPECTED_ARCH" == "universal" ]]; then
  grep -qw x86_64 <<<"$ARCHS" || fail "universal binary does not contain x86_64: $ARCHS"
fi
vtool -show-build "$BINARY" | grep -Eq 'minos[[:space:]]+14[.]0' || \
  fail "Mach-O minimum OS is not 14.0"

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
SIGN_DETAILS="$(codesign -dvvv "$APP_BUNDLE" 2>&1)"
grep -Eq 'flags=.*runtime' <<<"$SIGN_DETAILS" || fail "hardened runtime flag is missing"

ENTITLEMENTS_PLIST="$WORK_DIR/extracted-entitlements.plist"
codesign -d --entitlements :- "$APP_BUNDLE" > "$ENTITLEMENTS_PLIST" 2>/dev/null || \
  fail "unable to read signed entitlements"
plutil -lint "$ENTITLEMENTS_PLIST" >/dev/null || fail "signed entitlements are not a valid plist"

AUDIO_INPUT="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$ENTITLEMENTS_PLIST" 2>/dev/null || true)"
[[ "$AUDIO_INPUT" == "true" ]] || fail "audio-input entitlement is missing"
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$ENTITLEMENTS_PLIST" >/dev/null 2>&1; then
  fail "App Sandbox entitlement was added unexpectedly"
fi

if grep -q '^Signature=adhoc' <<<"$SIGN_DETAILS"; then
  [[ "$ALLOW_ADHOC" == "1" ]] || \
    fail "artifact is ad-hoc signed; use --allow-adhoc only for local/CI structural verification"
  if spctl -a -t exec -vvv "$APP_BUNDLE" >/dev/null 2>&1; then
    log "warning: Gatekeeper unexpectedly accepted an ad-hoc artifact"
  else
    log "Gatekeeper rejection is expected for this explicitly allowed ad-hoc artifact"
  fi
  DISTRIBUTION_STATUS="ad-hoc structural verification only"
else
  grep -q '^Authority=Developer ID Application:' <<<"$SIGN_DETAILS" || \
    fail "signature is neither ad-hoc nor Developer ID Application"
  spctl -a -t exec -vvv "$APP_BUNDLE"
  if [[ "$ARTIFACT_KIND" == "dmg" ]]; then
    xcrun stapler validate "$ARTIFACT"
  else
    xcrun stapler validate "$APP_BUNDLE"
  fi
  DISTRIBUTION_STATUS="Developer ID and notarization checks passed"
fi

log "verification passed"
printf '%s\n' \
  "  Artifact: $ARTIFACT" \
  "  Bundle ID: $BUNDLE_ID" \
  "  Version: $VERSION ($BUILD_NUMBER)" \
  "  Architectures: $ARCHS" \
  "  Minimum macOS: $MINIMUM_OS" \
  "  Distribution: $DISTRIBUTION_STATUS"
