# Hachidori

A native macOS HTTP/HTTPS debugging proxy. See every request your apps and websites make,
inspect the responses, and change them on the fly.

<!-- screenshot: main window with captured traffic and a request open in the inspector -->

## Installation

1. Download `Hachidori-<version>.dmg` from the
   [latest release](https://github.com/Ekko0701/Hachidori/releases/latest).
2. Open the DMG and drag **Hachidori** into **Applications**.
3. Launch Hachidori from Applications.

Hachidori runs on macOS 14 or later, on Apple silicon and Intel Macs. Releases are signed
and notarized by Apple, so they open without a security warning.

From 0.1.3 on, Hachidori checks GitHub for new releases. When one is out, an **Update**
button appears in the toolbar; **Restart to Update** downloads it, checks its signature
and reopens the new version. **Hachidori → Check for Updates…** checks right away.

<!-- screenshot: the DMG window with Hachidori and the Applications shortcut -->

## Usage

### Capture traffic from this Mac

1. Press **Record** in the toolbar, or ⌘R.
2. Use your browser or app as usual. Requests appear in the list as they happen.
3. Press **Stop** when you are done.

While recording, Hachidori points this Mac's HTTP and HTTPS proxy at itself. Stopping or
quitting puts your previous proxy settings back. To manage the proxy yourself, turn off
**Auto-configure macOS system proxy** in the **Certificate** popover and use
`127.0.0.1:9090`.

<!-- screenshot: toolbar with the Record button -->

### Decrypt HTTPS

HTTPS traffic stays encrypted until you trust Hachidori's Root CA.

1. Click the **Certificate** button in the toolbar.
2. Click **Reveal Root CA in Finder**, then double-click `rootCA.pem` to add it to your
   login keychain.
3. In Keychain Access, open **Hachidori Root CA**, expand **Trust**, and set it to
   **Always Trust**.

Each installation creates its own Root CA. Its private key never leaves
`~/Library/Application Support/Hachidori` and is readable only by your user account.

<!-- screenshot: Certificate popover -->
<!-- screenshot: Keychain Access trust settings set to Always Trust -->

### Inspect a request

Select a request to open it in the inspector on the right.

- **Overview** shows the URL, method, status, content type and size at a glance.
- **Request** and **Response** show headers and the body as Pretty, Raw, Preview or Hex.
- **Timing** breaks the request down into connect, wait and download.

Use **Copy URL** or **Copy as cURL** to reproduce a request in the terminal. The filter bar
narrows the list by method, status or content type, and the search field matches the URL,
method or status.

<!-- screenshot: inspector showing a JSON response in Pretty mode -->

### Capture a phone or tablet

1. Connect the device and the Mac to the same Wi-Fi network.
2. In the **Certificate** popover, turn on **Test on physical devices (LAN)**, then restart
   recording.
3. On the device, set the Wi-Fi HTTP proxy to the address shown in the popover.
4. On the device, open that address in the browser to download the Root CA, install it,
   and trust it.

Each device appears separately in the sidebar. For iOS, Android and Flutter details, see
the [device testing guide](docs/device-testing.md) (Korean).

<!-- screenshot: Certificate popover with LAN testing on, showing the Mac's address -->
<!-- screenshot: sidebar with a device and its hosts -->

### Change responses

- **Rules** rewrite matching responses: replace the status code, headers or body, or
  answer locally without contacting the server (Map Local).
- **Breakpoints** pause matching requests or responses so you can edit them before they
  continue, or abort them.

Rules and the breakpoint URL filter are saved and come back the next time you open
Hachidori. The breakpoint switches always start off, so traffic never pauses until you
turn them on.

<!-- screenshot: Rules sheet with a rule open -->

## Development

Building from source, the project layout and the release process are described in
[docs/development.md](docs/development.md).

## License

[MIT](LICENSE) © 2026 Ekko0701
