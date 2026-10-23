import Foundation
import Network

// On networks that cap IPv6 packets at 1280 bytes, WebKit's HTTP/3 waits 2 minutes per request.
final class LocalProxy: @unchecked Sendable {
  private static let maxHeadBytes = 16 * 1024
  private static let chunkBytes = 64 * 1024

  private let queue = DispatchQueue(label: "onlymuse.local-proxy")
  private var listener: NWListener?

  var port: NWEndpoint.Port? { listener?.port }

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

  private func readHead(_ client: NWConnection, head: Data) {
    client.receive(minimumIncompleteLength: 1, maximumLength: Self.maxHeadBytes) { [weak self] data, _, isComplete, error in
      guard let self else { return }

      var head = head

      if let data { head.append(data) }

      guard let end = head.range(of: Data("\r\n\r\n".utf8)) else {
        let hasHeadFailed = isComplete || error != nil || head.count > Self.maxHeadBytes

        if hasHeadFailed { return client.cancel() }
        return self.readHead(client, head: head)
      }

      let firstLine = String(decoding: head[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
      let words = firstLine.split(separator: " ")
      let rest = head[end.upperBound...]

      guard words.count >= 2, words[0] == "CONNECT", let target = Self.toHostPort(String(words[1])) else {
        return self.reply(client, "HTTP/1.1 501 Not Implemented\r\n\r\n", then: { client.cancel() })
      }

      self.open(client, host: target.host, port: target.port, bytesAfterHead: Data(rest))
    }
  }

  private func open(_ client: NWConnection, host: String, port: NWEndpoint.Port, bytesAfterHead: Data) {
    let server = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
    let answer = Answer()

    server.stateUpdateHandler = { [weak self] state in
      guard let self else { return }

      switch state {
      case .ready where !answer.isSent:
        answer.isSent = true
        self.reply(client, "HTTP/1.1 200 Connection Established\r\n\r\n") {
          if !bytesAfterHead.isEmpty { server.send(content: bytesAfterHead, completion: .idempotent) }
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

  private func pipe(from source: NWConnection, to destination: NWConnection) {
    source.receive(minimumIncompleteLength: 1, maximumLength: Self.chunkBytes) { [weak self] data, _, isComplete, error in
      let hasEnded = isComplete || error != nil

      guard let data, !data.isEmpty else {
        self?.pipeUnlessEnded(from: source, to: destination, hasEnded: hasEnded)
        return
      }

      destination.send(content: data, completion: .contentProcessed { [weak self] writeError in
        self?.pipeUnlessEnded(from: source, to: destination, hasEnded: hasEnded || writeError != nil)
      })
    }
  }

  private func pipeUnlessEnded(from source: NWConnection, to destination: NWConnection, hasEnded: Bool) {
    guard !hasEnded else {
      source.cancel()
      return destination.cancel()
    }

    pipe(from: source, to: destination)
  }

  private func reply(_ client: NWConnection, _ text: String, then: @escaping @Sendable () -> Void) {
    client.send(content: Data(text.utf8), completion: .contentProcessed { _ in then() })
  }

  private static func toHostPort(_ text: String) -> (host: String, port: NWEndpoint.Port)? {
    guard let colon = text.lastIndex(of: ":"), let number = UInt16(text[text.index(after: colon)...]), let port = NWEndpoint.Port(rawValue: number) else { return nil }

    var host = String(text[..<colon])
    if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }

    return host.isEmpty ? nil : (host, port)
  }
}

private final class Answer: @unchecked Sendable {
  var isSent = false
}
