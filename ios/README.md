# Giga Grabber for iOS

Native SwiftUI port of [Giga Grabber](https://github.com/chanderlud/giga-grabber), maintained in a separate directory so the original Rust desktop application and CLI remain unchanged.

## Build

- Xcode 16 or newer
- iOS 17.0 deployment target
- Open `GigaGrabber.xcodeproj`
- Select the `GigaGrabber` scheme and an iOS Simulator or device
- Set your Apple Developer Team and a unique bundle identifier under Signing & Capabilities
- Build and run

No third-party Swift packages are required. The project uses SwiftUI, Foundation, URLSession, AppIntents, UIKit, CommonCrypto, and Apple's Network framework for iOS 17+ proxy configuration.

## Ported feature set

| Desktop Giga Grabber | iOS implementation |
| --- | --- |
| MEGA public file URLs | Native MEGA link parser and node metadata fetch |
| MEGA shared-folder URLs | Folder tree fetch, key unwrap, file/folder selection, preserved directory structure |
| End-to-end encrypted downloads | Local AES-CTR decryption using the file key from the public link |
| Concurrent download workers | Bounded async transfer scheduler (1–10 workers) |
| Weighted concurrency budget | Per-file weights matching the desktop size tiers, budget 1–100 |
| Pause / resume / cancel | Per-transfer controls and bulk pause/resume |
| Exponential retry and timeout policy | Configurable retries, minimum and maximum delays, exponential backoff, request timeout |
| Partial-file recovery | Encrypted partial files, 1 MiB rewind on resume, atomic finalization |
| Download session persistence | Versioned durable queue; re-fetches MEGA node keys at restore rather than persisting AES keys |
| Proxy mode: none | Direct URLSession connection |
| Proxy mode: single | One configured HTTP, HTTPS, SOCKS5 or SOCKS5H proxy |
| Proxy mode: random | Random selection from the configured proxy list for each MEGA API request and each file transfer; retry attempts reselect |
| Themes | Native system appearance with a matching accent palette for the bundled theme names |
| Progress bars and file sizes | Configurable transfer-row progress and size display |
| Update checking | Optional GitHub release check for the iOS fork |
| Desktop CLI for a MEGA URL | App Intent / Shortcuts action plus a `gigagrabber://download` automation URL with CLI-equivalent settings |
| Desktop save path | iOS folder picker with a security-scoped bookmark |
| Desktop file chooser | Native folder-tree selection screen |
| Desktop themes and settings page | Native Settings form |

## Proxy behavior

Proxy configuration is applied to the URLSession that performs the request using Apple's Network framework `ProxyConfiguration`, not merely displayed in Settings. HTTP proxies use HTTP CONNECT, HTTPS proxy endpoints use TLS to the proxy, and SOCKSv5 endpoints use Apple's SOCKSv5 configuration. Proxy credentials are passed through the proxy configuration. In Random mode, the proxy is chosen independently for each API request and each file-transfer response. If a transfer fails and is retried, the next attempt selects again. The selected proxy has failover-to-direct disabled.

A single HTTP response stream remains pinned to its selected proxy for that response. The app does not switch proxy in the middle of a TCP/HTTP stream. A MEGA HTTP 509 bandwidth-limit response pauses the transfer, consistent with the original worker behavior. The original project warns against proxy/VPN use to bypass MEGA's terms or account limits.

## iOS platform adaptations

iOS does not allow an ordinary foreground app to keep unrestricted worker processes running after suspension. Giga Grabber uses an iOS background-task grace period while the system permits it, persists the queue, and pauses transfers when that time expires. Restored transfers appear paused and require Resume. This is the iOS lifecycle equivalent of the desktop application's graceful session restoration, not a promise of indefinite background execution.

The original CLI cannot run as a normal process inside an iOS app sandbox. Its options are accepted through a `gigagrabber://download` URL for Shortcuts and other automation, while an App Intent can receive a MEGA link and queue it directly. URL query parameters: `url`, `max-workers`, `concurrency-budget`, `max-retries`, `timeout`, `min-retry-delay`, `max-retry-delay`, `proxy-mode` (`none`, `single`, `random`) and `proxies` (URLs separated by `|`). Percent-encode the URL values. The desktop GUI is replaced by native iPhone/iPad screens.

The proxy-list importer accepts one proxy URL per line in a `.txt` file; blank lines and lines beginning with `#` are ignored. Settings include a reset-to-defaults action. Download-session persistence is off by default, matching the desktop application's default.

## Source layout

- `GigaGrabber/App.swift`: app entry point and scene lifecycle
- `GigaGrabber/Models.swift`: settings, nodes, transfers and session records
- `GigaGrabber/MegaClient.swift`: MEGA API, public links, folder keys and AES crypto
- `GigaGrabber/ProxyHTTP.swift`: per-request proxy routing and streamed partial-file writer
- `GigaGrabber/DownloadManager.swift`: weighted workers, retries, resume/cancel and durable sessions
- `GigaGrabber/Views.swift`: downloads, link import, selection and settings UI
- `GigaGrabber/Shortcuts.swift`: App Intents and Shortcuts integration

## Tests

The shared Xcode scheme includes an XCTest target covering AES-128 ECB vectors, AES-CTR streaming across chunk boundaries, invalid crypto inputs, proxy URL parsing/default ports, settings normalization, transfer progress, and the session file's no-key persistence rule.

Run the iOS Simulator test suite from the repository root:

```sh
xcodebuild test \
  -project ios/GigaGrabber.xcodeproj \
  -scheme GigaGrabber \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  CODE_SIGNING_ALLOWED=NO
```

## License

The upstream project is MIT-licensed. Keep the original `LICENSE` file and copyright notice in redistributed copies and substantial portions.
