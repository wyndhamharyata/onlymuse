import Foundation

// A message from the app, as send in src/helper/requests.odin writes it.
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
  // In setNext, keepsYouTube says that a YouTube song plays later in the queue.
  let keepsYouTube: Bool?
}

// What the app knows of a catalog song, to find it in Music.app's library.
struct SongMatch: Decodable {
  let name: String
  let artistName: String
  let albumName: String
  let durationSeconds: Double
  // Only a song that plays from YouTube has a youtubeId. The helper plays it in its YouTube page.
  let youtubeId: String?

  var youTubeVideoID: String? {
    guard let youtubeId, !youtubeId.isEmpty else { return nil }

    return youtubeId
  }
}

// send writes one JSON line to the app, as Message in src/helper/helper.odin names it. A write after the app
// ended fails here. The reader thread's onAppGone still pauses Music.app.
func send(_ message: [String: Any]) {
  guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }

  try? FileHandle.standardOutput.write(contentsOf: data + Data("\n".utf8))
}

func sendError(_ text: String) {
  send(["type": "error", "text": text])
}

// This reads the app's lines on a thread of their own. The pipe closes however the app ends, even on kill -9, so onAppGone runs.
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

    // The app closed its end of the pipe, so it quit.
    DispatchQueue.main.sync { MainActor.assumeIsolated { onAppGone() } }
    exit(0)
  }
}
