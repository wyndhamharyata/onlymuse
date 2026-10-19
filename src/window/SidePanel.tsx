import { useEffect, useMemo, useRef, useState } from "react";
import { flushSync } from "@gpuix/react";
import {
  fetchLyrics,
  findCatalogSong,
  toArtworkUrl,
  type CatalogSong,
  type LyricLine,
  type LyricWord,
} from "../apple-music.ts";
import { useAccent, useHelper } from "../helper.ts";
import { readCurrentPositionSeconds } from "../position.ts";
import { probe } from "../probe.ts";
import { findQueueSong, playQueueAt, removeFromQueue, useQueue } from "../queue.ts";
import { colors, toAccentTint } from "../theme.ts";
import { PageStatus, useFetched } from "./Fetched.tsx";
import { Artwork } from "./Artwork.tsx";
import { ScrollingText } from "./ScrollingText.tsx";
import { toWindowStart } from "./PageList.tsx";

export type Panel = "queue" | "lyrics";

export function isPanel(value: unknown): value is Panel | null {
  return value === null || value === "queue" || value === "lyrics";
}

export const panelWidthPx = 300;
const artworkSizePx = 36;
const historyCount = 2;
// Up Next mounts this many rows around the ones in view, whatever the length of the queue.
const queueWindowCount = 64;
const queueRowHeightPx = 48;
// One object for every row, so a render of Up Next sends no style that did not change.
const queueRowStyle = { display: "flex", flexDirection: "column", width: "100%" } as const;
const linesBeforeCurrent = 3;
// The timer for the next word fires this much after its start, so a word is never a hair early.
const lineSlackMs = 5;
const shownLineCount = 14;

const panelTitles: Record<Panel, string> = { queue: "Up Next", lyrics: "Lyrics" };

function Tabs({ panel, onPanel }: { panel: Panel; onPanel: (panel: Panel) => void }) {
  const panels: Panel[] = ["queue", "lyrics"];

  return (
    <div style={{ display: "flex", padding: 2, borderRadius: 7, backgroundColor: colors.field }}>
      {panels.map((tab) => (
        <div
          key={tab}
          onClick={() => onPanel(tab)}
          style={{
            flexGrow: 1,
            display: "flex",
            justifyContent: "center",
            paddingTop: 4,
            paddingBottom: 4,
            borderRadius: 5,
            backgroundColor: tab === panel ? colors.track : undefined,
            cursor: "pointer",
          }}
        >
          <text style={{ color: tab === panel ? colors.text : colors.dim, fontSize: 12 }}>
            {panelTitles[tab]}
          </text>
        </div>
      ))}
    </div>
  );
}

function QueueRow({
  song,
  index,
  isCurrent,
  isPast,
}: {
  song: CatalogSong;
  index: number;
  isCurrent: boolean;
  isPast: boolean;
}) {
  const accent = useAccent();
  const artworkUrl = song.artwork ? toArtworkUrl(song.artwork, artworkSizePx * 2) : undefined;
  const background = isCurrent ? toAccentTint(accent) : undefined;

  return (
    <div
      style={{
        display: "flex",
        alignItems: "center",
        width: "100%",
        borderRadius: 6,
        backgroundColor: background,
        opacity: isPast ? 0.45 : 1,
      }}
    >
      <div
        onClick={() => playQueueAt(index)}
        style={{
          display: "flex",
          alignItems: "center",
          gap: 10,
          flexGrow: 1,
          minWidth: 0,
          padding: 5,
          cursor: "pointer",
        }}
      >
        <Artwork
          source={artworkUrl}
          widthPx={artworkSizePx}
          heightPx={artworkSizePx}
          radiusPx={4}
        />
        <div style={{ display: "flex", flexDirection: "column", flexGrow: 1, minWidth: 0 }}>
          <ScrollingText
            text={song.name}
            style={{ color: isCurrent ? accent : colors.text, fontSize: 12.5 }}
          />
          <ScrollingText text={song.artistName} style={{ color: colors.dim, fontSize: 11.5 }} />
        </div>
      </div>
      {!isCurrent && (
        <div
          onClick={() => removeFromQueue(index)}
          style={{ flexShrink: 0, paddingLeft: 8, paddingRight: 8, cursor: "pointer" }}
        >
          <text style={{ color: colors.faint, fontSize: 14 }}>×</text>
        </div>
      )}
    </div>
  );
}

