import AppKit
import WebKit

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

  private func apply(page: [String: Any]) {
    let pageID = page["id"] as? String ?? ""
    let playerState = page["state"] as? Int ?? -1
    let positionSeconds = page["position"] as? Double ?? 0
    let pageDurationSeconds = page["duration"] as? Double ?? 0
    let durationSeconds = pageDurationSeconds > 0 ? pageDurationSeconds : song?.durationSeconds ?? 0
    let isOtherSong = pageID != videoID && pageID != ""
    let isLoading = isOtherSong && lastState == nil
    let hasEnded = playerState == Self.endedState || (isOtherSong && !isLoading)

    if isLoading { return }

    if lastState == nil { sendVolumeToPage() }

    let isWaiting = !hasEnded && playerState != Self.playingState && playerState != Self.pausedState

    if isWaiting { return checkStuck(playerState: playerState) }

    stuckSince = nil
    if playerState == Self.playingState { playedSeconds = positionSeconds }

    let state: String

    if hasEnded {
      state = "stopped"
      pollTimer?.invalidate()
      pollTimer = nil
      run("document.getElementById('movie_player').pauseVideo()")
    } else if playerState == Self.pausedState {
      state = "paused"
    } else {
      state = "playing"
    }

    if state != lastState {
      lastState = state
      lastPositionSentAt = Date()

      var nowPlaying = makeNowPlaying(state: state, positionSeconds: positionSeconds, durationSeconds: durationSeconds)

      if state == "playing" { nowPlaying["hasStarted"] = true }
      send(nowPlaying)
      return
    }

    guard state == "playing", Date().timeIntervalSince(lastPositionSentAt) >= Self.positionSendSeconds else { return }

    lastPositionSentAt = Date()
    send(makePositionMessage(persistentID: Self.idPrefix + videoID, positionSeconds: positionSeconds))
  }

  private func checkSlowStart() {
    guard lastState == nil, isPageLoaded, Date().timeIntervalSince(startAskedAt) >= Self.slowStartSeconds else { return }

    let name = song?.name ?? videoID

    startAskedAt = Date()
    startRetryCount += 1
    playerView?.evaluateJavaScript("JSON.stringify({ state: \(Self.readStateScript), problem: \(Self.readProblemScript) })") { result, _ in
      sendError("The YouTube page did not start \(name) within \(Int(Self.slowStartSeconds)) s. The page showed: \(result as? String ?? "nothing")")
    }
    retryStart(attempt: startRetryCount, startSeconds: 0)
  }

  private func checkStuck(playerState: Int?) {
    guard lastState == "playing" else { return }
    guard let since = stuckSince else {
      stuckSince = Date()
      return
    }
    guard Date().timeIntervalSince(since) >= Self.stuckSeconds else { return }

    let name = song?.name ?? videoID
    let positionSeconds = Int(playedSeconds)
    let stateText = playerState.map { "state \($0)" } ?? "no answer"

    stuckSince = Date()
    reloadCount += 1
    playerView?.evaluateJavaScript(Self.readProblemScript) { result, _ in
      sendError("The YouTube page stopped \(name) at \(positionSeconds / 60):\(String(format: "%02d", positionSeconds % 60)) by itself (\(stateText)). The page showed: \(result as? String ?? "nothing")")
    }
    retryStart(attempt: reloadCount, startSeconds: playedSeconds)
  }

  private func retryStart(attempt: Int, startSeconds: Double) {
    let name = song?.name ?? videoID

    guard attempt <= Self.maxRetryCount else {
      sendError("The YouTube page did not start \(name) after \(Self.maxRetryCount) tries.")
      run("document.getElementById('movie_player')?.pauseVideo()")
      lastState = "paused"
      stuckSince = nil
      send(makeNowPlaying(state: "paused", positionSeconds: startSeconds, durationSeconds: song?.durationSeconds ?? 0))
      return
    }

    guard attempt > 1 else {
      sendError("The helper asks the YouTube page for \(name) again.")
      return run(toPlayScript(isLoadForced: true, startSeconds: startSeconds))
    }

    reopenPage(startSeconds: startSeconds)
  }

  // WebKit can keep a connection that sends nothing. Only a new network process drops it.
  private func reopenPage(startSeconds: Double) {
    sendError("The helper starts its network connections again and opens the YouTube page again for \(song?.name ?? videoID).")
    resumeSeconds = startSeconds
    isPageLoaded = false

    let store = WKWebsiteDataStore.default()
    let terminate = NSSelectorFromString("_terminateNetworkProcess")

    if store.responds(to: terminate) { store.perform(terminate) }
    playerView?.load(URLRequest(url: Self.toWatchURL(videoID: videoID)))
  }

  func makeNowPlaying(state: String, positionSeconds: Double, durationSeconds: Double) -> [String: Any] {
    guard state != "stopped", let song else { return ["type": "nowPlaying", "state": "stopped", "volumePercent": volumePercent] }

    return [
      "type": "nowPlaying", "state": state, "volumePercent": volumePercent,
      "positionSeconds": positionSeconds, "positionReadAtMs": nowMs,
      "song": [
        "name": song.name, "artist": song.artistName, "album": song.albumName,
        "persistentID": Self.idPrefix + videoID, "durationSeconds": durationSeconds,
      ],
    ]
  }
}
