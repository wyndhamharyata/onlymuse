import AppKit

// Each read checks isRunning first, as an AppleScript tell would open Music.app.
@MainActor
final class MusicApp {
  nonisolated static let bundleIdentifier = "com.apple.Music"
  private static let fieldSeparatorCode: UInt8 = 31
  private static let fieldSeparator = String(UnicodeScalar(fieldSeparatorCode))

  private let artworkFolder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appending(path: "onlymuse/artwork")

  private let nowPlayingScript = NSAppleScript(source: """
    tell application "Music"
      set separator to character id \(MusicApp.fieldSeparatorCode)
      set volumeText to (sound volume as text)
      set stateText to (player state as text)
      if stateText is "stopped" then return stateText & separator & volumeText
      set playingSong to current track
      return stateText & separator & volumeText & separator & (player position as text) & separator & (name of playingSong) & separator & (artist of playingSong) & separator & (album of playingSong) & separator & (persistent ID of playingSong) & separator & (duration of playingSong as text)
    end tell
    """)!

  private let artworkScript = NSAppleScript(source: """
    tell application "Music"
      if (count of artworks of current track) is 0 then return missing value
      return raw data of artwork 1 of current track
    end tell
    """)!

  private let volumeScript = NSAppleScript(source: "tell application \"Music\" to return sound volume")!
  private var lastVolumePercent: Int?

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
    guard isRunning, let text = run(nowPlayingScript)?.stringValue else { return ["type": "nowPlaying", "state": "closed"] }

    let positionReadAtMs = nowMs
    let fields = text.components(separatedBy: Self.fieldSeparator)

    guard fields.count >= 2 else { return ["type": "nowPlaying", "state": "stopped"] }

    let volumePercent = Int(fields[1]) ?? 0

    guard fields.count == 8 else { return ["type": "nowPlaying", "state": "stopped", "volumePercent": volumePercent] }

    let persistentID = fields[6]
    var song: [String: Any] = [
      "name": fields[3], "artist": fields[4], "album": fields[5], "persistentID": persistentID,
      "durationSeconds": Self.readSeconds(fields[7]),
    ]

    if let path = saveArtwork(persistentID: persistentID) { song["artworkPath"] = path }

