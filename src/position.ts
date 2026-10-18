import { useEffect, useState } from "react";
import { useHelper, type HelperState } from "./helper.ts";

const tickMs = 250;

// Music.app posts only on a change, so the position moves on here between its posts.
function readPositionSeconds(helper: HelperState, nowMs: number): number {
  const nowPlaying = helper.nowPlaying;

  if (nowPlaying.state !== "playing" && nowPlaying.state !== "paused") return 0;
  if (nowPlaying.state === "paused") return nowPlaying.positionSeconds;

  const elapsedSeconds = (nowMs - helper.nowPlayingReceivedAtMs) / 1000;

  return Math.min(nowPlaying.positionSeconds + elapsedSeconds, nowPlaying.song.durationSeconds);
}

export function usePositionSeconds(): number {
  const helper = useHelper();
  const isPlaying = helper.nowPlaying.state === "playing";
  const [nowMs, setNowMs] = useState(Date.now());

  useEffect(() => {
    if (!isPlaying) return;

    const timer = setInterval(() => setNowMs(Date.now()), tickMs);

    return () => clearInterval(timer);
  }, [isPlaying]);

  return readPositionSeconds(helper, Math.max(nowMs, helper.nowPlayingReceivedAtMs));
}
