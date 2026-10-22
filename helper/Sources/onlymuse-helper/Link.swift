import Foundation

// A message from the app, as Outgoing in src/helper.ts names it.
struct Command: Decodable {
  let type: String
  let requestId: Int?
  let positionSeconds: Double?
  let volumePercent: Int?
  let song: SongMatch?
  let afterPersistentID: String?
  // trackInfo and setFavorite name a song by its persistent ID, or by a match when the app has none.
  let persistentID: String?
  let favorited: Bool?
  // setNext: a YouTube song plays later in the queue.
  let keepsYouTube: Bool?
}

// What the app knows of a catalog song, to find it in Music.app's library.
struct SongMatch: Decodable {
  let name: String
  let artistName: String
  let albumName: String
  let durationSeconds: Double
  // Set for a song that plays from YouTube, which the helper plays in its YouTube page.
  let youtubeId: String?

  var youTubeVideoID: String? {
    guard let youtubeId, !youtubeId.isEmpty else { return nil }

    return youtubeId
  }
}

// Writes one JSON line to the app, as Incoming in src/helper.ts names it.
func send(_ message: [String: Any]) {
  guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }

  FileHandle.standardOutput.write(data + Data("\n".utf8))
}

func sendError(_ text: String) {
  send(["type": "error", "text": text])
}

// Reads the app's lines on a thread of their own. The pipe closes however the app ends, even on kill -9, so onAppGone runs.
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

    // The app closed its end of the pipe, so it has quit.
    DispatchQueue.main.sync { MainActor.assumeIsolated { onAppGone() } }
    exit(0)
  }
}
