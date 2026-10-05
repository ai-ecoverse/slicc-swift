import AsyncHTTPClient
import Compression
import Foundation
import NIOCore
import zlib

enum ContentDecodingError: Error {
  case zlib(Int32)
  case brotli
  case truncated
  case trailingData
}

class ContentDecoder {
  static let chunkSize = 64 * 1024

  private var input: [UInt8] = []
  private var offset = 0

  var available: Int { input.count - offset }

  func feed(_ bytes: [UInt8]) {
    input = offset == input.count ? bytes : Array(input[offset...]) + bytes
    offset = 0
  }

  func peek(_ index: Int) -> UInt8 { input[offset + index] }

  func consume(_ count: Int) {
    offset += count
    if offset == input.count {
      input = []
      offset = 0
    }
  }

  func withInput<T>(_ body: (UnsafeMutablePointer<UInt8>, Int) throws -> T) rethrows -> T {
    var placeholder: UInt8 = 0
    if available == 0 { return try body(&placeholder, 0) }
    let start = offset
    return try input.withUnsafeMutableBufferPointer {
      try body($0.baseAddress! + start, $0.count - start)
    }
  }

  func read(finish: Bool) throws -> [UInt8] { [] }
}

final class ZlibDecoder: ContentDecoder {
  private let gzip: Bool
  private var stream = z_stream()
  private var started = false
  private var ended = false

  init(gzip: Bool) {
    self.gzip = gzip
  }

  deinit {
    if started { inflateEnd(&stream) }
  }

  private func windowBits() -> Int32 {
    if gzip { return 31 }
    guard available >= 2 else { return -15 }
    let header = Int(peek(0)) << 8 | Int(peek(1))
    return peek(0) & 0x0f == 8 && header % 31 == 0 ? 15 : -15
  }

  override func read(finish: Bool) throws -> [UInt8] {
    if !started {
      if available == 0 || (available < 2 && !finish) { return [] }
      let rc = inflateInit2_(
        &stream, windowBits(), zlibVersion(), Int32(MemoryLayout<z_stream>.size))
      guard rc == Z_OK else { throw ContentDecodingError.zlib(rc) }
      started = true
    }
    var output = [UInt8](repeating: 0, count: Self.chunkSize)
    var produced = 0
    while produced < output.count {
      if ended {
        while available > 0 && peek(0) == 0 { consume(1) }
        if available == 0 { break }
        guard gzip, peek(0) == 0x1f else { throw ContentDecodingError.trailingData }
        inflateReset(&stream)
        ended = false
      }
      if available == 0 && !finish { break }
      let before = available
      let room = output.count - produced
      let rc = withInput { source, count in
        output.withUnsafeMutableBufferPointer { dest in
          stream.next_in = source
          stream.avail_in = uInt(count)
          stream.next_out = dest.baseAddress! + produced
          stream.avail_out = uInt(room)
          return inflate(&stream, Z_NO_FLUSH)
        }
      }
      let consumed = before - Int(stream.avail_in)
      let made = room - Int(stream.avail_out)
      consume(consumed)
      produced += made
      if rc == Z_STREAM_END {
        ended = true
        continue
      }
      if rc == Z_BUF_ERROR || (rc == Z_OK && made == 0 && consumed == 0) {
        if finish && available == 0 { throw ContentDecodingError.truncated }
        break
      }
      guard rc == Z_OK else { throw ContentDecodingError.zlib(rc) }
    }
    return Array(output[0..<produced])
  }
}

final class BrotliDecoder: ContentDecoder {
  private let state = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
  private var ended = false

  override init() {
    super.init()
  }

  func start() throws {
    guard
      compression_stream_init(state, COMPRESSION_STREAM_DECODE, COMPRESSION_BROTLI)
        == COMPRESSION_STATUS_OK
    else {
      ended = true
      throw ContentDecodingError.brotli
    }
  }

  deinit {
    compression_stream_destroy(state)
    state.deallocate()
  }

  override func read(finish: Bool) throws -> [UInt8] {
    if ended { return [] }
    var output = [UInt8](repeating: 0, count: Self.chunkSize)
    var produced = 0
    let flags = finish ? Int32(bitPattern: COMPRESSION_STREAM_FINALIZE.rawValue) : 0
    while produced < output.count {
      if available == 0 && !finish { break }
      let before = available
      let room = output.count - produced
      let status = withInput { source, count in
        output.withUnsafeMutableBufferPointer { dest in
          state.pointee.src_ptr = UnsafePointer(source)
          state.pointee.src_size = count
          state.pointee.dst_ptr = dest.baseAddress! + produced
          state.pointee.dst_size = room
          return compression_stream_process(state, flags)
        }
      }
      let consumed = before - state.pointee.src_size
      let made = room - state.pointee.dst_size
      consume(consumed)
      produced += made
      if status == COMPRESSION_STATUS_END {
        ended = true
        break
      }
      guard status == COMPRESSION_STATUS_OK else { throw ContentDecodingError.brotli }
      if made == 0 && consumed == 0 {
        if finish { throw ContentDecodingError.truncated }
        break
      }
    }
    return Array(output[0..<produced])
  }
}

enum ContentDecoding {
  static func decoders(for codings: [String]) throws -> [ContentDecoder] {
    try codings.reversed().map { coding -> ContentDecoder in
      switch coding {
      case "gzip", "x-gzip": return ZlibDecoder(gzip: true)
      case "deflate": return ZlibDecoder(gzip: false)
      default:
        let decoder = BrotliDecoder()
        try decoder.start()
        return decoder
      }
    }
  }
}

struct DecodedBody: AsyncSequence, Sendable {
  typealias Element = ByteBuffer
  let upstream: HTTPClientResponse.Body
  let codings: [String]

  struct AsyncIterator: AsyncIteratorProtocol {
    var inner: HTTPClientResponse.Body.AsyncIterator
    let codings: [String]
    var decoders: [ContentDecoder] = []
    var inputDone: [Bool] = []

    mutating func next() async throws -> ByteBuffer? {
      if codings.isEmpty { return try await inner.next() }
      if decoders.isEmpty {
        decoders = try ContentDecoding.decoders(for: codings)
        inputDone = Array(repeating: false, count: decoders.count)
      }
      return try await pull(decoders.count - 1).map { ByteBuffer(bytes: $0) }
    }

    private mutating func pull(_ stage: Int) async throws -> [UInt8]? {
      let decoder = decoders[stage]
      while true {
        let output = try decoder.read(finish: inputDone[stage])
        if !output.isEmpty { return output }
        if inputDone[stage] { return nil }
        let input: [UInt8]?
        if stage == 0 {
          input = try await inner.next().map { Array($0.readableBytesView) }
        } else {
          input = try await pull(stage - 1)
        }
        if let input { decoder.feed(input) } else { inputDone[stage] = true }
      }
    }
  }

  func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(inner: upstream.makeAsyncIterator(), codings: codings)
  }
}
