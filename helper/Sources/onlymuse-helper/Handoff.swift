import Foundation

// Starts the queue's next song a moment before the one playing ends, so Music.app never picks a song of its own.
@MainActor
final class Handoff {
  // The next song starts this much before the end, which is less than Music.app's own switch takes.
  private let leadSeconds = 0.04
  // The timer wakes this long before the end, and reads the position again, as a seek or a pause moves the end.
  private let checkSeconds = 0.4
  // A switch by Music.app this close to the end is its own pick, which the next song replaces.
  private let endToleranceSeconds = 3.0

  private let music: MusicApp
  private var afterID: String?
  private var nextID: String?
  private var expectedEnd: Date?
  private var timer: Timer?

  init(music: MusicApp) {
    self.music = music
  }

  // The song to play after afterID ends. nil clears the handoff. Answers with the next song's persistent ID.
  func set(afterID: String?, next: SongMatch?) -> String? {
    self.afterID = afterID
    nextID = afterID == nil || !music.isRunning ? nil : next.flatMap { music.findSong($0) }
    arm()

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

    timer?.invalidate()
    timer = nil
    afterID = nil
    self.nextID = nil
    expectedEnd = nil
    music.play(persistentID: nextID)
  }
}
