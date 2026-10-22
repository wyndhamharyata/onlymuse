import AppKit
import WebKit

// The JavaScript the helper runs in the YouTube page, and the player states it reads back.
extension YouTube {
  // The page plays its own next song when one ends. Only the app's queue picks what plays, so any other song pauses.
  // A song loaded ahead, while Music.app plays, is muted and paused once it starts, so it waits ready to play.
  // A page first loaded for that says so in its address, as the page plays its song before didFinish.
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

  // The page may load a song's address and fetch none of it until it is played, so it is played, muted and
  // paused at once, until its length is known.
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

  // A quiet run mutes each song before it makes a sound, and the page's player can never turn it back on.
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

  // What the page shows when its song stops by itself, for the Console.
  static let readProblemScript = """
    (() => JSON.stringify({
      visibility: document.visibilityState,
      error: document.querySelector(".ytp-error")?.innerText ?? "",
      dialogs: [...document.querySelectorAll("tp-yt-paper-dialog, ytmusic-you-there-renderer")].filter((dialog) => dialog.offsetParent).map((dialog) => dialog.innerText.slice(0, 200)),
      hasSource: !!document.querySelector("video")?.src,
    }))()
    """

  // The page's player states, as YT.PlayerState names them.
  static let endedState = 0

  static let playingState = 1

  static let pausedState = 2

  static let bufferingState = 3

  static let unstartedState = -1

  // Plays the song, at once when it was loaded ahead, and with sound again after it waited muted.
  // forcesLoad loads the song again even when the page already holds it, from startSeconds.
  func toPlayScript(forcesLoad: Bool = false, startSeconds: Double = 0) -> String {
    let id = quoted(videoID)
    let unmute = isQuiet ? "" : "const video = document.querySelector('video'); if (video) video.muted = false; player?.unMute?.();"

    return """
      (() => {
        window.onlymuseIsPreparing = false;
        window.onlymuseVideoID = \(id);
        const player = document.getElementById('movie_player');
        \(unmute)
        if (!player || !player.getVideoData) return;
        if (\(!forcesLoad) && player.getVideoData().video_id === \(id) && player.getPlayerState() !== \(Self.endedState)) {
          if (player.getCurrentTime() > 1) player.seekTo(0, true);
          player.playVideo();
        } else {
          player.loadVideoById({ videoId: \(id), startSeconds: \(startSeconds) });
        }
      })()
      """
  }
}
