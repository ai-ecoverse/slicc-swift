# slicc-swift

SLICC's local proxy for macOS and iOS: the Swift twin of [slicc-node](https://github.com/ai-ecoverse/slicc-node). The new SLICC on `*.sliccy.ai` sends program traffic (curl, git, npm) through the kernel's `localProxyTransport({ url, key })`, which talks to this proxy on loopback.

## Launcher

```sh
swift run slicc-swift
```

It starts the proxy on `127.0.0.1` (never another interface) with a fresh proxy key, prints the proxy URL and the launch URL, and opens the launch URL in the default browser:

```
https://seven.sliccy.ai/#proxy=http%3A%2F%2F127.0.0.1%3A52731&key=<43-char base64url key>
```

Options: `--port PORT` (default `0`, any free port), `--page URL` (default `https://seven.sliccy.ai/`), `--no-open`. The binary is not signed or notarized.

## Library

```swift
import SliccSwift

let proxy = LocalProxy()
try await proxy.run { proxyURL in
  print(LocalProxy.launchURL(proxyURL: proxyURL, key: proxy.key))
}
```

## Protocol

It's the protocol in [slicc-node's README](https://github.com/ai-ecoverse/slicc-node#protocol), the raw mode of SLICC's `/api/fetch-proxy`. The kernel's `localProxyTransport` and `probeLocalProxy` (`@ai-ecoverse/slicc-kernel` 1.5.0) are the client.

- **Request:** `POST /api/fetch-proxy`.
  - **Head:** JSON in `X-Slicc-Raw-Request`, `{"url","method","headers":[[name,value],…]}`. Request heads may be up to 1 MiB. `url` must be http or https and `method` a token, otherwise `400`.
  - **Body:** buffered up to 256 MiB (`413` past that) and not sent for GET or HEAD.
  - **Headers:** hop-by-hop headers, `Host`, `Content-Length`, `Accept-Encoding`, `Expect` and `Proxy-Authorization` are dropped. Repeats are folded with `, `, and `Cookie` with `; `. Upstream gets `Accept-Encoding: gzip, deflate, br`, or `identity` when the request has `Range` or `If-Range`.
- **Response:** `200 application/vnd.slicc.raw-fetch` with `Cache-Control: no-store`.
  - **Head:** a big-endian u32 length, then the JSON head `{"status","statusText","headers":[[name,value],…],"url"}`. Every `Set-Cookie` is its own entry, and no hop-by-hop headers are included.
  - **Body:** the decoded upstream body streams after the head.
  - **Redirects:** not followed.
- **Decoding:** `gzip`, `x-gzip`, `deflate` and `br` are decoded, including stacked codings. When every coding was undone, `Content-Encoding` and `Content-Length` are dropped. Bodiless responses keep both.
- **Probe:** `X-Slicc-Raw-Probe: 1` answers `{"rawFetch":1,"requestBodyStreaming":false,"maxRequestBodyBytes":268435456}`.
- **Errors:** a non-200 status with `X-Proxy-Error: 1` and `{"error":"…"}`. An unreachable upstream is `502 fetch failed: …`, and a `206` that came back encoded is `502` as well.

## Security gate

The checks run in this order:

1. **Host:** the `Host` header must be `127.0.0.1`, `localhost` or `[::1]` with the bound port. This blocks DNS rebinding. Otherwise `403 host not allowed`.
2. **Path:** anything other than `/api/fetch-proxy` gets `404 not found`.
3. **Origin:** the request needs an `Origin` of the form `https://<label>.sliccy.ai`, which covers `seven` and the branch hosts but not `www` or the apex. An origin listed in `SLICC_PROXY_ALLOWED_ORIGINS` (comma-separated, for local development) also passes. Otherwise `403 origin not allowed`.
4. **Preflight:** an `OPTIONS` request answers `204` with `Access-Control-Allow-Methods: POST, OPTIONS`, the transport headers in `Access-Control-Allow-Headers`, and `Access-Control-Max-Age: 600`. It adds `Access-Control-Allow-Private-Network: true` when the browser asks for Private or Local Network Access.
5. **Method:** anything other than `POST` gets `405`.
6. **Proxy key:** the per-process key must arrive in the `X-Bridge-Token` header and is compared in constant time. It is never accepted in a query string. Otherwise `403 proxy key missing or wrong`.

Every refusal carries `X-Proxy-Error: 1` and `{"error":"…"}`. Responses to an allowed origin echo it in `Access-Control-Allow-Origin` (without credentials) and expose `X-Proxy-Error`.

## Development

`npm run lint` runs the slicc lint tools and `swift format lint`. `swift test` runs the integration tests, which start a loopback upstream and the proxy and cover the protocol and the gate. Releases are GitHub tags only, via semantic-release.

## What else is in SLICC's Swift code

These numbers are lines of source and lines of tests at `ai-ecoverse/slicc` `origin/main`.

| Package | Source / tests | What it is |
| --- | --- | --- |
| `swift-server` | 15.6k / 21k | Hummingbird server for Sliccstart. Raw fetch proxy (ported here). Default fetch-proxy mode with secret masking, SigV4 and HMAC signing (`Keychain`, `Signing`, about 2k). CDP proxy and Chrome/Electron launch (`Browser`, `WebSocket`, about 5.9k). Host FS routes, sudo approval, handoff, lick system and activity tracking (`Server`). Tray follower glue (`Follower`). |
| `swift-launcher` | 11.2k / 13.5k | Sliccstart, the macOS app that finds Chromium browsers and Electron apps and launches them with SLICC. It depends on every library below and on AppUpdater. |
| `swift-trayfollower` | 4.3k / 3.8k | WebRTC tray follower transport, shared by Sliccstart, swift-server and the iOS app. |
| `swift-traykit` | 1.7k / 2.3k | Tray VFS on top of trayfollower. |
| `swift-traysession` | 1.0k / 1.2k | Tray session state. |
| `swift-widgetkit` | 2.9k / 1.5k | Native widgets and the widget gallery. |
| `swift-optel` | 1.8k / 2.6k | Operational telemetry, the same format as helix-rum-js. |
| `ios-app` | about 250 files | iOS follower, File Provider, share extension and widgets. |

## Proposed order

1. **Raw fetch proxy and launcher.** This repo.
2. **CDP bridge.** Move `Browser`, `WebSocket/CDPProxy` and the `/cdp` subprotocol gate into a `SliccCDP` target here, alongside ai-ecoverse/slicc-cdp, so the launcher can attach a local Chrome.
3. **Secrets in the proxy.** `Keychain`, `Signing` and the masking and unmasking in fetch-proxy, once the new SLICC has a secrets story.
4. **Host routes.** Host FS, sudo approval and handoff, as the new SLICC grows those features.
5. **Leaf libraries.** `swift-optel` and `swift-widgetkit`, which have no SLICC dependencies and can move any time.
6. **Tray stack.** `swift-traysession`, then `swift-trayfollower`, then `swift-traykit`, when the tray and cloud story lands in slicc-node.
7. **Sliccstart.** The `swift-launcher` app goes last on macOS, because it needs everything above plus signing and notarization.
8. **iOS app.** Together with the iOS leader (ai-ecoverse/slicc#3809), on top of 5 and 6.
