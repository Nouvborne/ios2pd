# ios2pd

[i2pd](https://github.com/PurpleI2P/i2pd) — the I2P anonymous-network daemon
written in C++ — ported to iOS as a VPN app, built as an **unsigned `.ipa`** by
a GitHub Actions workflow (macOS runners, no Mac needed).

## What this is

* A real cross-compile of **i2pd 2.61.0** for `arm64` iOS (device):
  `libi2pd.a`, `libi2pdclient.a`, `libi2pdlang.a`, plus OpenSSL, zlib and Boost
  statically linked for iOS.
* A SwiftUI app with two tabs:
  * **Home** — connect/disconnect, router status, uptime, tunnel counts.
  * **Logs** — live tail of the i2pd log.
* A **NEPacketTunnelProvider** extension (`ios/ext/`) that runs the i2pd router
  and exposes it to the whole system.

## How the VPN works

The router runs **inside the tunnel extension**, not inside the app. That is
the whole point: iOS suspends backgrounded apps, but it keeps a running VPN
extension alive, so the daemon stays up when you leave ios2pd.

The tunnel carries no packets. `includedRoutes` is empty, so nothing is routed
into the extension. What the tunnel actually does is publish
`NEProxySettings` for the device: HTTP/HTTPS traffic to hosts matching `i2p`
goes to the router's own HTTP proxy on `127.0.0.1:4444`, and everything else
takes its normal path. `.i2p` hostnames never need to resolve in DNS — the
proxy resolves them inside I2P.

So `*.i2p` works in Safari and any other app while connected, clearnet traffic
is untouched, and there is no userspace TCP/IP stack to maintain.

Consequences worth knowing:

* **Only HTTP/HTTPS is tunneled.** Non-HTTP I2P protocols (IRC, torrents) are
  not reachable; the SOCKS proxy, SAM bridge, I2CP and the web console are all
  disabled.
* **The extension has a much smaller memory budget than an app.** The generated
  config keeps the router lean — `notransit = true`, no transit tunnels,
  `bandwidth = L`, no ElGamal precomputation — so it does not relay for others.

The app talks to the extension over `sendProviderMessage`, which is how the
Logs tab and the router counters on Home get their data. There is deliberately
no app group: a sideloaded build is signed against a provisioning profile that
will not have one registered, and claiming an entitlement the profile does not
grant stops the extension from launching at all. The app also reads the
extension's real bundle id off disk rather than hardcoding it, since
sideloaders rewrite bundle ids.

## Build

Everything runs in CI on `macos-26` runners. Locally you need a Mac with Xcode
and command line tools:

```sh
./scripts/build-deps.sh       # OpenSSL 3.0.16, zlib 1.3.1, Boost 1.85.0 (arm64 iOS)
./scripts/build-i2pd.sh       # cmake + leetal/ios-cmake -> i2pd static libs
./scripts/build-app.sh        # SwiftUI app (pure Swift) -> ios2pd.app
./scripts/build-extension.sh  # i2pd + daemon core + provider -> ios2pdTunnel.appex
./scripts/make-ipa.sh         # assemble bundle + package ios2pd-unsigned.ipa
```

Artifacts land in `build/`. The workflow caches `build/deps-ios` between runs.

## Installing

1. Open the repo on GitHub → **Actions** → **Build unsigned iOS IPA**.
2. Run the workflow (or wait for the push trigger).
3. Download the `ios2pd-unsigned-ipa` artifact.

The IPA is unsigned, so it has to be re-signed before it will install
(Sideloadly, AltStore, or `codesign` with your own profile).

> **A paid Apple Developer account is required.** The app and its extension need
> `com.apple.developer.networking.networkextension` (`packet-tunnel-provider`),
> which free personal-team signing does not grant. With a free Apple ID the app
> installs but connecting fails.
>
> When re-signing, make sure the nested `.appex` is signed too and that the
> Network Extensions capability is applied to both bundles. Bundle ids may be
> rewritten freely; the app resolves the extension's id at runtime.

## Caveats

* **Runtime on device is experimental.** The build is verified to compile and
  package; reseeding, tunnel building and proxy behaviour on a real device
  depend on entitlements and iOS network policies.
* A cold start needs a reseed and a minute or two of tunnel building before
  `.i2p` addresses resolve.
* If iOS kills the extension for memory, the VPN drops. The Logs tab keeps the
  last session's output, since the log lives in the shared container.

## Layout

```
.github/workflows/build-ipa.yml  CI pipeline (deps → libs → app → appex → IPA)
scripts/                         build scripts (macOS/Xcode)
ios/Swift/                       SwiftUI app (Liquid Glass on iOS 26+)
ios/Info.plist                   app bundle metadata
ios/entitlements.plist           network extension entitlement
ios/ext/                         NEPacketTunnelProvider — runs the i2pd router
i2pd/                            i2pd source (submodule, pinned to 2.61.0)
```

## Credits

* [PurpleI2P/i2pd](https://github.com/PurpleI2P/i2pd) — the daemon (BSD-3).
* [leetal/ios-cmake](https://github.com/leetal/ios-cmake) — iOS CMake toolchain.
* Official i2pd iOS build docs: https://i2pd.readthedocs.io/en/latest/devs/building/ios/