function Heading({ text }: { text: string }) {
  return (
    <text
      style={{ color: colors.faint, fontSize: 12, fontWeight: 600, marginTop: 12, marginBottom: 4 }}
    >
      {text}
    </text>
  );
}

function UpNext() {
  const queue = useQueue();
  const [windowStart, setWindowStart] = useState(0);
  const firstInViewRef = useRef(0);

  if (queue.index < 0)
    return <PageStatus text="Play an album, a playlist or a song to fill the queue." />;

  const firstShownIndex = Math.max(0, queue.index - historyCount);
  const rowCount = queue.songs.length - firstShownIndex;
  const firstIndex = firstShownIndex + Math.min(windowStart, rowCount);
  const rows = queue.songs
    .slice(firstIndex, firstIndex + queueWindowCount)
    .map((song, offset) => ({ song, index: firstIndex + offset }));

  const moveWindow = (event: { startIndex?: number; endIndex?: number }): void => {
    const nextStart = toWindowStart(windowStart, event, queueWindowCount, firstInViewRef.current);

    firstInViewRef.current = Math.floor(event.startIndex ?? 0);

    if (nextStart !== windowStart) flushSync(() => setWindowStart(nextStart));
  };

  return (
    <virtual-list
      itemCount={rowCount}
      windowStart={Math.min(windowStart, rowCount)}
      estimatedItemHeight={queueRowHeightPx}
      onVisibleRange={moveWindow}
      style={{ flexGrow: 1, minHeight: 0 }}
    >
      {rows.map(({ song, index }) => (
        <div key={`${index}-${song.id}`} style={queueRowStyle}>
          {index === queue.index && <Heading text="Now Playing" />}
          {index === queue.index + 1 && <Heading text="Up Next" />}
          <QueueRow
            song={song}
            index={index}
            isCurrent={index === queue.index}
            isPast={index < queue.index}
          />
        </div>
      ))}
    </virtual-list>
  );
}

// The line being sung is the last one that has begun.
function findCurrentLineIndex(lines: LyricLine[], positionSeconds: number): number {
  let currentIndex = -1;

  for (const [index, line] of lines.entries()) {
    if (line.beginSeconds <= positionSeconds) currentIndex = index;
  }

  return currentIndex;
}

// A song started outside onlymuse has no catalog ID yet, so it is looked up by its name.
async function fetchPlayingLyrics(
  name: string,
  artist: string,
  album: string,
  persistentID: string
): Promise<LyricLine[]> {
  const song = findQueueSong(persistentID) ?? (await findCatalogSong(name, artist, album));

  return song ? fetchLyrics(song.id) : [];
}

// Every start of a line or a word, in order: the moments the lyrics change.
function toChangeTimes(lines: LyricLine[]): number[] {
  const times = lines.flatMap((line) => [
    line.beginSeconds,
    ...line.words.map((word) => word.beginSeconds),
    ...line.pronunciation.map((word) => word.beginSeconds),
  ]);

  return [...new Set(times)].sort((first, second) => first - second);
}

