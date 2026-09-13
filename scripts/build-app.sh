#!/usr/bin/env bash
# Compiles the SwiftUI app and assembles ios2pd.app. The app is pure Swift:
# i2pd itself lives in the tunnel extension (see build-extension.sh).
set -euo pipefail
source "$(dirname "$0")/common.sh"

SWIFTC="$(xcrun --find swiftc)"

APP_DIR="$BUILD_DIR/ios2pd.app"
OBJ_DIR="$BUILD_DIR/obj"
rm -rf "$APP_DIR" "$OBJ_DIR"
mkdir -p "$APP_DIR" "$OBJ_DIR"

echo "==> Compiling SwiftUI module"
"$SWIFTC" \
  -parse-as-library \
  -whole-module-optimization \
  -target "$TARGET" \
  -sdk "$SDK_ROOT" \
  -O \
  -swift-version 5 \
  -emit-object \
  -o "$OBJ_DIR/ios2pd-swift.o" \
  "$ROOT"/ios/Swift/*.swift

echo "==> Linking ios2pd"
"$SWIFTC" \
  -target "$TARGET" \
  -sdk "$SDK_ROOT" \
  "$OBJ_DIR/ios2pd-swift.o" \
  -framework UIKit \
  -framework SwiftUI \
  -framework Foundation \
  -framework NetworkExtension \
  -o "$APP_DIR/ios2pd"

echo "==> App binary:"
file "$APP_DIR/ios2pd"
