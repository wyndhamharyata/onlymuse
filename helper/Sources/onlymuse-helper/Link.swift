import Foundation

struct Command: Decodable {
  let type: String
  let requestId: Int?
  let positionSeconds: Double?
  let volumePercent: VolumePercent?
  let song: SongMatch?
  let afterPersistentID: String?
  let persistentID: String?
  let favorited: Bool?
  let keepsYouTube: Bool?
}

struct VolumePercent: Decodable {
  let value: Int

  init(from decoder: Decoder) throws {
    value = min(max(try decoder.singleValueContainer().decode(Int.self), 0), 100)
  }
}

struct SongMatch: Decodable {
  let name: String
  let artistName: String
  let albumName: String
  let durationSeconds: Double
  let youtubeId: String?

  var youTubeVideoID: String? {
    guard let youtubeId, !youtubeId.isEmpty else { return nil }

    return youtubeId
  }
}

var nowMs: Double { Date().timeIntervalSince1970 * 1000 }

func makePositionMessage(persistentID: String, positionSeconds: Double) -> [String: Any] {
  ["type": "position", "persistentID": persistentID, "positionSeconds": positionSeconds, "positionReadAtMs": nowMs]
}

func send(_ message: [String: Any]) {
  guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }

  try? FileHandle.standardOutput.write(contentsOf: data + Data("\n".utf8))
}

func sendError(_ text: String) {
  send(["type": "error", "text": text])
}

// The pipe closes however the app ends, even on kill -9, so onAppGone always runs.
func startReadingCommands(
  onCommand: @escaping @MainActor @Sendable (Command) -> Void,
  onAppGone: @escaping @MainActor @Sendable () -> Void
) {
  Thread.detachNewThread {
    let decoder = JSONDecoder()

    while let line = readLine() {
      guard let command = try? decoder.decode(Command.self, from: Data(line.utf8)) else {
        sendError("The helper could not read the command \(line)")
        continue
      }

      DispatchQueue.main.async { MainActor.assumeIsolated { onCommand(command) } }
    }

    DispatchQueue.main.sync { MainActor.assumeIsolated { onAppGone() } }
    exit(0)
  }
}