// The position, drawn again at each word's own start time: a timer waits for the next one, so the lyrics run on time.
function useLyricsPosition(lines: LyricLine[] | null, isPlaying: boolean): number {
  const [, setTickCount] = useState(0);
  const changeTimes = useMemo(() => toChangeTimes(lines ?? []), [lines]);
  const positionSeconds = readCurrentPositionSeconds();
  const nextChangeSeconds = changeTimes.find((seconds) => seconds > positionSeconds);

  useEffect(() => {
    if (!isPlaying || nextChangeSeconds === undefined) return;

    const waitMs = (nextChangeSeconds - readCurrentPositionSeconds()) * 1000 + lineSlackMs;
    const timer = setTimeout(
      () => {
        // How late the timer fired, past the word's start. A held-up main thread shows here.
        probe("lyricWord", {
          lateMs: Math.round((readCurrentPositionSeconds() - nextChangeSeconds) * 1000),
        });
        setTickCount((count) => count + 1);
      },
      Math.max(0, waitMs)
    );

    return () => clearTimeout(timer);
  });

  return positionSeconds;
}

type LineLook = { color: string; sungColor: string; fontSize: number; lineHeight: number };

// The words of a line in a wrapping row. The words already sung take sungColor.
function LyricWords({
  words,
  positionSeconds,
  look,
}: {
  words: LyricWord[];
  positionSeconds: number;
  look: LineLook;
}) {
  return (
    <div style={{ display: "flex", flexDirection: "row", flexWrap: "wrap" }}>
      {words.map((word, index) => (
        <text
          key={index}
          style={{
            color: word.beginSeconds <= positionSeconds ? look.sungColor : look.color,
            fontSize: look.fontSize,
            fontWeight: 700,
            lineHeight: look.lineHeight,
          }}
        >
          {word.text}
        </text>
      ))}
    </div>
  );
}

function Lyrics() {
  const { accent, nowPlaying } = useHelper();
  const song =
    nowPlaying.state === "playing" || nowPlaying.state === "paused" ? nowPlaying.song : null;
  const persistentID = song?.persistentID ?? "";

  const { value: lines, statusText } = useFetched(
    () =>
      song
        ? fetchPlayingLyrics(song.name, song.artist, song.album, persistentID)
        : Promise.resolve([]),
    [persistentID]
  );

  const positionSeconds = useLyricsPosition(lines, nowPlaying.state === "playing");

  if (!song) return <PageStatus text="Nothing is playing." />;
  if (!lines) return <PageStatus text={statusText} />;
  if (lines.length === 0) return <PageStatus text="Apple Music has no lyrics for this song." />;

  const currentIndex = findCurrentLineIndex(lines, positionSeconds);
  const firstShownIndex = Math.max(0, currentIndex - linesBeforeCurrent);
  const shownLines = lines.slice(firstShownIndex, firstShownIndex + shownLineCount);
  const currentLook = { color: colors.dim, sungColor: accent, fontSize: 19, lineHeight: 24 };
  const otherLook = { color: colors.faint, sungColor: colors.faint, fontSize: 16, lineHeight: 22 };

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 14, paddingTop: 10 }}>
      {shownLines.map((line, offset) => {
        const isCurrent = firstShownIndex + offset === currentIndex;
        const look = isCurrent ? currentLook : otherLook;
        const pronunciationLook = {
          ...look,
          fontSize: look.fontSize - 4,
          lineHeight: look.lineHeight - 6,
        };

        return (
          <div
            key={firstShownIndex + offset}
            style={{ display: "flex", flexDirection: "column", gap: 2 }}
          >
            <LyricWords words={line.words} positionSeconds={positionSeconds} look={look} />
            {line.pronunciation.length > 0 && (
              <LyricWords
                words={line.pronunciation}
                positionSeconds={positionSeconds}
                look={pronunciationLook}
              />
            )}
          </div>
        );
      })}
    </div>
  );
}

export function SidePanel({ panel, onPanel }: { panel: Panel; onPanel: (panel: Panel) => void }) {
  return (
    <div
      style={{
        width: panelWidthPx,
        flexShrink: 0,
        display: "flex",
        flexDirection: "column",
        gap: 6,
        padding: 16,
        borderLeftWidth: 1,
        borderColor: colors.line,
        backgroundColor: colors.player,
      }}
    >
      <Tabs panel={panel} onPanel={onPanel} />
      {panel === "queue" ? <UpNext /> : <Lyrics />}
    </div>
  );
}
