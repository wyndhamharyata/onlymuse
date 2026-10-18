import Foundation

// A message from the app, as Outgoing in src/helper.ts names it.
struct Command: Decodable {
  let type: String
  let requestId: Int?
  let positionSeconds: Double?
  let volumePercent: Int?
  let song: SongMatch?
}

// What the app knows of a catalog song, to find it in Music.app's library.
struct SongMatch: Decodable {
  let name: String
  let artistName: String
  let albumName: String
  let durationSeconds: Double
}

// Writes one JSON line to the app, as Incoming in src/helper.ts names it.
func send(_ message: [String: Any]) {
  guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }

  FileHandle.standardOutput.write(data + Data("\n".utf8))
}

func sendError(_ text: String) {
  send(["type": "error", "text": text])
}

// Reads the app's lines on a thread of their own and hands each command to the main actor.
func startReadingCommands(onCommand: @escaping @MainActor @Sendable (Command) -> Void) {
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
    exit(0)
  }
}
