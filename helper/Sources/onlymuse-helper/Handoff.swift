import Foundation

// This class starts the queue's next song a moment before the one playing ends, so Music.app never picks a song of its own.
@MainActor
final class Handoff {
  // The next song starts this much before the end, which is less than Music.app's own switch takes.
  private let leadSeconds = 0.04
  // The timer wakes this long before the end and reads the position again. A seek or a pause moves the end.
  private let checkSeconds = 0.4
  // A switch by Music.app this close to the end is its own pick, which the next song replaces.
  private let endToleranceSeconds = 3.0

  private let music: MusicApp
  private let youTube: YouTube
  private var afterID: String?
  private var next: SongMatch?
  private var nextID: String?
  private var expectedEnd: Date?
  private var timer: Timer?

  init(music: MusicApp, youTube: YouTube) {
    self.music = music
    self.youTube = youTube
  }

  // This sets the song to play after afterID ends. nil cancels the handoff. It answers with the next song's persistent ID.
  func set(afterID: String?, next: SongMatch?) -> String? {
    self.afterID = afterID
    self.next = next

    if afterID == nil || !music.isRunning {
      nextID = nil
    } else if let videoID = next?.youTubeVideoID {
      nextID = YouTube.idPrefix + videoID
    } else {
      nextID = next.flatMap { music.findSong($0) }
    }

    arm()

    // A YouTube song after Music.app's song loads ahead. An empty afterID ends the queue. The page that loaded
    // ahead then goes. After a YouTube song, afterID is nil. The page then plays on.
    if afterID != nil { youTube.prepare(videoID: next?.youTubeVideoID ?? "") }

    return nextID
  }

  // Music.app posted a change: a pause, a play, or another song.
  func onPlayerChange() {
    guard let afterID, nextID != nil else { return }

    let playback = music.readPlayback()
    let isNearEnd = expectedEnd.map { abs($0.timeIntervalSinceNow) < endToleranceSeconds } ?? false

    if let playback, playback.persistentID != afterID, isNearEnd { return fire() }

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

    let nextSong = next

    timer?.invalidate()
    timer = nil
    afterID = nil
    next = nil
    self.nextID = nil
    expectedEnd = nil

    if let nextSong, let videoID = nextSong.youTubeVideoID {
      _ = youTube.play(nextSong, videoID: videoID)
      return
    }

    music.play(persistentID: nextID)
  }
}
