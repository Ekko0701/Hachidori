# Hachidori (ハチドリ)

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
| UI | `HachidoriApp` | SwiftUI `NavigationSplitView` / `Table`, native macOS components |

```
Sources/
  ProxyCore/       ProxyServer, CertificateAuthority, WebSocket, Overrides, Breakpoints,
                   SystemProxy, Transaction (+ timing), BodyDecoding (gzip/deflate/br),
                   TextEncoding (charset from Content-Type / <meta charset>)
  HachidoriApp/     HachidoriApp (@main, AppModel), ContentView (shell/sidebar),
                   TrafficListView (filters + table), InspectorViews (tabs/headers),
                   BodyViews (pretty/raw/preview/hex + highlighter), TimingView, RulesView,
                   BreakpointViews, Format, TrafficModel
Tests/
  ProxyCoreTests/  unit + end-to-end integration tests
```

## Build & run

```bash
swift build
swift run Hachidori        # launches the app
swift test                # unit + integration tests
```

Development flags:

```bash
swift run Hachidori --record           # start recording immediately, without touching the system proxy
swift run Hachidori --record --lan     # …and accept LAN devices (bind 0.0.0.0)
swift run Hachidori --record --port 9091   # …on another port (beside an instance already on 9090)
swift run Hachidori --serve 9090       # headless proxy (no UI), logs to stderr
```

## Try it (HTTP)

1. Launch the app and press **Record** (starts the proxy on `127.0.0.1:9090`).
2. Route traffic through it:

```bash
curl -x http://127.0.0.1:9090 http://example.com
```

The request appears live in the list; select it to inspect headers, body (pretty / raw /
preview / hex; legacy charsets such as EUC-KR are decoded from the declared
charset), and a timing waterfall. The sidebar groups traffic per device (this Mac and
each LAN client by IP), so several phones can share one proxy without mixing up. For HTTPS, install and trust the Root CA from the
**Certificate** toolbar popover first.

## Testing a real device

Step-by-step guide (Korean) for pointing an iOS/Android build at Hachidori and
rewriting its API / WebView responses: [docs/device-testing.md](docs/device-testing.md).

## Requirements

- macOS 14+
- Swift 6.3 / Xcode 26+
