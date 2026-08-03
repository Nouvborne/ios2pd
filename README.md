# ios2pd

[i2pd](https://github.com/PurpleI2P/i2pd) — the I2P anonymous-network daemon
written in C++ — ported to iOS, built as an **unsigned `.ipa`** by a GitHub
Actions workflow (macOS runners, no Mac or Apple Developer account needed).

## What this is

* A real cross-compile of **i2pd 2.61.0** for `arm64` iOS (device):
  * `libi2pd.a`, `libi2pdclient.a`, `libi2pdlang.a`
  * plus OpenSSL, zlib and Boost statically linked for iOS.
* A minimal UIKit app (`ios/main.mm`) that embeds the i2pd daemon core
  (`DaemonUnix`) and runs the router on a background thread, with a Start/Stop
  button and a live log view. HTTP proxy (:4444), SOCKS proxy (:4447) and the
  SAM bridge (:7656) are enabled.
* A CI pipeline that produces an **unsigned IPA** — a `Payload/ios2pd.app`
  bundle with no code signature — downloadable as a workflow artifact.

## Build

Everything runs in CI on `macos-15` runners. To run it locally you need a Mac
with Xcode + command line tools:

```sh
./scripts/build-deps.sh   # OpenSSL 3.0.16, zlib 1.3.1, Boost 1.85.0 (arm64 iOS)
./scripts/build-i2pd.sh   # cmake + leetal/ios-cmake -> i2pd static libs
./scripts/build-app.sh    # compile daemon core + UIKit shell -> ios2pd.app
./scripts/make-ipa.sh     # assemble bundle + package ios2pd-unsigned.ipa
```

Artifacts land in `build/`. The workflow caches `build/deps-ios` between runs.

## Getting the IPA

1. Open the repo on GitHub → **Actions** → **Build unsigned iOS IPA**.
2. Run the workflow (or wait for the push trigger).
3. Download the `ios2pd-unsigned-ipa` artifact.

Because the app is unsigned, iOS will refuse to install it as-is. To put it on
a device, re-sign it with a free Apple ID:

* **Sideloadly** or **AltStore** (macOS/Windows/Linux) — point it at the IPA
  and your Apple ID.
* or `codesign --force --deep --sign -` after embedding your provisioning
  profile (see Apple's docs on free personal-team signing).

## Caveats

* **Background execution:** iOS suspends apps that are not foregrounded, so
  the router keeps running while the app is open but stops once the OS suspends
  it. A proper `PacketTunnelProvider` (Network Extension) would be needed for
  long-running background operation — out of scope for this port.
* **Runtime on device is experimental.** The build is verified to compile and
  package; networking behaviour (interface enumeration, tunnels, reseeding) on
  a real device depends on entitlements and iOS network policies.
* `getifaddrs`/interface access on iOS is restricted; the router may see only
  loopback until network entitlements are granted when signing.

## Layout

```
.github/workflows/build-ipa.yml  CI pipeline (deps → libs → app → IPA)
scripts/                         build scripts (macOS/Xcode)
ios/main.mm                      UIKit shell + daemon bridge
ios/Info.plist                   app bundle metadata
i2pd/                            i2pd source (submodule, pinned to 2.61.0)
```

## Credits

* [PurpleI2P/i2pd](https://github.com/PurpleI2P/i2pd) — the daemon (BSD-3).
* [leetal/ios-cmake](https://github.com/leetal/ios-cmake) — iOS CMake toolchain.
* Official i2pd iOS build docs: https://i2pd.readthedocs.io/en/latest/devs/building/ios/
