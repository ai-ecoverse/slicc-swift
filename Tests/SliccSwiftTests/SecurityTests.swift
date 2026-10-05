import AsyncHTTPClient
import Foundation
import NIOCore
import Testing

@testable import SliccSwift

func errorText(_ bytes: [UInt8]) -> String? {
  (try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: String])?["error"]
}

@Suite struct SecurityTests {
  static let probe = [(RawFetchProtocol.probeHeader, "1")]

  @Test func missingKeyIsRejected() async throws {
    try await withHarness { harness in
      let (response, bytes) = try await harness.post(key: nil, headers: Self.probe)
      #expect(response.status == .forbidden)
      #expect(errorText(bytes) == "proxy key missing or wrong")
      #expect(response.headers.first(name: RawFetchProtocol.errorHeader) == "1")
      #expect(response.headers.first(name: "access-control-allow-origin") == hostedOrigin)
    }
  }

  @Test(arguments: ["wrong", testKey + "x", String(testKey.dropLast()), testKey.uppercased()])
  func wrongKeyIsRejected(key: String) async throws {
    try await withHarness { harness in
      let (response, bytes) = try await harness.post(key: key, headers: Self.probe)
      #expect(response.status == .forbidden)
      #expect(errorText(bytes) == "proxy key missing or wrong")
    }
  }

  @Test func rejectedKeyNeverReachesUpstream() async throws {
    try await withHarness { harness in
      let head = rawHead(harness.upstream + "/echo", method: "POST")
      let (response, _) = try await harness.post(
        key: "wrong", headers: [(RawFetchProtocol.requestHeader, head)],
        body: .bytes(ByteBuffer(string: "x")))
      #expect(response.status == .forbidden)
      #expect(response.headers.first(name: "content-type") != RawFetchProtocol.contentType)
    }
  }

  @Test func originIsRequired() async throws {
    try await withHarness { harness in
      let (response, bytes) = try await harness.post(origin: nil, headers: Self.probe)
      #expect(response.status == .forbidden)
      #expect(errorText(bytes) == "origin not allowed")
      #expect(response.headers.first(name: "access-control-allow-origin") == nil)
    }
  }

  @Test(arguments: [
    "https://evil.example", "http://seven.sliccy.ai", "https://sliccy.ai.evil.example",
    "https://evilsliccy.ai", "https://seven.sliccy.ai:8443", "null", "http://localhost:5710",
    "https://sliccy.ai", "https://www.sliccy.ai", "https://a.b.sliccy.ai", "https://-x.sliccy.ai",
    "https://SEVEN.sliccy.ai", "https://seven.sliccy.ai/",
  ])
  func foreignOriginsAreRejected(origin: String) async throws {
    try await withHarness { harness in
      let (response, bytes) = try await harness.post(origin: origin, headers: Self.probe)
      #expect(response.status == .forbidden)
      #expect(errorText(bytes) == "origin not allowed")
      #expect(response.headers.first(name: "access-control-allow-origin") == nil)
    }
  }

