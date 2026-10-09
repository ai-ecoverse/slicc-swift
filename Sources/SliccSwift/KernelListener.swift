import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import ServiceLifecycle

struct KernelListener: Service {
  static let host = "127.0.0.1"

  let port: Int?
  let tunnels: KernelTunnels
  let state: KernelState
  let log: @Sendable (String) -> Void
  let warn: @Sendable (String) -> Void

  func run() async throws {
    guard let port else {
      state.settle(nil)
      try? await gracefulShutdown()
      return
    }
    let server: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>
    do {
      server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
        .childChannelOption(.allowRemoteHalfClosure, value: true)
        .bind(host: Self.host, port: port) { channel in
          channel.eventLoop.makeCompletedFuture {
            try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
              wrappingChannelSynchronously: channel,
              configuration: .init(isOutboundHalfClosureEnabled: true))
          }
        }
    } catch {
      warn(
        "kernel services are off: cannot listen on \(Self.host):\(port) (\(Self.code(error))); try --kernel-port"
      )
      state.settle(nil)
      try? await gracefulShutdown()
      return
    }
    let bound = server.channel.localAddress?.port ?? port
    state.settle(bound)
    let open = NIOLockedValueBox<[ObjectIdentifier: any Channel]>([:])
    let tunnels = tunnels
    await withGracefulShutdownHandler {
      try? await server.executeThenClose { inbound in
        await withDiscardingTaskGroup { group in
          do {
            for try await connection in inbound {
              let key = ObjectIdentifier(connection.channel)
              open.withLockedValue { $0[key] = connection.channel }
              group.addTask {
                await KernelConnection(port: bound, tunnels: tunnels, log: log).run(connection)
                _ = open.withLockedValue { $0.removeValue(forKey: key) }
              }
            }
          } catch {}
        }
      }
    } onGracefulShutdown: {
      server.channel.close(promise: nil)
      for channel in open.withLockedValue({ Array($0.values) }) { channel.close(promise: nil) }
      Task { await tunnels.shutdown() }
    }
  }

  static func code(_ error: any Error) -> String {
    guard let io = error as? IOError else { return "EIO" }
    switch io.errnoCode {
    case EADDRINUSE: return "EADDRINUSE"
    case EACCES: return "EACCES"
    case EADDRNOTAVAIL: return "EADDRNOTAVAIL"
    case EPERM: return "EPERM"
    default: return "E\(io.errnoCode)"
    }
  }
}

struct KernelConnection {
  let port: Int
  let tunnels: KernelTunnels
  let log: @Sendable (String) -> Void

  private static let separator: [UInt8] = Array("\r\n\r\n".utf8)

  func run(_ connection: NIOAsyncChannel<ByteBuffer, ByteBuffer>) async {
    let channel = connection.channel
    try? await connection.executeThenClose { inbound, outbound in
      var iterator = inbound.makeAsyncIterator()
      let timer = Task {
        guard (try? await Task.sleep(for: KernelProtocol.headTimeout)) != nil else { return }
        channel.close(promise: nil)
      }
      var buffered: [UInt8] = []
      var end: Int?
      while end == nil && buffered.count <= KernelProtocol.headLimit {
        guard let chunk = try await iterator.next() else {
          timer.cancel()
          return
        }
        let from = max(0, buffered.count - 3)
        buffered.append(contentsOf: chunk.readableBytesView)
        end = Self.find(buffered, from: from)
      }
      timer.cancel()
      guard let end, end <= KernelProtocol.headLimit else {
        return try await refuse(431, "request head too large", &iterator, outbound, channel)
      }
      guard let head = KernelProtocol.parseHead(Array(buffered[..<end])) else {
        return try await refuse(400, "malformed request head", &iterator, outbound, channel)
      }
      guard let kernelPort = KernelProtocol.kernelPort(head.host, listenPort: port) else {
        return try await refuse(
          421, "only <port>.kernel.localhost is served here", &iterator, outbound, channel)
      }
      let dial = await tunnels.dial(port: kernelPort) { channel.close(promise: nil) }
      switch dial {
      case .noPage:
        log("kernel \(head.method) \(kernelPort) ← 502 no page")
        try await refuse(502, "no seven page connected", &iterator, outbound, channel)
      case .failed(let code):
        let (status, message) = KernelProtocol.failure(code, port: kernelPort)
        log("kernel \(head.method) \(kernelPort) ← \(status)")
        try await refuse(status, message, &iterator, outbound, channel)
      case .opened(let id, let events):
        log("kernel \(head.method) \(kernelPort)")
        await pipe(id, ByteBuffer(bytes: buffered), events, &iterator, outbound)
      }
    }
  }

  private func pipe(
    _ id: UInt32, _ first: ByteBuffer, _ events: AsyncStream<KernelEvent>,
    _ iterator: inout NIOAsyncChannelInboundStream<ByteBuffer>.AsyncIterator,
    _ outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>
  ) async {
    let tunnels = tunnels
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        for await event in events {
          switch event {
          case .data(let buffer):
            do {
              try await outbound.write(buffer)
            } catch {
              await tunnels.close(id)
              return
            }
            await tunnels.credit(id, buffer.readableBytes)
          case .end:
            outbound.finish()
            return
          }
        }
      }
      do {
        try await tunnels.send(id, first)
        while let chunk = try await iterator.next() { try await tunnels.send(id, chunk) }
        await tunnels.end(id)
      } catch {
        await tunnels.close(id)
        outbound.finish()
        group.cancelAll()
      }
    }
    await tunnels.close(id)
  }

  private func refuse(
    _ status: Int, _ message: String,
    _ iterator: inout NIOAsyncChannelInboundStream<ByteBuffer>.AsyncIterator,
    _ outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>, _ channel: any Channel
  ) async throws {
    try await outbound.write(KernelProtocol.answer(status: status, message: message))
    outbound.finish()
    let timer = Task {
      guard (try? await Task.sleep(for: KernelProtocol.headTimeout)) != nil else { return }
      channel.close(promise: nil)
    }
    while try await iterator.next() != nil {}
    timer.cancel()
  }

  private static func find(_ bytes: [UInt8], from: Int) -> Int? {
    guard bytes.count >= 4 else { return nil }
    var index = from
    while index + 4 <= bytes.count {
      if bytes[index] == 13 && bytes[index + 1] == 10 && bytes[index + 2] == 13
        && bytes[index + 3] == 10
      {
        return index
      }
      index += 1
    }
    return nil
  }
}
