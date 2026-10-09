import AsyncHTTPClient
import Foundation
import NIOCore
import Testing

@testable import SliccSwift

@Suite struct RawFetchTests {
  @Test func probeAdvertisesTheProtocol() async throws {
    try await withHarness { harness in
      let (response, bytes) = try await harness.post(headers: [(RawFetchProtocol.probeHeader, "1")])
      #expect(response.status == .ok)
      let reply = try #require(
        try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any])
      #expect(reply["rawFetch"] as? Int == 1)
      #expect(reply["requestBodyStreaming"] as? Bool == false)
      #expect(reply["maxRequestBodyBytes"] as? Int == RawFetchProtocol.requestBodyCap)
      #expect(reply["cdp"] == nil)
    }
  }

  @Test func getKeepsStatusHeadersAndEveryCookie() async throws {
    try await withHarness { harness in
      let reply = try await harness.fetch("/hello")
      #expect(reply.status == 200)
      #expect(reply.statusText == "OK")
      #expect(reply.url == harness.upstream + "/hello")
      #expect(reply.text == "hello")
      #expect(reply.values("set-cookie") == ["a=1; Path=/", "b=2; Path=/"])
      #expect(reply.values("x-custom") == ["custom"])
      #expect(reply.values("content-length") == ["5"])
    }
  }

  @Test func redirectsReachTheCaller() async throws {
    try await withHarness { harness in
      let reply = try await harness.fetch("/redirect")
      #expect(reply.status == 302)
      #expect(reply.values("location") == ["/hello"])
    }
  }

  @Test func headAndNoContentHaveNoBody() async throws {
    try await withHarness { harness in
      let head = try await harness.fetch("/hello", method: "HEAD")
      #expect(head.status == 200)
      #expect(head.body.isEmpty)
      #expect(head.values("content-length") == ["5"])
      let empty = try await harness.fetch("/empty")
      #expect(empty.status == 204)
      #expect(empty.body.isEmpty)
    }
  }

  @Test func requestHeadersAreForwardedAndFolded() async throws {
    try await withHarness { harness in
      let reply = try await harness.fetch(
        "/headers",
        headers: [
          ("User-Agent", "curl/8.0"), ("Cookie", "a=1"), ("cookie", "b=2"), ("X-Multi", "one"),
          ("x-multi", "two"), ("Connection", "x-drop"), ("X-Drop", "gone"),
          ("Proxy-Authorization", "Basic c2VjcmV0"),
          ("Host", "evil.example"),
        ]
      )
      let seen = try #require(
        try JSONSerialization.jsonObject(with: Data(reply.body)) as? [String: String])
      #expect(seen["user-agent"] == "curl/8.0")
      #expect(seen["cookie"] == "a=1; b=2")
      #expect(seen["x-multi"] == "one, two")
      #expect(seen["x-drop"] == nil)
      #expect(seen["proxy-authorization"] == nil)
      #expect(!seen.values.contains { $0.contains("evil.example") })
      #expect(seen["accept-encoding"] == "gzip, deflate, br")
      #expect(seen[ProxySecurity.keyHeader.lowercased()] == nil)
      #expect(seen["origin"] == nil)
    }
  }

  @Test func rangedRequestsAskForIdentity() async throws {
    try await withHarness { harness in
      let reply = try await harness.fetch("/headers", headers: [("Range", "bytes=0-1")])
      let seen = try #require(
        try JSONSerialization.jsonObject(with: Data(reply.body)) as? [String: String])
      #expect(seen["accept-encoding"] == "identity")
    }
  }

  @Test func bufferedUploadReachesUpstream() async throws {
    try await withHarness { harness in
      let payload = Array("posted body".utf8)
      let reply = try await harness.fetch(
        "/echo", method: "POST", headers: [("Content-Type", "text/plain")],
        body: .bytes(ByteBuffer(bytes: payload)))
      #expect(reply.status == 201)
      #expect(reply.body == payload)
    }
  }

  @Test func chunkedUploadIsBufferedBeforeUpstream() async throws {
    try await withHarness { harness in
      let chunks = AsyncStream<ByteBuffer> { continuation in
        for index in 0..<4 {
          continuation.yield(ByteBuffer(repeating: UInt8(65 + index), count: 64 * 1024))
        }
        continuation.finish()
      }
      let reply = try await harness.fetch(
        "/echo", method: "PUT", headers: [("Content-Type", "application/octet-stream")],
        body: .stream(chunks, length: .unknown))
      #expect(reply.status == 200)
      #expect(reply.values("x-received-bytes") == [String(4 * 64 * 1024)])
      #expect(reply.values("x-received-chunked") == ["no"])
      #expect(reply.body.count == 4 * 64 * 1024)
      #expect(reply.body.last == 68)
    }
  }

  @Test(arguments: [
    ("/gzip", "compressed hello"), ("/x-gzip", "compressed hello"),
    ("/members", "compressed hello and more"), ("/padded", "compressed hello"),
    ("/deflate", "zlib hello"),
    ("/raw-deflate", "raw hello"), ("/br", "brotli hello"), ("/stacked", "stacked hello"),
  ])
  func everyCodingIsDecoded(path: String, text: String) async throws {
    try await withHarness { harness in
      let reply = try await harness.fetch(path)
      #expect(reply.status == 200)
      #expect(reply.text == text)
      #expect(reply.values("content-encoding").isEmpty)
      #expect(reply.values("content-length").isEmpty)
    }
  }

  @Test func decompressionStreamsInBoundedChunks() async throws {
    try await withHarness { harness in
      let head = rawHead(harness.upstream + "/bomb")
      var request = HTTPClientRequest(url: harness.proxy + RawFetchProtocol.path)
      request.method = .POST
      request.headers.add(name: "Origin", value: hostedOrigin)
      request.headers.add(name: ProxySecurity.keyHeader, value: testKey)
      request.headers.add(name: RawFetchProtocol.requestHeader, value: head)
      let response = try await harness.client.execute(request, timeout: .seconds(60))
      var total = 0
      var largest = 0
      for try await chunk in response.body {
        total += chunk.readableBytes
        largest = max(largest, chunk.readableBytes)
      }
      #expect(total > 64 * 1024 * 1024)
      #expect(largest <= 1024 * 1024)
    }
  }

  @Test func garbageAfterGzipFailsTheBody() async throws {
    try await withHarness { harness in
      await #expect(throws: (any Error).self) {
        _ = try await harness.fetch("/garbage")
      }
    }
  }

  @Test func encodedHeadKeepsItsCoding() async throws {
    try await withHarness { harness in
      let reply = try await harness.fetch("/gzip", method: "HEAD")
      #expect(reply.body.isEmpty)
      #expect(reply.values("content-encoding") == ["gzip"])
      #expect(reply.values("content-length") == ["42"])
    }
  }

  @Test func unknownCodingPassesThrough() async throws {
    try await withHarness { harness in
      let reply = try await harness.fetch("/unknown")
      #expect(reply.body == gzippedText)
      #expect(reply.values("content-encoding") == ["zstd"])
      #expect(reply.values("content-length") == [String(gzippedText.count)])
    }
  }

  @Test func undeclaredGzipPassesThrough() async throws {
    try await withHarness { harness in
      let reply = try await harness.fetch("/sniff")
      #expect(reply.body == gzippedText)
      #expect(reply.values("content-length") == [String(gzippedText.count)])
    }
  }

  @Test func encodedPartialIsRefused() async throws {
    try await withHarness { harness in
      let head = rawHead(harness.upstream + "/partial")
      let (response, bytes) = try await harness.post(headers: [
        (RawFetchProtocol.requestHeader, head)
      ])
      #expect(response.status == .badGateway)
      #expect(response.headers.first(name: RawFetchProtocol.errorHeader) == "1")
      #expect(
        errorText(bytes) == "upstream answered a range request with an encoded partial body")
    }
  }

  @Test func largeBodyStreamsThrough() async throws {
    try await withHarness { harness in
      let reply = try await harness.fetch("/large")
      #expect(reply.status == 200)
      #expect(reply.body.count == 32 * 1024 * 1024)
      #expect(reply.body.last == 255)
    }
  }

  @Test func megabyteHeadsAreAccepted() async throws {
    try await withHarness { harness in
      let cookie = "big=" + String(repeating: "c", count: 900 * 1024)
      let reply = try await harness.fetch("/headers", headers: [("Cookie", cookie)])
      #expect(reply.status == 200)
      let seen = try #require(
        try JSONSerialization.jsonObject(with: Data(reply.body)) as? [String: String])
      #expect(seen["cookie"]?.count == cookie.count)
    }
  }

  @Test func invalidHeaderNameFailsTheFetch() async throws {
    try await withHarness { harness in
      let head = #"{"url":"http:\/\/127.0.0.1:1\/","method":"GET","headers":[["bad name","v"]]}"#
      let (response, bytes) = try await harness.post(headers: [
        (RawFetchProtocol.requestHeader, head)
      ])
      #expect(response.status == .badGateway)
      #expect(errorText(bytes)?.hasPrefix("fetch failed: ") == true)
    }
  }

  @Test(arguments: [
    "not json",
    #"{"url":"http:\/\/x\/","method":"G T","headers":[]}"#,
    #"{"url":"http:\/\/x\/","method":"GET","headers":[["a",1]]}"#,
    #"{"url":"ftp:\/\/x\/","method":"GET","headers":[]}"#,
  ])
  func malformedHeadsAreRejected(head: String) async throws {
    try await withHarness { harness in
      let (response, bytes) = try await harness.post(headers: [
        (RawFetchProtocol.requestHeader, head)
      ])
      #expect(response.status == .badRequest)
      #expect(response.headers.first(name: RawFetchProtocol.errorHeader) == "1")
      let reply = try #require(
        try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: String])
      #expect(reply["error"] != nil)
    }
  }

  @Test func plainPostWithoutRawHeadersIsRejected() async throws {
    try await withHarness { harness in
      let (response, _) = try await harness.post()
      #expect(response.status == .badRequest)
      #expect(response.headers.first(name: RawFetchProtocol.errorHeader) == "1")
    }
  }

  @Test func unreachableUpstreamIsBadGateway() async throws {
    try await withHarness { harness in
      let head = rawHead("http://127.0.0.1:1/")
      let (response, bytes) = try await harness.post(headers: [
        (RawFetchProtocol.requestHeader, head)
      ])
      #expect(errorText(bytes)?.hasPrefix("fetch failed: ") == true)
      #expect(response.status == .badGateway)
      #expect(response.headers.first(name: RawFetchProtocol.errorHeader) == "1")
    }
  }
}
