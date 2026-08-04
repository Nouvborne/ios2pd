#!/usr/bin/env bash
# Assembles the .app bundle (Info.plist + icons) and packages an unsigned IPA.
set -euo pipefail
source "$(dirname "$0")/common.sh"

APP_DIR="$BUILD_DIR/ios2pd.app"
DIST_DIR="$BUILD_DIR/dist"

# ---------------------------------------------------------------- Info.plist
cp "$ROOT/ios/Info.plist" "$APP_DIR/Info.plist"
I2PD_VERSION="$(grep -E '^#define I2PD_VERSION ' "$I2PD_DIR/libi2pd/version.h" | grep -oE '"[0-9.]+"' | tr -d '"' || true)"
if [ -n "$I2PD_VERSION" ]; then
  plutil -replace CFBundleShortVersionString -string "$I2PD_VERSION" "$APP_DIR/Info.plist"
  echo "==> i2pd version: $I2PD_VERSION"
fi

# ---------------------------------------------------------------- icons
python3 "$ROOT/ios/make_icon.py" "$APP_DIR"

# ---------------------------------------------------------------- validate
echo "==> Bundle contents:"
ls -la "$APP_DIR"
echo "==> Binary arch:"
file "$APP_DIR/ios2pd"
echo "==> Info.plist:"
plutil -p "$APP_DIR/Info.plist"

# Ship the (empty) entitlements alongside the bundle so Sideloadly/AltStore
# sign it with default entitlements on any free Apple ID. No appex and no
# restricted entitlements -> free-account signing trivially succeeds.
cp "$ROOT/ios/entitlements.plist" "$APP_DIR/entitlements.plist"

# ---------------------------------------------------------------- codesign
# Ad-hoc sign ("-") on the macOS runner and then VERIFY with --deep --strict.
# installd and strict sideloaders (ESign/Feather) reject a bundle whose
# signature is malformed or whose sealed hashes don't match, so a broken
# signature must fail the build rather than ship (set -e aborts below).
rm -rf "$APP_DIR/_CodeSignature"
if command -v codesign >/dev/null 2>&1; then
  echo "==> Ad-hoc codesigning bundle..."
  codesign --force --sign - "$APP_DIR"
  codesign -dv "$APP_DIR" 2>&1 || true
  echo "==> Verifying signature (strict, deep)..."
  codesign --verify --deep --strict --verbose=2 "$APP_DIR"
else
  echo "!! codesign not found; packaging WITHOUT a signature"
fi

# ---------------------------------------------------------------- IPA
rm -rf "$BUILD_DIR/Payload" "$DIST_DIR"
mkdir -p "$BUILD_DIR/Payload" "$DIST_DIR"
cp -R "$APP_DIR" "$BUILD_DIR/Payload/"
(
  cd "$BUILD_DIR"
  zip -qry "$DIST_DIR/ios2pd-unsigned.ipa" Payload
)

echo "==> Unsigned IPA:"
ls -lh "$DIST_DIR/ios2pd-unsigned.ipa"
