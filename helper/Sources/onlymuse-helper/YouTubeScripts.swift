import AppKit
import WebKit

extension YouTube {
  static let pageScript = """
    window.onlymuseVideoID = "";
    window.onlymuseIsPreparing = location.hash === "#\(YouTube.prepareHash)";
    document.addEventListener("play", (event) => { if (window.onlymuseIsPreparing) event.target.muted = true }, true);
    document.addEventListener("playing", () => {
      const player = document.getElementById("movie_player");
      if (!player) return;
      if (window.onlymuseIsPreparing || (window.onlymuseVideoID && player.getVideoData().video_id !== window.onlymuseVideoID)) player.pauseVideo();
    }, true);
    """

  static let prepareHash = "onlymuse-prepare"

  static let nudgeScript = """
    (() => {
      const player = document.getElementById("movie_player");
      if (!window.onlymuseIsPreparing || !player || !player.getPlayerState) return false;
      player.mute();
      if (player.getPlayerState() === \(pausedState) && player.getDuration() > 0) return true;
      if (player.getPlayerState() !== \(playingState)) player.playVideo();
      return false;
    })()
    """

  // The page's player turns its sound back on, so a quiet run locks muted and volume.
  static let muteScript = """
    (() => {
      const muted = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, "muted");
      const volume = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, "volume");
      Object.defineProperty(HTMLMediaElement.prototype, "muted", { get() { return true }, set() {}, configurable: true });
      Object.defineProperty(HTMLMediaElement.prototype, "volume", { get() { return 0 }, set() {}, configurable: true });
      document.addEventListener("play", (event) => { muted.set.call(event.target, true); volume.set.call(event.target, 0) }, true);
    })();
    """

  static let readStateScript = """
    (() => {
      const player = document.getElementById("movie_player");
      if (!player || !player.getVideoData) return "";
      return JSON.stringify({ id: player.getVideoData().video_id, state: player.getPlayerState(), position: player.getCurrentTime(), duration: player.getDuration() });
    })()
    """

  static let readProblemScript = """
    (() => JSON.stringify({
      visibility: document.visibilityState,
      error: document.querySelector(".ytp-error")?.innerText ?? "",
      dialogs: [...document.querySelectorAll("tp-yt-paper-dialog, ytmusic-you-there-renderer")].filter((dialog) => dialog.offsetParent).map((dialog) => dialog.innerText.slice(0, 200)),
      hasSource: !!document.querySelector("video")?.src,
    }))()
    """

  static let endedState = 0

  static let playingState = 1

  static let pausedState = 2

  static let bufferingState = 3

  static let unstartedState = -1

  static let rewindAfterSeconds = 1.0

  func toPlayScript(isLoadForced: Bool = false, startSeconds: Double = 0) -> String {
    let id = toJavaScriptText(videoID)
    let unmute = isQuiet ? "" : "const video = document.querySelector('video'); if (video) video.muted = false; player?.unMute?.();"

    return """
      (() => {
        window.onlymuseIsPreparing = false;
        window.onlymuseVideoID = \(id);
        const player = document.getElementById('movie_player');
        \(unmute)
        if (!player || !player.getVideoData) return;
        if (\(!isLoadForced) && player.getVideoData().video_id === \(id) && player.getPlayerState() !== \(Self.endedState)) {
          if (player.getCurrentTime() > \(Self.rewindAfterSeconds)) player.seekTo(0, true);
          player.playVideo();
        } else {
          player.loadVideoById({ videoId: \(id), startSeconds: \(startSeconds) });
        }
      })()
      """
  }
}
