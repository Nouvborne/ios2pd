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
  button, a live log view and a VPN status line. HTTP proxy (:4444), SOCKS
  proxy (:4447) and the SAM bridge (:7656) are enabled.
* A bundled **NEAppProxyProvider** (`ios/ext/`) — a "VPN" that routes
  `*.i2p` traffic through the local i2pd SOCKS proxy. When the VPN is enabled
  in Settings and the router is running, Safari and other apps can open
  `.i2p` sites directly (e.g. `http://i2p.i2p`). Clearnet traffic is
  untouched.
* A CI pipeline that produces an **unsigned IPA** — a `Payload/ios2pd.app`
  bundle with an ad-hoc signature (for sideloader compatibility) —
  downloadable as a workflow artifact.

## Build

Everything runs in CI on `macos-15` runners. To run it locally you need a Mac
with Xcode + command line tools:

```sh
./scripts/build-deps.sh        # OpenSSL 3.0.16, zlib 1.3.1, Boost 1.85.0 (arm64 iOS)
./scripts/build-i2pd.sh        # cmake + leetal/ios-cmake -> i2pd static libs
./scripts/build-app.sh         # daemon core + UIKit shell + app-proxy extension -> ios2pd.app
./scripts/make-ipa.sh          # assemble bundle + package ios2pd-unsigned.ipa
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

## Using the I2P VPN

The bundled Network Extension only works when the app is signed with a
**paid** Apple Developer account whose provisioning profile includes the
**Network Extensions** capability (`com.apple.developer.networking.networkextension`,
see `ios/entitlements.plist`). Free personal-team signing does not grant this
entitlement, so the VPN toggle won't appear.

1. Sign the IPA with your paid certificate (in Sideloadly, make sure nested
   extensions are signed and the Network Extensions entitlement is applied).
2. Install and launch ios2pd, tap **Start**, and wait until the log shows the
   router has built tunnels.
3. Open **Settings → VPN** and flip **ios2pd I2P VPN** on.
4. Browse `.i2p` sites in any app (e.g. Safari → `http://i2p.i2p`). Clearnet
   traffic is unaffected.
5. Keep ios2pd open in the foreground — iOS suspends backgrounded apps, which
   stops the router (see caveats).

## Caveats

* **Background execution:** iOS suspends apps that are not foregrounded, so
  the router keeps running while the app is open but stops once the OS suspends
  it. Keeping ios2pd foregrounded is required for the VPN to work.
* **Runtime on device is experimental.** The build is verified to compile and
  package; networking behaviour (interface enumeration, tunnels, reseeding) on
  a real device depends on entitlements and iOS network policies.
* `getifaddrs`/interface access on iOS is restricted; the router may see only
  loopback until network entitlements are granted when signing.
* The app-proxy VPN answers `*.i2p` DNS itself (fake IPs in `10.192.0.0/10`);
  UDP apps are not yet relayed.

## Layout

```
.github/workflows/build-ipa.yml  CI pipeline (deps → libs → app → IPA)
scripts/                         build scripts (macOS/Xcode)
ios/main.mm                      UIKit shell + daemon bridge
ios/Info.plist                   app bundle metadata
ios/entitlements.plist           network-extension entitlement (for signing)
ios/ext/                         NEAppProxyProvider (.i2p VPN)
i2pd/                            i2pd source (submodule, pinned to 2.61.0)
```

## Credits

* [PurpleI2P/i2pd](https://github.com/PurpleI2P/i2pd) — the daemon (BSD-3).
* [leetal/ios-cmake](https://github.com/leetal/ios-cmake) — iOS CMake toolchain.
* Official i2pd iOS build docs: https://i2pd.readthedocs.io/en/latest/devs/building/ios/
