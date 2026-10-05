import AsyncHTTPClient
import Compression
import Foundation
import NIOCore
import zlib

enum ContentDecodingError: Error {
  case zlib(Int32)
  case brotli
  case truncated
}

protocol ContentDecoder: AnyObject {
  func push(_ input: [UInt8], finish: Bool) throws -> [UInt8]
}

final class ZlibDecoder: ContentDecoder {
  private let gzip: Bool
  private var stream = z_stream()
  private var started = false
  private var ended = false
  private var pending: [UInt8] = []

  init(gzip: Bool) {
    self.gzip = gzip
  }

  deinit {
    if started { inflateEnd(&stream) }
  }

  func push(_ input: [UInt8], finish: Bool) throws -> [UInt8] {
    if !started {
      pending += input
      if pending.count < 2 && !finish { return [] }
      if pending.isEmpty { return [] }
      try start(windowBits: windowBits(for: pending))
      let buffered = pending
      pending = []
      return try inflate(buffered, finish: finish)
    }
    return try inflate(input, finish: finish)
  }

  private func windowBits(for prefix: [UInt8]) -> Int32 {
    if gzip { return 31 }
    guard prefix.count >= 2 else { return -15 }
    let header = Int(prefix[0]) << 8 | Int(prefix[1])
    return prefix[0] & 0x0f == 8 && header % 31 == 0 ? 15 : -15
  }

  private func start(windowBits: Int32) throws {
    let rc = inflateInit2_(&stream, windowBits, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
    guard rc == Z_OK else { throw ContentDecodingError.zlib(rc) }
    started = true
  }

  private func inflate(_ input: [UInt8], finish: Bool) throws -> [UInt8] {
    var source = input
    var output: [UInt8] = []
    let chunk = 64 * 1024
    var outbuf = [UInt8](repeating: 0, count: chunk)
    try source.withUnsafeMutableBufferPointer { inBuf in
      stream.next_in = inBuf.baseAddress
      stream.avail_in = uInt(inBuf.count)
      while true {
        if ended {
          guard gzip, stream.avail_in > 0, stream.next_in.pointee == 0x1f else {
            stream.avail_in = 0
            return
          }
          inflateReset(&stream)
          ended = false
        }
        if stream.avail_in == 0 && !finish { return }
        let rc = outbuf.withUnsafeMutableBufferPointer { dest -> Int32 in
          stream.next_out = dest.baseAddress
          stream.avail_out = uInt(dest.count)
          return zlib.inflate(&stream, Z_NO_FLUSH)
        }
        let produced = chunk - Int(stream.avail_out)
        if produced > 0 { output.append(contentsOf: outbuf[0..<produced]) }
        if rc == Z_STREAM_END {
          ended = true
          continue
        }
        if rc == Z_BUF_ERROR || (rc == Z_OK && produced == 0 && stream.avail_in == 0) {
          if finish { throw ContentDecodingError.truncated }
          return
        }
        guard rc == Z_OK else { throw ContentDecodingError.zlib(rc) }
      }
    }
    return output
  }
}

final class BrotliDecoder: ContentDecoder {
  private let state = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
  private var ended = false

  init() throws {
    guard
      compression_stream_init(state, COMPRESSION_STREAM_DECODE, COMPRESSION_BROTLI)
        == COMPRESSION_STATUS_OK
    else {
      state.deallocate()
      throw ContentDecodingError.brotli
    }
  }

  deinit {
    compression_stream_destroy(state)
    state.deallocate()
  }

  func push(_ input: [UInt8], finish: Bool) throws -> [UInt8] {
    if ended { return [] }
    var output: [UInt8] = []
    let chunk = 64 * 1024
    var outbuf = [UInt8](repeating: 0, count: chunk)
    let flags = finish ? Int32(bitPattern: COMPRESSION_STREAM_FINALIZE.rawValue) : 0
    try input.withUnsafeBufferPointer { inBuf in
      let empty: [UInt8] = [0]
      try empty.withUnsafeBufferPointer { placeholder in
        state.pointee.src_ptr = inBuf.baseAddress ?? placeholder.baseAddress!
        state.pointee.src_size = inBuf.count
        while true {
          let status = outbuf.withUnsafeMutableBufferPointer { dest -> compression_status in
            state.pointee.dst_ptr = dest.baseAddress!
            state.pointee.dst_size = dest.count
            return compression_stream_process(state, flags)
          }
          let produced = chunk - state.pointee.dst_size
          if produced > 0 { output.append(contentsOf: outbuf[0..<produced]) }
          switch status {
          case COMPRESSION_STATUS_END:
            ended = true
            return
          case COMPRESSION_STATUS_OK:
            if produced == 0 && state.pointee.src_size == 0 {
              if finish { throw ContentDecodingError.truncated }
              return
            }
          default:
            throw ContentDecodingError.brotli
          }
        }
      }
    }
    return output
  }
}

enum ContentDecoding {
  static func decoders(for codings: [String]) throws -> [any ContentDecoder] {
    try codings.reversed().map { coding -> any ContentDecoder in
      switch coding {
      case "gzip", "x-gzip": return ZlibDecoder(gzip: true)
      case "deflate": return ZlibDecoder(gzip: false)
      default: return try BrotliDecoder()
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
    var decoders: [any ContentDecoder]?
    var finished = false

    mutating func next() async throws -> ByteBuffer? {
      if codings.isEmpty { return try await inner.next() }
      if decoders == nil { decoders = try ContentDecoding.decoders(for: codings) }
      while !finished {
        guard let chunk = try await inner.next() else {
          finished = true
          var bytes: [UInt8] = []
          for decoder in decoders ?? [] { bytes = try decoder.push(bytes, finish: true) }
          return bytes.isEmpty ? nil : ByteBuffer(bytes: bytes)
        }
        var bytes = Array(chunk.readableBytesView)
        for decoder in decoders ?? [] { bytes = try decoder.push(bytes, finish: false) }
        if !bytes.isEmpty { return ByteBuffer(bytes: bytes) }
      }
      return nil
    }
  }

  func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(inner: upstream.makeAsyncIterator(), codings: codings)
  }
}
