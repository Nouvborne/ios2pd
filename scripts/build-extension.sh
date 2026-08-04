#!/usr/bin/env bash
# Builds the NEAppProxyProvider app extension and embeds it in the .app
# bundle under PlugIns/. Requires the app bundle to already exist
# (run build-app.sh first).
set -euo pipefail
source "$(dirname "$0")/common.sh"

APP_DIR="$BUILD_DIR/ios2pd.app"
EXT_DIR="$APP_DIR/PlugIns/ios2pdProxy.appex"
OBJ_DIR="$BUILD_DIR/obj-ext"
CC="$(xcrun --find clang)"

rm -rf "$EXT_DIR" "$OBJ_DIR"
mkdir -p "$EXT_DIR" "$OBJ_DIR"

EXT_CFLAGS=(
  -target "$TARGET"
  -isysroot "$SDK_ROOT"
  -fobjc-arc
  -O2
  -Wno-deprecated-declarations
  -Wno-unused-variable
  -fobjc-abi-version=2
)

echo "==> Compiling AppProxyProvider"
"$CC" "${EXT_CFLAGS[@]}" -c "$ROOT/ios/ext/AppProxyProvider.m" -o "$OBJ_DIR/AppProxyProvider.o"

echo "==> Linking ios2pdProxy.appex"
"$CC" "${EXT_CFLAGS[@]}" -bundle \
  -framework NetworkExtension \
  -framework Foundation \
  -framework Security \
  -o "$EXT_DIR/AppProxyProvider" "$OBJ_DIR/AppProxyProvider.o"

cp "$ROOT/ios/ext/Info.plist" "$EXT_DIR/Info.plist"
I2PD_VERSION="$(grep -E '^#define I2PD_VERSION ' "$I2PD_DIR/libi2pd/version.h" | grep -oE '"[0-9.]+"' | tr -d '"' || true)"
if [ -n "$I2PD_VERSION" ]; then
  plutil -replace CFBundleShortVersionString -string "$I2PD_VERSION" "$EXT_DIR/Info.plist"
fi

echo "==> Extension bundle:"
file "$EXT_DIR/AppProxyProvider"
ls -la "$EXT_DIR"
