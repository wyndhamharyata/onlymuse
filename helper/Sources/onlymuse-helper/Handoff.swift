import Foundation

@MainActor
final class Handoff {
  private let leadSeconds = 0.04
  private let checkSeconds = 0.4
  private let endToleranceSeconds = 3.0

  private let music: MusicApp
  private let youTube: YouTube
  private var afterID: String?
  private var nextSong: SongMatch?
  private var nextID: String?
  private var expectedEnd: Date?
  private var timer: Timer?

  init(music: MusicApp, youTube: YouTube) {
    self.music = music
    self.youTube = youTube
  }

  func apply(_ command: Command) {
    guard let requestId = command.requestId else { return }

    switch command.type {
    case "playSong":
      guard let song = command.song else { return }

      send(["type": "playSongResult", "requestId": requestId, "persistentID": playSong(song) ?? NSNull()])
    case "setNext":
      send(["type": "setNextResult", "requestId": requestId, "persistentID": setNext(command) ?? NSNull()])
    default:
      break
    }
  }

  private func playSong(_ song: SongMatch) -> String? {
    if let videoID = song.youTubeVideoID { return youTube.play(song, videoID: videoID) }

    youTube.stop()

    return music.playSong(song)
  }

  private func setNext(_ command: Command) -> String? {
    youTube.isPageKept = command.keepsYouTube ?? false

    let isAfterYouTube = command.afterPersistentID?.hasPrefix(YouTube.idPrefix) ?? false
    let afterID = isAfterYouTube ? nil : command.afterPersistentID

    set(afterID: afterID, nextSong: command.song)

    if !isAfterYouTube { youTube.prepare(videoID: afterID == nil ? "" : command.song?.youTubeVideoID ?? "") }

    return nextID
  }

  private func set(afterID: String?, nextSong: SongMatch?) {
    let isHandoffOff = afterID == nil || !music.isRunning

    self.afterID = afterID
    self.nextSong = nextSong

    if isHandoffOff {
      nextID = nil
    } else if let videoID = nextSong?.youTubeVideoID {
      nextID = YouTube.idPrefix + videoID
    } else {
      nextID = nextSong.flatMap { music.findSong($0) }
    }

    arm()
  }

  func applyPlayerChange() {
    guard let afterID, nextID != nil else { return }

    let playingID = music.readPlayback()?.persistentID
    let isNearEnd = expectedEnd.map { abs($0.timeIntervalSinceNow) < endToleranceSeconds } ?? false
    let isMusicAppPick = playingID != nil && playingID != afterID && isNearEnd

    if isMusicAppPick { return fire() }

    arm()
  }

  func arm() {
    timer?.invalidate()
    timer = nil

    guard let afterID, nextID != nil, let playback = music.readPlayback(), playback.persistentID == afterID else {
      expectedEnd = nil
      return
    }

    let remainingSeconds = playback.durationSeconds - playback.positionSeconds

    expectedEnd = Date(timeIntervalSinceNow: remainingSeconds)

    if remainingSeconds > checkSeconds {
      return schedule(after: remainingSeconds - checkSeconds) { $0.arm() }
    }

    schedule(after: max(0, remainingSeconds - leadSeconds)) { $0.fire() }
  }

  private func schedule(after seconds: Double, action: @escaping @MainActor (Handoff) -> Void) {
    timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }

        action(self)
      }
    }
  }

  private func fire() {
    guard let nextID else { return }

    let song = nextSong

    timer?.invalidate()
    timer = nil
    afterID = nil
    nextSong = nil
    self.nextID = nil
    expectedEnd = nil

    if let song, let videoID = song.youTubeVideoID {
      _ = youTube.play(song, videoID: videoID)
      return
    }

    music.play(persistentID: nextID)
  }
}
