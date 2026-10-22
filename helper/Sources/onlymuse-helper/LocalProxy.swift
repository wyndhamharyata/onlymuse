import Foundation
import Network

// A proxy that only this Mac can reach, for the helper's pages. Each connection of a page goes through it as a
// TCP tunnel, so none uses HTTP/3. Some networks, such as a phone's hotspot, allow IPv6 packets only up to 1280
// bytes. HTTP/3's packets are larger. WebKit then waits two minutes on each request before it gives up. The
// tunnels carry the pages' TLS as it is, so the proxy reads none of it.
final class LocalProxy: @unchecked Sendable {
  // The most a CONNECT request's head may be.
  private static let maxHeadBytes = 16 * 1024
  private static let chunkBytes = 64 * 1024

  private let queue = DispatchQueue(label: "onlymuse.local-proxy")
  private var listener: NWListener?

  var port: NWEndpoint.Port? { listener?.port }

  // start listens on a free port of 127.0.0.1. It gives the port to onReady once it listens.
  func start(onReady: @escaping @Sendable (NWEndpoint.Port) -> Void) {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)

    guard let listener = try? NWListener(using: parameters) else { return sendError("The helper's proxy could not start.") }

    listener.stateUpdateHandler = { [weak listener] state in
      switch state {
      case .ready: if let port = listener?.port { onReady(port) }
      case .failed(let error): sendError("The helper's proxy stopped: \(error.localizedDescription)")
      default: break
      }
    }
    listener.newConnectionHandler = { [weak self] client in self?.accept(client) }
    listener.start(queue: queue)
    self.listener = listener
  }

  private func accept(_ client: NWConnection) {
    client.start(queue: queue)
    readHead(client, head: Data())
  }

  // This reads the request's head: "CONNECT host:port HTTP/1.1", its headers, then an empty line.
  private func readHead(_ client: NWConnection, head: Data) {
    client.receive(minimumIncompleteLength: 1, maximumLength: Self.maxHeadBytes) { [weak self] data, _, isComplete, error in
      guard let self else { return }

      var head = head
      if let data { head.append(data) }

      guard let end = head.range(of: Data("\r\n\r\n".utf8)) else {
        if isComplete || error != nil || head.count > Self.maxHeadBytes { return client.cancel() }
        return self.readHead(client, head: head)
      }

      let firstLine = String(decoding: head[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
      let words = firstLine.split(separator: " ")
      let rest = head[end.upperBound...]

      guard words.count >= 2, words[0] == "CONNECT", let target = Self.toHostPort(String(words[1])) else {
        return self.reply(client, "HTTP/1.1 501 Not Implemented\r\n\r\n", then: { client.cancel() })
      }

      self.open(client, host: target.host, port: target.port, early: Data(rest))
    }
  }

  private func open(_ client: NWConnection, host: String, port: NWEndpoint.Port, early: Data) {
    let server = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
    let answer = Answer()

    server.stateUpdateHandler = { [weak self] state in
      guard let self else { return }

      switch state {
      case .ready where !answer.isSent:
        answer.isSent = true
        self.reply(client, "HTTP/1.1 200 Connection Established\r\n\r\n") {
          if !early.isEmpty { server.send(content: early, completion: .idempotent) }
          self.pipe(from: client, to: server)
          self.pipe(from: server, to: client)
        }
      case .failed, .waiting:
        guard !answer.isSent else { return client.cancel() }
        answer.isSent = true
        server.cancel()
        self.reply(client, "HTTP/1.1 502 Bad Gateway\r\n\r\n", then: { client.cancel() })
      case .cancelled:
        client.cancel()
      default:
        break
      }
    }
    server.start(queue: queue)
  }

  // This copies one side's bytes to the other until either side ends.
  private func pipe(from source: NWConnection, to destination: NWConnection) {
    source.receive(minimumIncompleteLength: 1, maximumLength: Self.chunkBytes) { [weak self] data, _, isComplete, error in
      if let data, !data.isEmpty {
        destination.send(content: data, completion: .contentProcessed { sendError in
          guard sendError == nil else {
            source.cancel()
            return destination.cancel()
          }
          if isComplete || error != nil {
            source.cancel()
            return destination.cancel()
          }
          self?.pipe(from: source, to: destination)
        })
        return
      }

      guard isComplete || error != nil else { return self?.pipe(from: source, to: destination) ?? () }

      source.cancel()
      destination.cancel()
    }
  }

  private func reply(_ client: NWConnection, _ text: String, then: @escaping @Sendable () -> Void) {
    client.send(content: Data(text.utf8), completion: .contentProcessed { _ in then() })
  }

  // "host:port", with an IPv6 host in brackets.
  private static func toHostPort(_ text: String) -> (host: String, port: NWEndpoint.Port)? {
    guard let colon = text.lastIndex(of: ":"), let number = UInt16(text[text.index(after: colon)...]), let port = NWEndpoint.Port(rawValue: number) else { return nil }

    var host = String(text[..<colon])
    if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }

    return host.isEmpty ? nil : (host, port)
  }
}

// Whether the proxy answered a CONNECT. Only the proxy's queue reads and sets it.
private final class Answer: @unchecked Sendable {
  var isSent = false
}
