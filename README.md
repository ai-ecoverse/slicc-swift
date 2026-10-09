# slicc-swift

SLICC's local proxy for macOS and iOS: the Swift twin of [slicc-node](https://github.com/ai-ecoverse/slicc-node). The new SLICC on `*.sliccy.ai` sends program traffic (curl, git, npm) through the kernel's `localProxyTransport({ url, key })`, which talks to this proxy on loopback. The proxy can also share folders from the user's disk with the page ([Host folders](#host-folders)) and serve the page's kernel servers on `http://<port>.kernel.localhost/` ([Kernel services](#kernel-services)).

## Launcher

```sh
swift run slicc-swift
```

It starts the proxy on `127.0.0.1:17117` (never another interface) with its proxy key, prints the proxy URL and the launch URL, and opens the launch URL in the default browser. The key and port stay the same when it starts again, after an update, a crash or a reboot, so an open SLICC page reconnects without a new launch URL (see [Restarts](#restarts)):

```
https://seven.sliccy.ai/#proxy=http%3A%2F%2F127.0.0.1%3A52731&key=<43-char base64url key>
```

Options:

- `--port PORT`: default `17117`, or any free port with `--ephemeral`.
- `--page URL`: default `https://seven.sliccy.ai/`.
- `--mount PATH[:NAME][:ro]`: shares a folder with the page, and can be repeated. See [Host folders](#host-folders).
- `--kernel-port PORT`: the port on `127.0.0.1` for `http://<port>.kernel.localhost/`, default `80`. See [Kernel services](#kernel-services).
- `--no-kernel`: does not serve the page's kernel on `<port>.kernel.localhost`.
- `--rotate-key`: replaces the stored key, so pages and launch URLs holding the old one stop working.
- `--ephemeral`: uses a fresh key and any free port, and stores nothing: the key dies with the process.
- `--no-open`: prints the launch URL without opening a browser.
- `--quiet`: does not log host folder grants, writes and kernel requests to stderr.

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

`LocalProxy` mints a fresh key unless given one; `ProxyIdentity.persistentKey(directory:rotate:warn:)` returns the stored one, creating it if needed, and `ProxyIdentity.configDirectory()` names the directory. `LocalProxy` also takes `portFallback` (listen on any free port when `port` is taken), `kernelPort` (default `80`, `nil` for off) and `warn`. `run(onListening:)` passes the bound kernel port too, or `nil` when the listener is off or could not bind.

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
- **Probe:** `X-Slicc-Raw-Probe: 1` answers `{"rawFetch":1,"requestBodyStreaming":false,"maxRequestBodyBytes":268435456}`. With at least one folder exported, it adds `"hostfs":1`. With the [kernel listener](#kernel-services) up, it adds `"kernelTunnel":1,"kernelPort":<port>`.
- **Errors:** a non-200 status with `X-Proxy-Error: 1` and `{"error":"…"}`. An unreachable upstream is `502 fetch failed: …`, and a `206` that came back encoded is `502` as well.

## Restarts

This is slicc-node's [restarts](https://github.com/ai-ecoverse/slicc-node#restarts) contract (slicc-node#20). The page stores `{ url, key }` from the launch fragment, and the launcher keeps both valid across restarts, so the page reconnects on its own: network through the same proxy, host folders by asking for new tokens, and the kernel tunnel with the same key.

- **Key file.** The key lives in `key` in the config directory: `$XDG_CONFIG_HOME/slicc-swift` when that is set, else `~/Library/Application Support/slicc-swift` on macOS and the app's Application Support directory on iOS. It is created on first run, mode `0600` in a `0700` directory, and published whole (written aside, then linked in), so two first starts at once agree on one key. A file or directory open to others is set back to `0600` or `0700` with a warning. A file without a key gets a new one, also with a warning. The key is the same format as before: 32 random bytes, base64url. It is slicc-swift's own and is not shared with slicc-node, so a page that switches from one proxy to the other needs the new launch URL once.
- **Port.** The default is `17117`, the same as slicc-node's. If it is taken, for example by a running slicc-node, the launcher warns `port 17117 is taken; using a free port, so pages from an earlier launch cannot reconnect` and takes any free port. A port given with `--port` that is taken stops the launcher with exit code `1`.
- **Host folders** are only as persistent as the command line: pass the same `--mount` options again, and the kernel's driver re-grants each folder by name when its old token answers `403`. Tokens never survive a restart.
- `--rotate-key` writes a new key. `--ephemeral` keeps the old behaviour: a fresh key, any free port, nothing stored. Both together exit with code `2`.

## Security gate

The checks run in this order:

1. **Host:** the `Host` header must be `127.0.0.1`, `localhost` or `[::1]` with the bound port. This blocks DNS rebinding. Otherwise `403 host not allowed`.
2. **Path:** `/api/fetch-proxy` (`POST`) and the [host folder](#host-folders) paths pass, and `/api/kernel-tunnel` takes only a WebSocket upgrade (see [Kernel services](#kernel-services)). Anything else gets `404 not found`.
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

## Kernel services

This is slicc-node's [kernel services](https://github.com/ai-ecoverse/slicc-node#kernel-services) contract (slicc-node#19). A kernel port `N` in the page is `http://N.kernel.localhost/`; the proxy carries top-level navigations and WebSockets (vite HMR) there through a tunnel into the page, which calls `kernel.dial({ port: N })`.

**Listener.**

- It listens on `127.0.0.1:80` by default, never another interface. `--kernel-port` picks another port, and then URLs carry it: `http://8400.kernel.localhost:8080/`.
- If the port cannot be bound, it warns `kernel services are off: cannot listen on 127.0.0.1:80 (EADDRINUSE); try --kernel-port` and runs on without it. The probe then leaves out `kernelTunnel`.
- It reads the first request head (64 KiB at most, within 30 s) and takes exactly one `Host` of the form `<1–65535>.kernel.localhost`, with no port or the listener's own port, no leading zeros and no trailing dot. It opens a stream to that kernel port, sends what it has read and then pipes bytes both ways, so keep-alive, chunked bodies and WebSocket upgrades pass through.

**Errors** are plain text with `X-Proxy-Error: 1` and `Connection: close`:

| case | answer |
| --- | --- |
| `Host` not `<port>.kernel.localhost` | `421` |
| malformed request line, or not exactly one `Host` | `400` |
| head over 64 KiB | `431` |
| no page connected | `502 no seven page connected` |
| the page answers `RESET` with `ECONNREFUSED` | `502 nothing listening on kernel port N` |
| the page answers `RESET` with another reason | `502 kernel port N: <reason>` |
| no `OPENED` within 10 s | `504 kernel port N did not answer` |

**Tunnel.** The page opens a WebSocket to `ws://127.0.0.1:<proxy port>/api/kernel-tunnel` with the subprotocols `slicc.kernel-tunnel.v1` and `slicc.key.<key>`. Before upgrading, the proxy checks the loopback `Host` (`403 host not allowed`), the path and that the listener is up (`404`), the `Origin` as in the [gate](#security-gate) (`403 origin not allowed`), that `slicc.kernel-tunnel.v1` is offered (`400`) and the key in constant time (`403 proxy key missing or wrong`). Refusals are `{"error":…}` without CORS headers. It selects `slicc.kernel-tunnel.v1`, so the key is never echoed.

Every message is binary: a `u8` type, a big-endian `u32` stream id, then the payload. The proxy opens every stream and numbers them from 1.

| type | direction | payload |
| --- | --- | --- |
| `1` OPEN | proxy → page | `u16` BE kernel port |
| `2` OPENED | page → proxy | empty |
| `3` DATA | both | 1 to 65 536 bytes |
| `4` END | both | empty, a half-close |
| `5` RESET | both | UTF-8 reason, such as `ECONNREFUSED` |
| `6` CREDIT | both | `u32` BE count of bytes consumed, at least 1 |

- **Flow control:** each side may have at most 256 KiB of DATA per stream and direction that the other has not credited. The proxy credits bytes once the browser's socket has taken them, and stops reading the browser while its own window is empty.
- **Lifecycle:** the page answers OPEN with OPENED or RESET. A stream ends after END both ways or a RESET from either side. Frames for an unknown id are ignored.
- **Violations:** DATA or END before OPENED, DATA or END after the page's END, empty DATA, DATA past the window or CREDIT past it reset the stream with `EPROTO`. A text message closes the tunnel with `1003`, an unknown type, a short or malformed frame or OPEN from the page with `1002`, and a message over 65 541 bytes with `1009`. Closing the tunnel resets its streams.
- **Liveness:** the proxy pings every 15 s and drops a tunnel that misses a pong.
- **Several tabs:** the most recently connected tunnel takes new streams. When it closes, the one before it that is still open takes over.

Any local process, and any web page Chrome lets reach loopback, can reach kernel services on the kernel port, like any dev server on localhost. Run with `--no-kernel` to keep them inside the page.

## Development

`npm run lint` runs the slicc lint tools and `swift format lint`. `swift test` runs the integration tests, which start a loopback upstream and the proxy and cover the protocol, the gate, host folders (traversal and symlink escapes, read-only tokens, foreign origins, token expiry, in-place writes and the watch stream) restarts (the stored key and its permissions, `--rotate-key`, `--ephemeral`, the port fallback and two first starts at once, against the built launcher) and kernel services (the `Host` allowlist, the tunnel gate, forwarded HTTP and WebSocket exchanges, credits and backpressure, resets, protocol violations and several tabs, against a simulated page). Releases are GitHub tags only, via semantic-release.

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