  @Test(arguments: [
    "https://seven.sliccy.ai", "https://feat-proxy.sliccy.ai", "https://8.sliccy.ai",
  ])
  func hostedOriginsAreAllowed(origin: String) async throws {
    try await withHarness { harness in
      let (response, _) = try await harness.post(origin: origin, headers: Self.probe)
      #expect(response.status == .ok)
      #expect(response.headers.first(name: "access-control-allow-origin") == origin)
      #expect(
        response.headers.first(name: "access-control-expose-headers")
          == RawFetchProtocol.errorHeader)
      #expect(response.headers.first(name: "vary") == "Origin")
    }
  }

  @Test func devOriginsComeFromConfiguration() async throws {
    let extra = ProxySecurity.parseOrigins(" http://localhost:5710/ ,,bogus,http://x/path")
    #expect(extra == ["http://localhost:5710"])
    try await withHarness(extraOrigins: extra) { harness in
      let (response, _) = try await harness.post(
        origin: "http://localhost:5710", headers: Self.probe)
      #expect(response.status == .ok)
      let (other, _) = try await harness.post(origin: "http://localhost:5711", headers: Self.probe)
      #expect(other.status == .forbidden)
    }
  }

  @Test func foreignHostIsRejected() async throws {
    try await withHarness { harness in
      let port = harness.proxy.split(separator: ":").last.map(String.init) ?? ""
      for host in ["evil.example:\(port)", "127.0.0.1:1", "127.0.0.1"] {
        let (response, bytes) = try await harness.post(headers: Self.probe + [("Host", host)])
        #expect(response.status == .forbidden)
        #expect(errorText(bytes) == "host not allowed")
      }
      let (local, _) = try await harness.post(headers: Self.probe + [("Host", "localhost:\(port)")])
      #expect(local.status == .ok)
    }
  }

  @Test func preflightGrantsPrivateNetworkAccess() async throws {
    try await withHarness { harness in
      let (response, _) = try await harness.post(
        key: nil,
        headers: [
          ("Access-Control-Request-Method", "POST"),
          ("Access-Control-Request-Headers", "x-bridge-token, x-slicc-raw-request"),
          ("Access-Control-Request-Private-Network", "true"),
        ],
        method: .OPTIONS
      )
      #expect(response.status == .noContent)
      let headers = response.headers
      #expect(headers.first(name: "access-control-allow-origin") == hostedOrigin)
      #expect(headers.first(name: "access-control-allow-private-network") == "true")
      #expect(headers.first(name: "access-control-allow-methods") == "POST, OPTIONS")
      #expect(headers.first(name: "access-control-max-age") == "600")
      #expect(
        headers.first(name: "access-control-allow-headers")
          == "Content-Type, X-Bridge-Token, X-Slicc-Raw-Request, X-Slicc-Raw-Probe")
      #expect(headers.first(name: "access-control-allow-credentials") == nil)
    }
  }

  @Test func preflightWithoutPrivateNetworkRequest() async throws {
    try await withHarness { harness in
      let (response, _) = try await harness.post(key: nil, method: .OPTIONS)
      #expect(response.status == .noContent)
      #expect(response.headers.first(name: "access-control-allow-private-network") == nil)
    }
  }

  @Test func preflightNeedsAnAllowedOrigin() async throws {
    try await withHarness { harness in
      let (foreign, _) = try await harness.post(
        origin: "https://evil.example", key: nil,
        headers: [("Access-Control-Request-Private-Network", "true")], method: .OPTIONS)
      #expect(foreign.status == .forbidden)
      #expect(foreign.headers.first(name: "access-control-allow-private-network") == nil)
      let (missing, _) = try await harness.post(origin: nil, key: nil, method: .OPTIONS)
      #expect(missing.status == .forbidden)
    }
  }

  @Test func otherPathsAndMethodsAreRefused() async throws {
    try await withHarness { harness in
      let (other, otherBytes) = try await harness.post(headers: Self.probe, path: "/api/other")
      #expect(other.status == .notFound)
      #expect(errorText(otherBytes) == "not found")
      let (get, _) = try await harness.post(headers: Self.probe, method: .GET)
      #expect(get.status == .methodNotAllowed)
      #expect(get.headers.first(name: "allow") == "POST, OPTIONS")
      #expect(get.headers.first(name: "access-control-allow-origin") == hostedOrigin)
    }
  }

  @Test func mintedKeysAreLongAndFresh() {
    let first = ProxySecurity.mintKey()
    #expect(first.count == 43)
    #expect(first != ProxySecurity.mintKey())
    #expect(first.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
  }

  @Test func launchURLCarriesProxyAndKeyInTheFragment() {
    let url = LocalProxy.launchURL(
      page: "https://seven.sliccy.ai/#old", proxyURL: "http://127.0.0.1:5799", key: "k-_+/=")
    #expect(url == "https://seven.sliccy.ai/#proxy=http%3A%2F%2F127.0.0.1%3A5799&key=k-_%2B%2F%3D")
  }
}
