import AppKit
import WebKit

// Reads the YouTube page twice a second, tells the app what it plays, and starts a song again that has stuck.
extension YouTube {
  func startPolling() {
    pollTimer?.invalidate()
    pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollSeconds, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.poll() }
    }
  }

  private func poll() {
    guard isActive, let playerView else { return }

    playerView.evaluateJavaScript(Self.readStateScript) { [weak self] result, _ in
      MainActor.assumeIsolated {
        guard let self, self.isActive else { return }
        self.checkSlowStart()
        guard let text = result as? String, let data = text.data(using: .utf8), let page = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
          return self.checkStuck(playerState: nil)
        }

        self.apply(page: page)
      }
    }
  }

  // Sends nowPlaying when the state changes, and the position every few seconds, as Music.app's side does.
  private func apply(page: [String: Any]) {
    let pageID = page["id"] as? String ?? ""
    let playerState = page["state"] as? Int ?? -1
    let positionSeconds = page["position"] as? Double ?? 0
    let pageDuration = page["duration"] as? Double ?? 0
    let durationSeconds = pageDuration > 0 ? pageDuration : song?.durationSeconds ?? 0
    // Until the new song loads, the page still holds the last one.
    let isLoading = pageID != videoID && pageID != "" && lastState == ""
    let hasEnded = playerState == Self.endedState || (pageID != videoID && !isLoading && pageID != "")

    if isLoading { return }

    // The page plays at its own volume until a song's first state comes, as the player may not exist before.
    if lastState == "" { run("document.getElementById('movie_player').setVolume(\(volumePercent))") }

    // Before a song starts, and while it waits for more of itself, the page plays nothing, and the app hears
    // nothing new. A song that played and then waits too long loads again.
    let isWaiting = !hasEnded && playerState != Self.playingState && playerState != Self.pausedState

    if isWaiting { return checkStuck(playerState: playerState) }

    stuckSince = nil
    if playerState == Self.playingState { playedSeconds = positionSeconds }

    let state = hasEnded ? "stopped" : playerState == Self.pausedState ? "paused" : "playing"

    if hasEnded {
      pollTimer?.invalidate()
      pollTimer = nil
      run("document.getElementById('movie_player').pauseVideo()")
    }

    if state != lastState {
      lastState = state
      lastPositionSentAt = Date()
      var nowPlaying = toNowPlaying(state: state, positionSeconds: positionSeconds, durationSeconds: durationSeconds)
      // The page says it plays only once it does, so its clock moves on from the first post.
      if state == "playing" { nowPlaying["hasStarted"] = true }
      send(nowPlaying)
      return
    }

    guard state == "playing", Date().timeIntervalSince(lastPositionSentAt) >= Self.positionSendSeconds else { return }

    lastPositionSentAt = Date()
    send(["type": "position", "persistentID": Self.idPrefix + videoID, "positionSeconds": positionSeconds, "positionReadAtMs": MusicApp.nowMs()])
  }

  // The song has not started long after the page had it, as when the page's load of it hangs with no error.
  private func checkSlowStart() {
    guard lastState == "", isPageLoaded, Date().timeIntervalSince(startAskedAt) >= Self.slowStartSeconds else { return }

    startAskedAt = Date()
    startRetryCount += 1
    let name = song?.name ?? videoID

    // The app shows the song as paused at its start, so the person can press Play again or skip it.
    guard startRetryCount <= Self.maxStartRetryCount else {
      sendError("The YouTube page still has not started \(name).")
      run("document.getElementById('movie_player')?.pauseVideo()")
      lastState = "paused"
      send(toNowPlaying(state: "paused", positionSeconds: 0, durationSeconds: song?.durationSeconds ?? 0))
      return
    }

    playerView?.evaluateJavaScript("JSON.stringify({ state: \(Self.readStateScript), problem: \(Self.readProblemScript) })") { result, _ in
      sendError("The YouTube page had not started \(name) after \(Int(Self.slowStartSeconds)) s. The page showed: \(result as? String ?? "nothing")")
    }

    if startRetryCount == 1 {
      sendError("The helper asks the YouTube page for \(name) again.")
      run(toPlayScript(forcesLoad: true))
    } else {
      reopenPage(startSeconds: 0)
    }
  }

  // WebKit's network process can keep a connection that sends nothing, as when the network allows only smaller
  // packets than HTTP/3 sends, and each request on it hangs for two minutes. A new network process makes new
  // connections, then the page opens again with the song from startSeconds.
  private func reopenPage(startSeconds: Double) {
    sendError("The helper starts its network connections again and opens the YouTube page again for \(song?.name ?? videoID).")
    resumeSeconds = startSeconds
    isPageLoaded = false

    let store = WKWebsiteDataStore.default()
    let terminate = NSSelectorFromString("_terminateNetworkProcess")
    if store.responds(to: terminate) { store.perform(terminate) }

    playerView?.load(URLRequest(url: URL(string: "https://music.youtube.com/watch?v=\(videoID)")!))
  }

  // The page stopped a song that played, by itself: it answers no state, or one neither playing nor paused. It
  // loads the song again where it stopped, and after maxReloadCount tries the app shows it paused.
  private func checkStuck(playerState: Int?) {
    guard lastState == "playing" else { return }
    guard let since = stuckSince else {
      stuckSince = Date()
      return
    }
    guard Date().timeIntervalSince(since) >= Self.stuckSeconds else { return }

    stuckSince = Date()
    reloadCount += 1
    let name = song?.name ?? videoID
    let position = Int(playedSeconds)
    let stateText = playerState.map { "state \($0)" } ?? "no answer"

    playerView?.evaluateJavaScript(Self.readProblemScript) { result, _ in
      sendError("The YouTube page stopped \(name) at \(position / 60):\(String(format: "%02d", position % 60)) by itself (\(stateText)). The page showed: \(result as? String ?? "nothing")")
    }

    guard reloadCount <= Self.maxReloadCount else {
      lastState = "paused"
      stuckSince = nil
      send(toNowPlaying(state: "paused", positionSeconds: playedSeconds, durationSeconds: song?.durationSeconds ?? 0))
      return sendError("\(name) did not play again after \(Self.maxReloadCount) tries, so it shows as paused.")
    }

    guard reloadCount == 1 else { return reopenPage(startSeconds: playedSeconds) }

    sendError("The helper loads \(name) again from where it stopped.")
    run(toPlayScript(forcesLoad: true, startSeconds: playedSeconds))
  }

  func toNowPlaying(state: String, positionSeconds: Double, durationSeconds: Double) -> [String: Any] {
    guard state != "stopped", let song else { return ["type": "nowPlaying", "state": "stopped", "volumePercent": volumePercent] }

    return [
      "type": "nowPlaying", "state": state, "volumePercent": volumePercent,
      "positionSeconds": positionSeconds, "positionReadAtMs": MusicApp.nowMs(),
      "song": [
        "name": song.name, "artist": song.artistName, "album": song.albumName,
        "persistentID": Self.idPrefix + videoID, "durationSeconds": durationSeconds,
      ],
    ]
  }
}
