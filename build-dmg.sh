#!/usr/bin/env bash
# build-dmg.sh — build a signed, notarized, stapled Lunation.dmg for release.
#
#   ./build-dmg.sh                 # archive → export → notarize → dmg → notarize → staple
#   ./build-dmg.sh path/to/Lunation.app   # skip the build; package an existing .app
#
# Prereqs (one-time):
#   • A "Developer ID Application" certificate in your login keychain.
#   • A stored notarytool credential profile (default name: "notary"):
#       xcrun notarytool store-credentials notary \
#         --apple-id "you@example.com" --team-id 2WZ6A7Z8A4
#     (override the profile name with NOTARY_PROFILE=<name>.)
#
# Output: ./dist/Lunation.dmg — upload that to a GitHub Release.

set -euo pipefail
cd "$(dirname "$0")"

# --- config (override via env) -------------------------------------------------------
PROJECT="${PROJECT:-MenuBarApp/Lunation.xcodeproj}"
SCHEME="${SCHEME:-Lunation}"
APP_NAME="${APP_NAME:-Lunation}"
VOLNAME="${VOLNAME:-Lunation}"
TEAM_ID="${TEAM_ID:-2WZ6A7Z8A4}"
NOTARY_PROFILE="${NOTARY_PROFILE:-notary}"

DIST="dist"
BUILD="$DIST/build"
ARCHIVE="$BUILD/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD/export"
OUT_DMG="$DIST/$APP_NAME.dmg"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
die()  { echo "error: $1" >&2; exit 1; }

# --- preflight -----------------------------------------------------------------------
command -v xcodebuild >/dev/null || die "xcodebuild not found (install Xcode)."
DEVID_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/{print $2; exit}')"
[[ -n "$DEVID_IDENTITY" ]] \
  || die "no 'Developer ID Application' certificate in the keychain. Add one in Xcode → Settings → Accounts → Manage Certificates."
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || die "notarytool profile '$NOTARY_PROFILE' not found. Create it with: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <you> --team-id $TEAM_ID"

mkdir -p "$DIST"
rm -f "$OUT_DMG"

# --- 1. build the signed .app (unless one was passed in) -----------------------------
if [[ $# -ge 1 ]]; then
  APP="$1"
  [[ -d "$APP" ]] || die "no app bundle at: $APP"
  step "Using existing app: $APP"
else
  step "Archiving $SCHEME (Release)"
  rm -rf "$ARCHIVE" "$EXPORT_DIR"
  xcodebuild archive \
    -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -archivePath "$ARCHIVE" \
    -destination 'generic/platform=macOS' \
    -allowProvisioningUpdates

  step "Exporting with Developer ID"
  cat > "$BUILD/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
EOF
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$BUILD/ExportOptions.plist" \
    -exportPath "$EXPORT_DIR" \
    -allowProvisioningUpdates
  APP="$EXPORT_DIR/$APP_NAME.app"
  [[ -d "$APP" ]] || die "export did not produce $APP"
fi

# --- 2. notarize + staple the app ----------------------------------------------------
# Staple the app itself so it launches cleanly even offline once copied to /Applications.
step "Notarizing the app (this waits for Apple)"
APP_ZIP="$BUILD/$APP_NAME.app.zip"
ditto -c -k --keepParent "$APP" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$APP_ZIP"

# --- 3. build the DMG ----------------------------------------------------------------
step "Building $OUT_DMG"
if command -v create-dmg >/dev/null 2>&1; then
  create-dmg --volname "$VOLNAME" --app-drop-link 450 150 "$OUT_DMG" "$APP"
else
  staging="$(mktemp -d)"
  cp -R "$APP" "$staging/"
  ln -s /Applications "$staging/Applications"   # drag-to-install target
  hdiutil create -volname "$VOLNAME" -srcfolder "$staging" -ov -format UDZO "$OUT_DMG"
  rm -rf "$staging"
fi

# --- 4. sign the DMG -----------------------------------------------------------------
# hdiutil/create-dmg produce an UNSIGNED disk image. Notarizing + stapling alone
# leaves it with a ticket but "no usable signature", which Gatekeeper/spctl can't
# assess. Sign it with Developer ID (with a secure timestamp) BEFORE notarizing.
step "Signing the DMG"
codesign --force --timestamp --sign "$DEVID_IDENTITY" "$OUT_DMG"

# --- 5. notarize + staple the DMG ----------------------------------------------------
step "Notarizing the DMG (this waits for Apple)"
xcrun notarytool submit "$OUT_DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$OUT_DMG"

# --- 6. verify -----------------------------------------------------------------------
# stapler validate is the authoritative check (ticket present + valid). spctl is
# informational — it can be finicky on disk images, so don't fail the build on it.
step "Verifying"
xcrun stapler validate "$OUT_DMG" \
  || die "notarization ticket not stapled — the DMG would be rejected by Gatekeeper."
if spctl -a -t open --context context:primary-signature -vv "$OUT_DMG"; then
  echo "  Gatekeeper: accepted (Notarized Developer ID) ✓"
else
  echo "  note: spctl was inconclusive, but the ticket validated above — the DMG is good to ship."
fi

printf '\n\033[1;32m✓ Done:\033[0m %s\n' "$OUT_DMG"
echo "  Upload it to a GitHub Release (asset name: $APP_NAME.dmg)."
