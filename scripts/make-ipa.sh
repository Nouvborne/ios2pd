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
echo "==> Extension:"
ls -la "$APP_DIR/PlugIns/ios2pdProxy.appex" 2>/dev/null || echo "!! no extension found"
echo "==> Binary arch:"
file "$APP_DIR/ios2pd"
echo "==> Info.plist:"
plutil -p "$APP_DIR/Info.plist"

# Ship the entitlements alongside the bundle so Sideloadly/AltStore users can
# apply them (com.apple.developer.networking.networkextension) when signing.
cp "$ROOT/ios/entitlements.plist" "$APP_DIR/entitlements.plist"

# ---------------------------------------------------------------- codesign
# Sideloaders (AltStore/Sideloadly/TrollStore) refuse a bundle with NO code
# signature at all. Ad-hoc sign ("-") on the macOS runner so installd and the
# various re-signing tools accept it; they swap in their own cert later.
rm -rf "$APP_DIR/_CodeSignature"
if command -v codesign >/dev/null 2>&1; then
  echo "==> Ad-hoc codesigning extension..."
  if [ -d "$APP_DIR/PlugIns/ios2pdProxy.appex" ]; then
    rm -rf "$APP_DIR/PlugIns/ios2pdProxy.appex/_CodeSignature"
    codesign --force --sign - "$APP_DIR/PlugIns/ios2pdProxy.appex"
    codesign -dv "$APP_DIR/PlugIns/ios2pdProxy.appex" 2>&1 || true
  else
    echo "!! no extension found; skipping appex signing"
  fi
  echo "==> Ad-hoc codesigning bundle..."
  codesign --force --sign - "$APP_DIR"
  codesign -dv "$APP_DIR" 2>&1 || true
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