    return [
      "type": "nowPlaying", "state": Self.toState(fields[0]), "volumePercent": volumePercent,
      "positionSeconds": Self.readSeconds(fields[2]), "positionReadAtMs": positionReadAtMs, "song": song,
    ]
  }

  func readPosition() -> [String: Any]? {
    guard let playback = readPlayback() else { return nil }

    return makePositionMessage(persistentID: playback.persistentID, positionSeconds: playback.positionSeconds)
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
      send(readNowPlaying())
    case "setVolume":
      guard let volumePercent = command.volumePercent?.value, isRunning else { return }

      _ = run(NSAppleScript(source: "tell application \"Music\" to set sound volume to \(volumePercent)")!)
      send(readNowPlaying())
    case "songInfo":
      guard let persistentID = command.persistentID else { return }

      send(readSongInfo(persistentID: persistentID))
    case "setFavorite":
      applyFavorite(command)
    default:
      sendError("The helper has no command named \(command.type).")
    }
  }

  func playSong(_ match: SongMatch) -> String? {
    if !isRunning { launch() }

    guard let persistentID = findSong(match) else { return nil }

    play(persistentID: persistentID)

    return persistentID
  }

  func pauseIfRunning() {
    guard isRunning else { return }

    _ = run(NSAppleScript(source: "tell application \"Music\" to pause")!)
  }

  func play(persistentID: String) {
    _ = run(NSAppleScript(source: "tell application \"Music\" to play (first track of library playlist 1 whose persistent ID is \(Self.toAppleScriptText(persistentID)))")!)
  }

  private static func toFindSongScript(persistentID: String) -> String {
    let id = toAppleScriptText(persistentID)

    return """
      set foundSong to missing value
      try
        if persistent ID of current track is \(id) then set foundSong to current track
      end try
      if foundSong is missing value then
        set found to (every track of library playlist 1 whose persistent ID is \(id))
        if (count of found) is 0 then return missing value
        set foundSong to item 1 of found
      end if
      """
  }

  func readSongInfo(persistentID: String) -> [String: Any] {
    var info: [String: Any] = ["type": "songInfo", "persistentID": persistentID]

    guard isRunning, !persistentID.isEmpty else { return info }

    let names = [
      "played count", "played date", "skipped count", "skipped date", "date added", "favorited", "rating",
      "bit rate", "sample rate", "kind", "bpm", "size",
    ]
    let reads = names.enumerated().map { index, name in
      "  set item \(index + 1) of answers to missing value\n  try\n    set item \(index + 1) of answers to (\(name) of foundSong)\n  end try"
    }.joined(separator: "\n")
    let script = NSAppleScript(source: """
      tell application "Music"
      \(Self.toFindSongScript(persistentID: persistentID))
        set answers to {\(names.map { _ in "missing value" }.joined(separator: ", "))}
      \(reads)
        return answers
      end tell
      """)!

    guard let list = run(script), list.numberOfItems == names.count else { return info }

    for (index, name) in names.enumerated() {
      guard let item = list.atIndex(index + 1), item.descriptorType != typeType else { continue }
      let key = Self.toCamelCase(name)

      switch name {
      case "played date", "skipped date", "date added":
        if let date = item.dateValue { info[key + "Ms"] = date.timeIntervalSince1970 * 1000 }
      case "favorited":
        info[key] = item.booleanValue
      case "kind":
        if let text = item.stringValue { info[key] = text }
      case "size":
        info[key] = item.doubleValue
      default:
        info[key] = Int(item.int32Value)
      }
    }

    info["isInLibrary"] = info["dateAddedMs"] != nil

    return info
  }

  private func applyFavorite(_ command: Command) {
    guard let favorited = command.favorited else { return }

    let changedID = setFavorite(persistentID: command.persistentID, match: command.song, favorited: favorited)
    var result: [String: Any] = ["type": "setFavoriteResult", "favorited": favorited, "persistentID": changedID ?? NSNull()]

    if let requestId = command.requestId { result["requestId"] = requestId }
    send(result)
    if let changedID { send(readSongInfo(persistentID: changedID)) }
  }

  private func setFavorite(persistentID: String?, match: SongMatch?, favorited: Bool) -> String? {
    guard isRunning, let id = persistentID ?? match.flatMap({ findSong($0) }) else { return nil }

    let script = NSAppleScript(source: """
      tell application "Music"
      \(Self.toFindSongScript(persistentID: id))
        set favorited of foundSong to \(favorited)
        return "done"
      end tell
      """)!

    return run(script)?.stringValue == "done" ? id : nil
  }

  private static func toCamelCase(_ name: String) -> String {
    let words = name.split(separator: " ")

    return words.enumerated().map { index, word in index == 0 ? String(word) : word.capitalized }.joined()
  }

  func findSong(_ match: SongMatch) -> String? {
    let name = Self.toAppleScriptText(match.name)
    let artist = Self.toAppleScriptText(match.artistName)
    let album = Self.toAppleScriptText(match.albumName)
    let findScript = NSAppleScript(source: """
      tell application "Music"
        set separator to character id \(Self.fieldSeparatorCode)
        set found to (every track of library playlist 1 whose name is \(name) and artist is \(artist) and album is \(album))
        set foundRows to {}
        repeat with candidate in found
          set end of foundRows to (persistent ID of candidate) & separator & (duration of candidate as text)
        end repeat
        set AppleScript's text item delimiters to linefeed
        return foundRows as text
      end tell
      """)!

    guard let text = run(findScript)?.stringValue, !text.isEmpty else { return nil }

    let candidates = text.split(separator: "\n").map { line in
      let fields = line.components(separatedBy: Self.fieldSeparator)

      return (persistentID: String(fields[0]), durationSeconds: Self.readSeconds(String(fields[1])))
    }

    let toLengthGap = { (candidate: (persistentID: String, durationSeconds: Double)) in abs(candidate.durationSeconds - match.durationSeconds) }

    return candidates.min(by: { toLengthGap($0) < toLengthGap($1) })?.persistentID
  }

  private let playbackScript = NSAppleScript(source: """
    tell application "Music"
      if player state is not playing then return ""
      set separator to character id \(MusicApp.fieldSeparatorCode)
      set playingSong to current track
      return (persistent ID of playingSong) & separator & (player position as text) & separator & (duration of playingSong as text)
    end tell
    """)!

  func readPlayback() -> (persistentID: String, positionSeconds: Double, durationSeconds: Double)? {
    guard isRunning, let text = run(playbackScript)?.stringValue, !text.isEmpty else { return nil }

    let fields = text.components(separatedBy: Self.fieldSeparator)

    guard fields.count == 3 else { return nil }

    return (fields[0], Self.readSeconds(fields[1]), Self.readSeconds(fields[2]))
  }

  private static func toAppleScriptText(_ text: String) -> String {
    let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")

    return "\"\(escaped)\""
  }

  func readVolumePercent() -> Int? {
    guard isRunning else { return nil }

    return run(volumeScript).map { Int($0.int32Value) }
  }

  func sendVolumeWhenChanged() {
    guard let volumePercent = readVolumePercent() else { return }
    guard volumePercent != lastVolumePercent else { return }

    lastVolumePercent = volumePercent
    send(readNowPlaying())
  }

  private func launch() {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) else { return }

    let configuration = NSWorkspace.OpenConfiguration()

    configuration.activates = false
    NSWorkspace.shared.openApplication(at: url, configuration: configuration)
  }

  private func run(_ script: NSAppleScript, isErrorReported: Bool = true) -> NSAppleEventDescriptor? {
    var error: NSDictionary?
    let result = script.executeAndReturnError(&error)

    guard let error else { return result }

    if isErrorReported { sendError("Music.app answered with an error: \(error[NSAppleScript.errorMessage] as? String ?? "\(error)")") }

    return nil
  }

  private func saveArtwork(persistentID: String) -> String? {
    let saved = try? FileManager.default.contentsOfDirectory(atPath: artworkFolder.path)

    if let name = saved?.first(where: { $0.hasPrefix(persistentID + ".") }) {
      return artworkFolder.appending(path: name).path
    }

    // A streamed song may answer "msng", AppleScript's missing value, instead of artwork.
    guard let data = run(artworkScript, isErrorReported: false)?.data else { return nil }

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
