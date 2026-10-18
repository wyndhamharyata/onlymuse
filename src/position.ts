import { useEffect, useState } from "react";
import { readHelperState, useHelper, type HelperState } from "./helper.ts";

// Music.app posts only on a change, so the position moves on here between its posts.
function readPositionSeconds(helper: HelperState, nowMs: number): number {
  const nowPlaying = helper.nowPlaying;

  if (nowPlaying.state !== "playing" && nowPlaying.state !== "paused") return 0;
  if (nowPlaying.state === "paused") return nowPlaying.positionSeconds;

  const elapsedSeconds =
    (Math.max(nowMs, helper.nowPlayingReceivedAtMs) - helper.nowPlayingReceivedAtMs) / 1000;

  return Math.min(nowPlaying.positionSeconds + elapsedSeconds, nowPlaying.song.durationSeconds);
}

// The position now, for a click. It renders nothing.
export function readCurrentPositionSeconds(): number {
  return readPositionSeconds(readHelperState(), Date.now());
}

// The position, drawn again just after each step of tickMs while Music.app plays, so a clock of whole seconds turns on time.
export function usePositionSeconds(tickMs: number): number {
  const helper = useHelper();
  const isPlaying = helper.nowPlaying.state === "playing";
  const [nowMs, setNowMs] = useState(Date.now());

  useEffect(() => {
    if (!isPlaying) return;

    let timer: ReturnType<typeof setTimeout>;

    const scheduleTick = (): void => {
      const positionMs = readPositionSeconds(readHelperState(), Date.now()) * 1000;
      const untilStepMs = tickMs - (positionMs % tickMs) + 5;

      timer = setTimeout(() => {
        setNowMs(Date.now());
        scheduleTick();
      }, untilStepMs);
    };

    scheduleTick();

    return () => clearTimeout(timer);
  }, [isPlaying, tickMs, helper]);

  return readPositionSeconds(helper, nowMs);
}
