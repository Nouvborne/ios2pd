#!/usr/bin/env bash
# Builds OpenSSL, zlib and Boost for arm64 iOS (device) into $DEPS_PREFIX.
set -euo pipefail
source "$(dirname "$0")/common.sh"

OPENSSL_VER="3.0.16"
ZLIB_VER="1.3.1"
BOOST_VER="1.85.0"
BOOST_DIRNAME="boost_1_85_0"

mkdir -p "$DEPS_SRC" "$DEPS_PREFIX"

# ---------------------------------------------------------------- OpenSSL
if [ ! -f "$DEPS_PREFIX/lib/libcrypto.a" ]; then
  echo "==> Building OpenSSL $OPENSSL_VER for iOS"
  fetch "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VER}/openssl-${OPENSSL_VER}.tar.gz" \
       "$DEPS_SRC/openssl-${OPENSSL_VER}.tar.gz"
  rm -rf "$DEPS_SRC/openssl-${OPENSSL_VER}"
  tar xzf "$DEPS_SRC/openssl-${OPENSSL_VER}.tar.gz" -C "$DEPS_SRC"
  pushd "$DEPS_SRC/openssl-${OPENSSL_VER}" >/dev/null
  ./Configure ios64-cross \
    no-shared no-dso no-tests no-apps \
    --prefix="$DEPS_PREFIX" --openssldir="$DEPS_PREFIX"
  make -j"$JOBS"
  make install_sw
  popd >/dev/null
fi

# ---------------------------------------------------------------- zlib
if [ ! -f "$DEPS_PREFIX/lib/libz.a" ]; then
  echo "==> Building zlib $ZLIB_VER for iOS"
  fetch "https://github.com/madler/zlib/releases/download/v${ZLIB_VER}/zlib-${ZLIB_VER}.tar.gz" \
       "$DEPS_SRC/zlib-${ZLIB_VER}.tar.gz"
  rm -rf "$DEPS_SRC/zlib-${ZLIB_VER}"
  tar xzf "$DEPS_SRC/zlib-${ZLIB_VER}.tar.gz" -C "$DEPS_SRC"
  pushd "$DEPS_SRC/zlib-${ZLIB_VER}" >/dev/null
  CC="xcrun -sdk iphoneos clang -arch ${ARCH} -isysroot ${SDK_ROOT} -mios-version-min=${MIN_IOS}" \
    CHOST="aarch64-apple-darwin" \
    ./configure --static --prefix="$DEPS_PREFIX"
  make -j"$JOBS"
  make install
  popd >/dev/null
fi

# ---------------------------------------------------------------- Boost
if [ ! -f "$DEPS_PREFIX/lib/libboost_filesystem.a" ]; then
  echo "==> Building Boost $BOOST_VER for iOS"
  fetch "https://archives.boost.io/release/${BOOST_VER}/source/boost_${BOOST_VER//./_}.tar.gz" \
       "$DEPS_SRC/boost_${BOOST_VER//./_}.tar.gz"
  rm -rf "$DEPS_SRC/$BOOST_DIRNAME"
  tar xzf "$DEPS_SRC/boost_${BOOST_VER//./_}.tar.gz" -C "$DEPS_SRC"
  pushd "$DEPS_SRC/$BOOST_DIRNAME" >/dev/null
  ./bootstrap.sh --prefix="$DEPS_PREFIX"

  cat > tools/build/src/user-config.jam <<EOF
using clang : ios : ${CXX} -arch ${ARCH} -isysroot ${SDK_ROOT} -mios-version-min=${MIN_IOS} -stdlib=libc++ -std=c++17 ;
EOF

  ./b2 -j"$JOBS" \
    --user-config=tools/build/src/user-config.jam \
    --prefix="$DEPS_PREFIX" \
    --layout=system \
    toolset=clang-ios \
    target-os=iphone \
    architecture=arm \
    address-model=64 \
    link=static runtime-link=static \
    threading=multi variant=release \
    cxxflags="-stdlib=libc++ -std=c++17" \
    linkflags="-stdlib=libc++" \
    --with-filesystem --with-program_options --with-atomic --with-system \
    install
  popd >/dev/null
fi

# boost.system / boost.atomic are header-only in modern boost; leave an empty
# archive in place so i2pd's find_package(Boost) and the linker are satisfied.
ensure_lib "$DEPS_PREFIX/lib/libboost_system.a"
ensure_lib "$DEPS_PREFIX/lib/libboost_atomic.a"

echo "==> Dependencies installed in $DEPS_PREFIX"
ls "$DEPS_PREFIX/lib"
