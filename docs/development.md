# Development

## Requirements

- macOS 14+
- Swift 6.3 / Xcode 26+

## Build & run

```bash
swift build
swift run Hachidori        # launches the app
swift test                 # unit + integration tests
```

Development flags (debug builds only; release builds ignore them):

```bash
swift run Hachidori --record               # start recording immediately, without touching the system proxy
swift run Hachidori --record --lan         # …and accept LAN devices (bind 0.0.0.0)
swift run Hachidori --record --port 9091   # …on another port (beside an instance already on 9090)
swift run Hachidori --serve 9090           # headless proxy (no UI), logs to stderr
swift run Hachidori --support-dir /tmp/hd  # keep the CA, saved rules and proxy backup in another folder
```

Quick check over plain HTTP, with the app recording:

```bash
curl -x http://127.0.0.1:9090 http://example.com
```

## Architecture

| Layer | Module | Notes |
|-------|--------|-------|
| Proxy engine | `ProxyCore` | SwiftNIO-based MITM proxy, buffered HTTP forwarding + capture |
| UI | `HachidoriApp` | SwiftUI `NavigationSplitView` / `Table`, native macOS components |

```
Sources/
  ProxyCore/       ProxyServer, CertificateAuthority, WebSocket, Overrides, SavedRules,
                   Breakpoints, SystemProxy, Transaction (+ timing), BodyDecoding (gzip/deflate/br),
                   TextEncoding (charset from Content-Type / <meta charset>)
  HachidoriApp/    HachidoriApp (@main, AppModel), ContentView (shell/sidebar),
                   TrafficListView (filters + table), InspectorViews (tabs/headers),
                   BodyViews (pretty/raw/preview/hex + highlighter), TimingView, RulesView,
                   BreakpointViews, Format, TrafficModel
                   Resources/AppIcon.icns (app icon)
Packaging/         Info.plist for the .app bundle
scripts/           package.sh: release build, .app, signing, notarization, DMG
Tests/
  ProxyCoreTests/  unit + end-to-end integration tests
```

## Releasing

`scripts/package.sh <version>` builds a universal `dist/Hachidori.app` and
`dist/Hachidori-<version>.dmg`, signed and notarized. Pushing a `v*` tag does the same in
GitHub Actions and drafts a release. Setup and checklist (Korean):
[releasing.md](releasing.md).

The roadmap is in [PLAN.md](../PLAN.md).
