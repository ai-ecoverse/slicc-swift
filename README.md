# slicc-swift

SLICC's local proxy for macOS and iOS: the Swift twin of [slicc-node](https://github.com/ai-ecoverse/slicc-node). The new SLICC on `*.sliccy.ai` sends program traffic (curl, git, npm) through the kernel's `localProxyTransport({ url, key })`, which talks to this proxy on loopback. The proxy can also share folders from the user's disk with the page ([Host folders](#host-folders)).

## Launcher

```sh
swift run slicc-swift
```

It starts the proxy on `127.0.0.1` (never another interface) with a fresh proxy key, prints the proxy URL and the launch URL, and opens the launch URL in the default browser:

```
https://seven.sliccy.ai/#proxy=http%3A%2F%2F127.0.0.1%3A52731&key=<43-char base64url key>
```

Options:

- `--port PORT`: default `0`, any free port.
- `--page URL`: default `https://seven.sliccy.ai/`.
- `--mount PATH[:NAME][:ro]`: shares a folder with the page, and can be repeated. See [Host folders](#host-folders).
- `--no-open`: prints the launch URL without opening a browser.
- `--quiet`: does not log host folder grants and writes to stderr.

The binary is not signed or notarized.

## Library

```swift
import SliccSwift

let folders = HostFolder.load(["/Users/me/project:project", "/Users/me/docs:docs:ro"])
let proxy = LocalProxy(folders: folders)
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
- **Probe:** `X-Slicc-Raw-Probe: 1` answers `{"rawFetch":1,"requestBodyStreaming":false,"maxRequestBodyBytes":268435456}`. With at least one folder exported, it adds `"hostfs":1`.
- **Errors:** a non-200 status with `X-Proxy-Error: 1` and `{"error":"…"}`. An unreachable upstream is `502 fetch failed: …`, and a `206` that came back encoded is `502` as well.

## Security gate

The checks run in this order:

1. **Host:** the `Host` header must be `127.0.0.1`, `localhost` or `[::1]` with the bound port. This blocks DNS rebinding. Otherwise `403 host not allowed`.
2. **Path:** `/api/fetch-proxy` (`POST`) and the [host folder](#host-folders) paths pass. Anything else gets `404 not found`.
3. **Origin:** the request needs an `Origin` of the form `https://<label>.sliccy.ai`, which covers `seven` and the branch hosts but not `www` or the apex. An origin listed in `SLICC_PROXY_ALLOWED_ORIGINS` (comma-separated, for local development) also passes. Otherwise `403 origin not allowed`.
4. **Preflight:** an `OPTIONS` request answers `204` with `Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS`, `Access-Control-Allow-Headers: Content-Type, X-Bridge-Token, X-Slicc-Raw-Request, X-Slicc-Raw-Probe, X-Hostfs-Token, X-Hostfs-Request`, and `Access-Control-Max-Age: 600`. It adds `Access-Control-Allow-Private-Network: true` when the browser asks for Private or Local Network Access.
5. **Method:** each path takes only its own methods. Any other gets `405`, with `Allow` listing them and `OPTIONS`.
6. **Proxy key:** the per-process key must arrive in the `X-Bridge-Token` header and is compared in constant time. It is never accepted in a query string. Otherwise `403 proxy key missing or wrong`. `/api/hostfs`, `/api/hostfs/write` and `/api/hostfs/watch` take a host folder token in `X-Hostfs-Token` instead.

Every refusal carries `X-Proxy-Error: 1` and `{"error":"…"}`. Responses to an allowed origin echo it in `Access-Control-Allow-Origin` (without credentials) and expose `X-Proxy-Error, X-Hostfs-Errno, ETag, Content-Range`.

## Host folders

This is slicc-node's [host folders](https://github.com/ai-ecoverse/slicc-node#host-folders) contract (`@ai-ecoverse/slicc-node` 2.1.0, design in [slicc-node#13](https://github.com/ai-ecoverse/slicc-node/issues/13)). The client is slicc-kernel's `hostfs` mount driver.

**Export.** `--mount PATH[:NAME][:ro]`, or `HostFolder.load` in the library, exports a folder. Its root is `realpath`'d at start. A missing path or a file is skipped with a warning, and so is a name that is taken. The name defaults to the folder's last component. Names never reveal host paths.

| path | methods | auth |
| --- | --- | --- |
| `/api/hostfs/grant` | `POST`, `DELETE` | `X-Bridge-Token` |
| `/api/hostfs/mounts` | `POST` | `X-Bridge-Token` |
| `/api/hostfs` | `POST` | `X-Hostfs-Token` |
| `/api/hostfs/write` | `PUT` | `X-Hostfs-Token` |
| `/api/hostfs/watch` | `POST` | `X-Hostfs-Token` |

**Tokens.** `POST /api/hostfs/grant` with the key and `{"mount","readonly"?}` answers `{"token","mount","readonly","capabilities":{"maxIo":16777216,"symlinks":true,"chmod":true,"caseInsensitive","normalization":"nfd-insensitive"}}`. An unknown mount is `ENOENT`.

- A token reaches only its folder, and only from the origin that was granted it. `readonly: true`, or an export marked `:ro`, makes every write `EROFS`.
- A token lives in memory until `DELETE /api/hostfs/grant` with `{"token"}`, until the process exits, or until 5 minutes pass with no request and no open watch. Its file handles close with it. A dead, unknown or foreign token is `403 hostfs token missing, unknown or revoked` with `X-Proxy-Error: 1`.
- Tokens are never accepted in a query string and never logged. The proxy keeps only their SHA-256.
- `caseInsensitive` is probed on the folder's volume.
- `POST /api/hostfs/mounts` answers `[{"name","readonly"}]`.

**Paths** are relative to the folder, `/`-separated, with `""` for the root. `..`, a leading `/` and NUL are refused (`EACCES`, `EINVAL`). Every operation resolves the parent with `realpath` and refuses it outside the folder (`EACCES`). The last component has lstat semantics, and files open with `O_NOFOLLOW`, so `open` on a symlink is `ELOOP`. Operations that change the namespace hold an exclusive lock and all others a shared one, so a page cannot swap a directory for a symlink between the check and the use.

**Operations:** `POST /api/hostfs` with a JSON body of at most 1 MiB, `{"op",…}`:

| op | body | answer |
| --- | --- | --- |
| `stat` | `path` | `attr` |
| `list` | `path` | `{"entries":[{"name","attr"}]}`, without entries that vanish meanwhile |
| `mkdir` | `path` | `{}`, not recursive |
| `rmdir` | `path` | `{}` |
| `unlink` | `path` | `{}`, `EISDIR` for a directory |
| `rename` | `from`, `to` | `{}`; a directory onto a non-empty one is `ENOTEMPTY` |
| `symlink` | `target`, `path` | `{}`; `target` is stored as given |
| `readlink` | `path` | `{"target"}` |
| `setattr` | `path`, `mode?`, `mtime?` (ms) | `{}`; `mode` on a symlink is `EINVAL` |
| `statfs` | | `{"bsize","blocks","bfree","bavail"}` |
| `open` | `path`, `write?`, `create?`, `truncate?`, `exclusive?`, `mode?` | `{"fh","attr"}` |
| `read` | `fh`, `offset`, `size` (at most `maxIo`), `ifMatch?` | the bytes, with `ETag` and `Content-Range`; short at EOF, empty past it |
| `release` | `fh` | `{"attr"}` for a write handle, `{}` otherwise |

The root can't be removed or renamed (`EBUSY`). `attr` is `{"kind":"file"|"directory"|"symlink","size","mtime","mode","ino","etag"}`, with `mtime` in ms, `mode` the permission bits and `etag` `"<size>-<mtimeNs>-<ino>"`. A grant holds at most 4096 handles (`EMFILE`).

**Reads.** A handle opened without `write`, `create`, `truncate` or `exclusive` is a name and holds nothing open between calls. Each `read` opens the file again and answers `ESTALE` when `ifMatch` differs from the current etag. `read` on a write handle reads its descriptor and ignores `ifMatch`.

**Writes happen in place,** like `open(2)`. `create`, `exclusive` (with `create`), `truncate` and `mode` (default `0666` minus the umask) apply at `open`. Then `PUT /api/hostfs/write` with `X-Hostfs-Request: {"fh","offset"}` and at most `maxIo` bytes `pwrite`s the body as it streams in, and answers `{}`. Hard links, extended attributes, ACLs and ownership survive. `release` closes the descriptor.

**Watch.** `POST /api/hostfs/watch` answers `200 application/x-ndjson` and streams lines:

```
{"mount":"project","paths":["src/a.ts","src"]}
{"mount":"project","all":true}
{"ping":1}
```

- `paths` names what changed and its parent directory, coalesced over 50 ms. Past 256 paths, or when FSEvents drops events, the line is `all`. A watcher that fails to start retries every second, with one `all` when it is lost and one when it is back.
- A ping goes out every 15 s. The stream ends when a token it carries is revoked or expires, or when the proxy stops.
- `X-Hostfs-Token` may list several tokens, comma-separated, so one stream serves every mount.
- The watcher is FSEvents, so it runs on macOS. On iOS the stream carries only pings.

**Errors.** A file system error carries `X-Hostfs-Errno: <name>` and `{"errno","message"}`. The message never contains a host path.

| errno | status |
| --- | --- |
| `ENOENT` | 404 |
| `EACCES`, `EPERM`, `EROFS` | 403 |
| `EEXIST`, `ENOTEMPTY`, `EISDIR`, `ENOTDIR`, `EBUSY`, `ESTALE` | 409 |
| `EINVAL`, `ENAMETOOLONG`, `ELOOP` | 400 |
| `EBADF` | 410 |
| `ENOSPC`, `EFBIG` | 507 |
| anything else (`EIO`, `EMFILE`, …) | 500 |

## Development

`npm run lint` runs the slicc lint tools and `swift format lint`. `swift test` runs the integration tests, which start a loopback upstream and the proxy and cover the protocol, the gate and host folders (traversal and symlink escapes, read-only tokens, foreign origins, token expiry, in-place writes and the watch stream). Releases are GitHub tags only, via semantic-release.

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
4. **Host routes.** Host folders are here. Sudo approval and handoff come as the new SLICC grows those features.
5. **Leaf libraries.** `swift-optel` and `swift-widgetkit`, which have no SLICC dependencies and can move any time.
6. **Tray stack.** `swift-traysession`, then `swift-trayfollower`, then `swift-traykit`, when the tray and cloud story lands in slicc-node.
7. **Sliccstart.** The `swift-launcher` app goes last on macOS, because it needs everything above plus signing and notarization.
8. **iOS app.** Together with the iOS leader (ai-ecoverse/slicc#3809), on top of 5 and 6.
