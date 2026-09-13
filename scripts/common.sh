#!/usr/bin/env bash
# Shared environment for the iOS build scripts. macOS (Xcode) only.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BUILD_DIR="$ROOT/build"
DEPS_PREFIX="$BUILD_DIR/deps-ios"          # installed include/ + lib/ for openssl, boost, zlib
DEPS_SRC="$BUILD_DIR/deps-src"             # downloaded/extracted dependency sources
I2PD_DIR="$ROOT/i2pd"
IOS_CMAKE_DIR="$BUILD_DIR/ios-cmake"
IOS_CMAKE_TAG="4.5.0"

ARCH="arm64"
MIN_IOS="16.0"
TARGET="arm64-apple-ios${MIN_IOS}"

SDK_ROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
SDK_PLATFORM="$(xcrun --sdk iphoneos --show-sdk-platform-path)"
SDK_NAME="$(basename "$SDK_ROOT")"
CXX="$(xcrun --find clang++)"
AR="$(xcrun --find ar)"

JOBS="$(sysctl -n hw.ncpu)"

export ROOT BUILD_DIR DEPS_PREFIX DEPS_SRC I2PD_DIR IOS_CMAKE_DIR IOS_CMAKE_TAG
export ARCH MIN_IOS TARGET SDK_ROOT SDK_PLATFORM SDK_NAME CXX AR JOBS
export CROSS_TOP="$SDK_PLATFORM/Developer"
export CROSS_SDK="$SDK_NAME"

# fetch URL DEST  -> download URL to DEST unless it already exists
fetch() {
  if [ ! -f "$2" ]; then
    curl -fL --retry 3 --retry-delay 2 -o "$2" "$1"
  fi
}

# ensure an (empty) static library exists at PATH so that find_package/linking
# is satisfied for header-only boost libraries (system, atomic).
ensure_lib() {
  local path="$1"
  if [ ! -f "$path" ]; then
    mkdir -p "$(dirname "$path")"
    printf '!<arch>\n' > "$path"
  fi
}
