#!/usr/bin/env bash
# Builds the NEPacketTunnelProvider extension — which is where the i2pd daemon
# actually runs — and embeds it in the .app bundle under PlugIns/.
# Requires the app bundle to already exist (run build-app.sh first).
set -euo pipefail
source "$(dirname "$0")/common.sh"

APP_DIR="$BUILD_DIR/ios2pd.app"
EXT_DIR="$APP_DIR/PlugIns/ios2pdTunnel.appex"
OBJ_DIR="$BUILD_DIR/obj-ext"

rm -rf "$EXT_DIR" "$OBJ_DIR"
mkdir -p "$EXT_DIR" "$OBJ_DIR"

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

# HTTPServer/I2PControl/UPnP are disabled in the generated i2pd.conf but are
# still referenced by Daemon.cpp, so they have to be linked in.
SOURCES=(
  "$I2PD_DIR/daemon/Daemon.cpp"
  "$I2PD_DIR/daemon/UnixDaemon.cpp"
  "$I2PD_DIR/daemon/HTTPServer.cpp"
  "$I2PD_DIR/daemon/I2PControl.cpp"
  "$I2PD_DIR/daemon/I2PControlHandlers.cpp"
  "$I2PD_DIR/daemon/UPnP.cpp"
  "$ROOT/ios/ext/PacketTunnelProvider.mm"
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
  -framework NetworkExtension
  -framework Foundation
  -framework CoreFoundation
  -framework Security
)

# An app extension is an executable whose entry point is NSExtensionMain (from
# Foundation), not a Mach-O bundle.
echo "==> Linking ios2pdTunnel.appex"
"$CXX" \
  -target "$TARGET" \
  -isysroot "$SDK_ROOT" \
  -e _NSExtensionMain \
  "${OBJS[@]}" \
  "${LIBS[@]}" \
  "${FRAMEWORKS[@]}" \
  -lc++ \
  -o "$EXT_DIR/ios2pdTunnel"

cp "$ROOT/ios/ext/Info.plist" "$EXT_DIR/Info.plist"
I2PD_VERSION="$(grep -E '^#define I2PD_VERSION ' "$I2PD_DIR/libi2pd/version.h" | grep -oE '"[0-9.]+"' | tr -d '"' || true)"
if [ -n "$I2PD_VERSION" ]; then
  plutil -replace CFBundleShortVersionString -string "$I2PD_VERSION" "$EXT_DIR/Info.plist"
fi

# Reseed SU3 signing certificates. Without these the router cannot verify a
# reseed and never bootstraps.
cp -R "$I2PD_DIR/contrib/certificates" "$EXT_DIR/certificates"

echo "==> Extension bundle:"
file "$EXT_DIR/ios2pdTunnel"
ls -la "$EXT_DIR"
