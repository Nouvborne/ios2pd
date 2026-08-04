# ios2pd

[i2pd](https://github.com/PurpleI2P/i2pd) — the I2P anonymous-network daemon
written in C++ — ported to iOS, built as an **unsigned `.ipa`** by a GitHub
Actions workflow (macOS runners, no Mac or Apple Developer account needed).

## What this is

* A real cross-compile of **i2pd 2.61.0** for `arm64` iOS (device):
  * `libi2pd.a`, `libi2pdclient.a`, `libi2pdlang.a`
  * plus OpenSSL, zlib and Boost statically linked for iOS.
* A SwiftUI app (`ios/Swift/`) that embeds the i2pd daemon core (`DaemonUnix`)
  behind an ObjC bridge (`ios/I2pdCore.mm`) and runs the router on a
  background thread, with tabs: **Router**
  (Start/Stop, live log), **Browser** (in-app `.i2p` browser through the local
  HTTP proxy), **Tunnels** (custom tunnels editor), **i2pd** (enable + port for
  the HTTP proxy :4444, SOCKS :4447 and SAM :7656, log level) and **Proxy**
  (backloop.dev SSL + one-tap `.mobileconfig` install, optional silent-audio
  background keep-alive). The UI uses Liquid Glass (`glassEffect`) on iOS 26+
  with a material fallback on older iOS; minimum iOS is 15.0.
* A CI pipeline that produces an **unsigned IPA** — a `Payload/ios2pd.app`
  bundle with a valid ad-hoc signature (for sideloader compatibility) —
  downloadable as a workflow artifact.

## Build

Everything runs in CI on `macos-26` runners. To run it locally you need a Mac
with Xcode + command line tools:

```sh
./scripts/build-deps.sh        # OpenSSL 3.0.16, zlib 1.3.1, Boost 1.85.0 (arm64 iOS)
./scripts/build-i2pd.sh        # cmake + leetal/ios-cmake -> i2pd static libs
./scripts/build-app.sh         # daemon core + I2pdCore.mm + SwiftUI shell -> ios2pd.app
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

## Using the I2P VPN (not in the default IPA)

The **NEAppProxyProvider** extension (`ios/ext/`) is no longer shipped in the
default IPA. It requires a **paid** Apple Developer account whose provisioning
profile includes the **Network Extensions** capability
(`com.apple.developer.networking.networkextension`); free personal-team
signing does not grant this entitlement. The default IPA has no appex and no
restricted entitlements, so it sideloads on any free Apple ID.

If you have a paid account and want the VPN extension, add it back by editing
`scripts/build-app.sh` to call `./scripts/build-extension.sh`, re-adding
`com.apple.developer.networking.networkextension` to `ios/entitlements.plist`,
and signing the IPA with your paid certificate (in Sideloadly, make sure
nested extensions are signed and the Network Extensions entitlement is
applied).

## Using the backloop.dev Wi-Fi proxy (no paid account needed)

If you don't have a paid Apple Developer account, the VPN toggle won't appear
(see above). Instead, the **Proxy** tab installs a Wi-Fi profile that routes
all HTTP/HTTPS traffic through the local i2pd HTTP proxy via
[backloop.dev](https://backloop.dev) — a wildcard domain that resolves to
`127.0.0.1` with a publicly trusted (publicly known) loopback certificate.

1. Sign and install the IPA with any free Apple ID (Sideloadly/AltStore).
2. Launch ios2pd, open the **Router** tab and tap **Start**; wait for the log
   to show tunnels are built.
3. Open the **Proxy** tab → **Update SSL servers** (fetches the current
   backloop.dev certificate) → **Install proxy profile (.mobileconfig)** and
   approve the profile in Settings.
4. Optionally enable **Keep i2pd alive in background** (plays silent audio so
   iOS doesn't suspend the app; uses battery).
5. Browse `*.i2p` sites in Safari over **Wi-Fi** (manual HTTP proxy
   `ios2pd.backloop.dev:4444` → device loopback). This works on any free
   Apple ID. Note: `*.i2p` hostnames only resolve through the i2pd HTTP proxy,
   so this routes all browser traffic over I2P while enabled.

## Caveats

* **Background execution:** iOS suspends apps that are not foregrounded, so
  the router stops once the OS suspends the app. The **Proxy → Keep i2pd alive
  in background** switch (silent audio) mitigates this for the Wi-Fi proxy
  workflow, at some battery cost.
* **Runtime on device is experimental.** The build is verified to compile and
  package; networking behaviour (interface enumeration, tunnels, reseeding) on
  a real device depends on entitlements and iOS network policies.
* `getifaddrs`/interface access on iOS is restricted; the router may see only
  loopback until network entitlements are granted when signing.

## Layout

```
.github/workflows/build-ipa.yml  CI pipeline (deps → libs → app → IPA)
scripts/                         build scripts (macOS/Xcode)
ios/I2pdCore.h, ios/I2pdCore.mm  ObjC bridge: daemon control, config, SSL server
ios/Swift/                       SwiftUI app (Liquid Glass on iOS 26+)
ios/Info.plist                   app bundle metadata
ios/entitlements.plist           empty (no restricted entitlements; free-account friendly)
ios/ext/                         NEAppProxyProvider (optional; not shipped in the default IPA)
i2pd/                            i2pd source (submodule, pinned to 2.61.0)
```

## Credits

* [PurpleI2P/i2pd](https://github.com/PurpleI2P/i2pd) — the daemon (BSD-3).
* [leetal/ios-cmake](https://github.com/leetal/ios-cmake) — iOS CMake toolchain.
* Official i2pd iOS build docs: https://i2pd.readthedocs.io/en/latest/devs/building/ios/
