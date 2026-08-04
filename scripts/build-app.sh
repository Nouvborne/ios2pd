#!/usr/bin/env bash
# Compiles the iOS app (daemon core + I2pdCore.mm + SwiftUI shell) and
# assembles ios2pd.app.
set -euo pipefail
source "$(dirname "$0")/common.sh"

SWIFTC="$(xcrun --find swiftc)"

APP_DIR="$BUILD_DIR/ios2pd.app"
OBJ_DIR="$BUILD_DIR/obj"
rm -rf "$APP_DIR" "$OBJ_DIR"
mkdir -p "$APP_DIR" "$OBJ_DIR"

INCLUDES=(
  -I"$I2PD_DIR/libi2pd"
  -I"$I2PD_DIR/libi2pd_client"
  -I"$I2PD_DIR/i18n"
  -I"$I2PD_DIR/daemon"
  -I"$DEPS_PREFIX/include"
)

COMMON_FLAGS=(
  -target "$TARGET"
  -isysroot "$SDK_ROOT"
  -std=c++20
  -O2
  -fobjc-arc
  -DMAC_OSX
  -Wno-deprecated-declarations
  -Wno-unused-parameter
  -Wno-unused-variable
)

# ------------------------------------------------------------------ C++/ObjC
SOURCES=(
  "$I2PD_DIR/daemon/Daemon.cpp"
  "$I2PD_DIR/daemon/UnixDaemon.cpp"
  "$I2PD_DIR/daemon/HTTPServer.cpp"
  "$I2PD_DIR/daemon/I2PControl.cpp"
  "$I2PD_DIR/daemon/I2PControlHandlers.cpp"
  "$I2PD_DIR/daemon/UPnP.cpp"
  "$ROOT/ios/I2pdCore.mm"
)

OBJS=()
PIDS=()
for src in "${SOURCES[@]}"; do
  obj="$OBJ_DIR/$(basename "$src" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_').o"
  "$CXX" "${COMMON_FLAGS[@]}" "${INCLUDES[@]}" -c "$src" -o "$obj" &
  PIDS+=("$!")
  OBJS+=("$obj")
done
for pid in "${PIDS[@]}"; do wait "$pid"; done

# ------------------------------------------------------------------- Swift
echo "==> Compiling SwiftUI module"
SWIFT_SRC=("$ROOT"/ios/Swift/*.swift)
"$SWIFTC" \
  -parse-as-library \
  -whole-module-optimization \
  -target "$TARGET" \
  -sdk "$SDK_ROOT" \
  -O \
  -swift-version 5 \
  -import-objc-header "$ROOT/ios/ios2pd-Bridging-Header.h" \
  -emit-object \
  -o "$OBJ_DIR/ios2pd-swift.o" \
  "${SWIFT_SRC[@]}"

LIBS=(
  "$BUILD_DIR/i2pd-ios/libi2pdlang.a"
  "$BUILD_DIR/i2pd-ios/libi2pdclient.a"
  "$BUILD_DIR/i2pd-ios/libi2pd.a"
  "$DEPS_PREFIX/lib/libboost_filesystem.a"
  "$DEPS_PREFIX/lib/libboost_program_options.a"
  "$DEPS_PREFIX/lib/libboost_atomic.a"
  "$DEPS_PREFIX/lib/libboost_system.a"
  "$DEPS_PREFIX/lib/libssl.a"
  "$DEPS_PREFIX/lib/libcrypto.a"
  "$DEPS_PREFIX/lib/libz.a"
)

FRAMEWORKS=(
  -framework UIKit
  -framework SwiftUI
  -framework CoreGraphics
  -framework Foundation
  -framework CoreFoundation
  -framework Security
  -framework NetworkExtension
  -framework AVFoundation
  -framework SystemConfiguration
  -framework QuartzCore
  -framework WebKit
)

echo "==> Linking ios2pd"
"$SWIFTC" \
  -target "$TARGET" \
  -sdk "$SDK_ROOT" \
  "${OBJS[@]}" \
  "$OBJ_DIR/ios2pd-swift.o" \
  "${LIBS[@]}" \
  "${FRAMEWORKS[@]}" \
  -lc++ \
  -o "$APP_DIR/ios2pd"

echo "==> App binary:"
file "$APP_DIR/ios2pd"
