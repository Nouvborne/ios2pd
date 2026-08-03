#!/usr/bin/env bash
# Builds i2pd as static libraries (libi2pd.a, libi2pdclient.a, libi2pdlang.a)
# for arm64 iOS using the leetal/ios-cmake toolchain.
set -euo pipefail
source "$(dirname "$0")/common.sh"

if [ ! -d "$IOS_CMAKE_DIR" ]; then
  echo "==> Cloning ios-cmake ($IOS_CMAKE_TAG)"
  git clone --depth 1 --branch "$IOS_CMAKE_TAG" https://github.com/leetal/ios-cmake.git "$IOS_CMAKE_DIR"
fi

rm -rf "$BUILD_DIR/i2pd-ios"
echo "==> Configuring i2pd for iOS"
cmake -S "$I2PD_DIR/build" -B "$BUILD_DIR/i2pd-ios" \
  -DCMAKE_TOOLCHAIN_FILE="$IOS_CMAKE_DIR/ios.toolchain.cmake" \
  -DPLATFORM=OS64 \
  -DARCHS="$ARCH" \
  -DDEPLOYMENT_TARGET="$MIN_IOS" \
  -DCMAKE_BUILD_TYPE=Release \
  -DWITH_BINARY=no \
  -DWITH_LIBRARY=yes \
  -DWITH_STATIC=yes \
  -DWITH_UPNP=no \
  -DWITH_GIT_VERSION=no \
  -DBUILD_TESTING=no \
  -DBoost_INCLUDE_DIR="$DEPS_PREFIX/include" \
  -DBoost_LIBRARY_DIR="$DEPS_PREFIX/lib" \
  -DOPENSSL_INCLUDE_DIR="$DEPS_PREFIX/include" \
  -DOPENSSL_SSL_LIBRARY="$DEPS_PREFIX/lib/libssl.a" \
  -DOPENSSL_CRYPTO_LIBRARY="$DEPS_PREFIX/lib/libcrypto.a" \
  -DZLIB_INCLUDE_DIR="$DEPS_PREFIX/include" \
  -DZLIB_LIBRARY="$DEPS_PREFIX/lib/libz.a"

echo "==> Building i2pd libraries"
cmake --build "$BUILD_DIR/i2pd-ios" -j"$JOBS"

echo "==> i2pd libraries:"
ls -lh "$BUILD_DIR"/i2pd-ios/*.a
