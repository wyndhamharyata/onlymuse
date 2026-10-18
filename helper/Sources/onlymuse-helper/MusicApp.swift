import AppKit

// Music.app through AppleScript. Every script checks first that Music.app runs, so reading the state never opens it.
@MainActor
final class MusicApp {
  nonisolated static let bundleIdentifier = "com.apple.Music"

  private let artworkFolder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appending(path: "onlymuse/artwork")

  // The fields are joined by the unit separator, so a song name can hold any other character.
  private let nowPlayingScript = NSAppleScript(source: """
    tell application "Music"
      set separator to character id 31
      set volumeText to (sound volume as text)
      set stateText to (player state as text)
      if stateText is "stopped" then return stateText & separator & volumeText
      set t to current track
      return stateText & separator & volumeText & separator & (player position as text) & separator & (name of t) & separator & (artist of t) & separator & (album of t) & separator & (persistent ID of t) & separator & (duration of t as text)
    end tell
    """)!

  private let artworkScript = NSAppleScript(source: """
    tell application "Music"
      if (count of artworks of current track) is 0 then return missing value
      return raw data of artwork 1 of current track
    end tell
    """)!

  private let commandScripts = [
    "playPause": NSAppleScript(source: "tell application \"Music\" to playpause")!,
    "next": NSAppleScript(source: "tell application \"Music\" to next track")!,
    "previous": NSAppleScript(source: "tell application \"Music\" to previous track")!,
  ]

  init() {
    try? FileManager.default.createDirectory(at: artworkFolder, withIntermediateDirectories: true)
  }

  var isRunning: Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty
  }

  func readNowPlaying() -> [String: Any] {
    guard isRunning else { return ["type": "nowPlaying", "state": "closed"] }
    guard let text = run(nowPlayingScript)?.stringValue else { return ["type": "nowPlaying", "state": "closed"] }

    let fields = text.components(separatedBy: "\u{1F}")
    let volumePercent = Int(fields[1]) ?? 0

    guard fields.count == 8 else { return ["type": "nowPlaying", "state": "stopped", "volumePercent": volumePercent] }

    let persistentID = fields[6]
    var song: [String: Any] = [
      "name": fields[3], "artist": fields[4], "album": fields[5], "persistentID": persistentID,
      "durationSeconds": Self.readSeconds(fields[7]),
    ]

    if let path = readArtworkPath(persistentID: persistentID) { song["artworkPath"] = path }

    return [
      "type": "nowPlaying", "state": Self.toState(fields[0]), "volumePercent": volumePercent,
      "positionSeconds": Self.readSeconds(fields[2]), "song": song,
    ]
  }

  func apply(_ command: Command) {
    if let script = commandScripts[command.type] {
      if !isRunning { launch() }
      _ = run(script)
      return
    }

    switch command.type {
    case "seek":
      guard let positionSeconds = command.positionSeconds, isRunning else { return }
      _ = run(NSAppleScript(source: "tell application \"Music\" to set player position to \(positionSeconds)")!)
    case "setVolume":
      guard let volumePercent = command.volumePercent, isRunning else { return }
      let clampedPercent = min(max(volumePercent, 0), 100)
      _ = run(NSAppleScript(source: "tell application \"Music\" to set sound volume to \(clampedPercent)")!)
    default:
      sendError("The helper has no command named \(command.type).")
    }
  }

  // Plays the library song closest in length to the match. nil when the library holds no such song yet.
  func playSong(_ match: SongMatch) -> String? {
    if !isRunning { launch() }

    let name = Self.toAppleScriptText(match.name)
    let artist = Self.toAppleScriptText(match.artistName)
    let album = Self.toAppleScriptText(match.albumName)
    let findScript = NSAppleScript(source: """
      tell application "Music"
        set separator to character id 31
        set found to (every track of library playlist 1 whose name is \(name) and artist is \(artist) and album is \(album))
        set foundRows to {}
        repeat with t in found
          set end of foundRows to (persistent ID of t) & separator & (duration of t as text)
        end repeat
        set AppleScript's text item delimiters to linefeed
        return foundRows as text
      end tell
      """)!

    guard let text = run(findScript)?.stringValue, !text.isEmpty else { return nil }

    let candidates = text.split(separator: "\n").map { line in
      let fields = line.split(separator: "\u{1F}")

      return (persistentID: String(fields[0]), durationSeconds: Self.readSeconds(String(fields[1])))
    }

    guard let closest = candidates.min(by: { abs($0.durationSeconds - match.durationSeconds) < abs($1.durationSeconds - match.durationSeconds) }) else { return nil }

    _ = run(NSAppleScript(source: "tell application \"Music\" to play (first track of library playlist 1 whose persistent ID is \"\(closest.persistentID)\")")!)

    return closest.persistentID
  }

  // A quoted AppleScript string, so a song name with a quote or a backslash stays text.
  private static func toAppleScriptText(_ text: String) -> String {
    let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")

    return "\"\(escaped)\""
  }

  // Opens Music.app in the background, so it never comes in front of onlymuse.
  private func launch() {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) else { return }

    let configuration = NSWorkspace.OpenConfiguration()

    configuration.activates = false
    NSWorkspace.shared.openApplication(at: url, configuration: configuration)
  }

  private func run(_ script: NSAppleScript) -> NSAppleEventDescriptor? {
    var error: NSDictionary?
    let result = script.executeAndReturnError(&error)

    if let error {
      sendError("Music.app answered with an error: \(error[NSAppleScript.errorMessage] as? String ?? "\(error)")")
      return nil
    }

    return result
  }

  // The artwork of a song is saved once, under its persistent ID.
  private func readArtworkPath(persistentID: String) -> String? {
    let saved = try? FileManager.default.contentsOfDirectory(atPath: artworkFolder.path)

    if let name = saved?.first(where: { $0.hasPrefix(persistentID + ".") }) {
      return artworkFolder.appending(path: name).path
    }

    // A streamed song answers with the four bytes "msng", AppleScript's missing value, instead of an image.
    guard let data = run(artworkScript)?.data else { return nil }

    let isPng = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
    let isJpeg = data.starts(with: [0xFF, 0xD8])

    guard isPng || isJpeg else { return nil }

    let url = artworkFolder.appending(path: "\(persistentID).\(isPng ? "png" : "jpg")")

    try? data.write(to: url, options: .atomic)

    return url.path
  }

  // AppleScript writes a real number with the system's decimal mark, such as "12,5" in Indonesia.
  private static func readSeconds(_ text: String) -> Double {
    Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0
  }

  private static func toState(_ playerState: String) -> String {
    playerState == "paused" ? "paused" : "playing"
  }
}
