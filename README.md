# ProxyBoy

A native macOS HTTP/HTTPS debugging proxy — inspect requests and responses while
developing apps and websites. Inspired by Proxyman; UI inspired by GitKraken / Fork.

> Status: **Phase 0–4 complete** — HTTP **and HTTPS (TLS MITM)** interception, WebSocket
> capture, system-proxy auto-config, rules (Map Local / Rewrite), breakpoints, and a full
> inspector UI (filters, host grouping, syntax highlighting, previews, timing waterfall).
> Next: persistence & HAR export, then signing/notarization — see [PLAN.md](PLAN.md).

## Architecture

| Layer | Module | Notes |
|-------|--------|-------|
| Proxy engine | `ProxyCore` | SwiftNIO-based MITM proxy, buffered HTTP forwarding + capture |
| UI | `ProxyBoyApp` | SwiftUI `NavigationSplitView` / `Table`, native macOS components |

```
Sources/
  ProxyCore/       ProxyServer, CertificateAuthority, WebSocket, Overrides, Breakpoints,
                   SystemProxy, Transaction (+ timing), BodyDecoding (gzip/deflate/br)
  ProxyBoyApp/     ProxyBoyApp (@main, AppModel), ContentView (shell/sidebar),
                   TrafficListView (filters + table), InspectorViews (tabs/headers),
                   BodyViews (pretty/raw/preview/hex + highlighter), TimingView, RulesView,
                   BreakpointViews, Format, TrafficModel
Tests/
  ProxyCoreTests/  unit + end-to-end integration tests
```

## Build & run

```bash
swift build
swift run ProxyBoy        # launches the app
swift test                # unit + integration tests
```

Development flags:

```bash
swift run ProxyBoy --record           # start recording immediately, without touching the system proxy
swift run ProxyBoy --serve 9090       # headless proxy (no UI), logs to stderr
```

## Try it (HTTP)

1. Launch the app and press **Record** (starts the proxy on `127.0.0.1:9090`).
2. Route traffic through it:

```bash
curl -x http://127.0.0.1:9090 http://example.com
```

The request appears live in the list; select it to inspect headers, body (pretty / raw /
preview / hex), and a timing waterfall. For HTTPS, install and trust the Root CA from the
**Certificate** toolbar popover first.

## Requirements

- macOS 14+
- Swift 6.3 / Xcode 26+
