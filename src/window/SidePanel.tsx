import { useState } from "react";
import {
  fetchLyrics,
  findCatalogSong,
  toArtworkUrl,
  type CatalogSong,
  type LyricLine,
} from "../apple-music.ts";
import { useAccent, useHelper } from "../helper.ts";
import { usePositionSeconds } from "../position.ts";
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
const queueWindowCount = 32;
const queueRowHeightPx = 48;
// One object for every row, so a render of Up Next sends no style that did not change.
const queueRowStyle = { display: "flex", flexDirection: "column", width: "100%" } as const;
const linesBeforeCurrent = 3;
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

  if (queue.index < 0)
    return <PageStatus text="Play an album, a playlist or a song to fill the queue." />;

  const firstShownIndex = Math.max(0, queue.index - historyCount);
  const rowCount = queue.songs.length - firstShownIndex;
  const firstIndex = firstShownIndex + Math.min(windowStart, rowCount);
  const rows = queue.songs
    .slice(firstIndex, firstIndex + queueWindowCount)
    .map((song, offset) => ({ song, index: firstIndex + offset }));

  const moveWindow = (event: { startIndex?: number; endIndex?: number }): void => {
    const nextStart = toWindowStart(windowStart, event, queueWindowCount);

    if (nextStart !== windowStart) setWindowStart(nextStart);
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

function Lyrics() {
  const { accent, nowPlaying } = useHelper();
  const positionSeconds = usePositionSeconds();
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

  if (!song) return <PageStatus text="Nothing is playing." />;
  if (!lines) return <PageStatus text={statusText} />;
  if (lines.length === 0) return <PageStatus text="Apple Music has no lyrics for this song." />;

  const currentIndex = findCurrentLineIndex(lines, positionSeconds);
  const firstShownIndex = Math.max(0, currentIndex - linesBeforeCurrent);
  const shownLines = lines.slice(firstShownIndex, firstShownIndex + shownLineCount);

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 14, paddingTop: 10 }}>
      {shownLines.map((line, offset) => {
        const isCurrent = firstShownIndex + offset === currentIndex;

        return (
          <text
            key={firstShownIndex + offset}
            style={{
              color: isCurrent ? accent : colors.faint,
              fontSize: isCurrent ? 19 : 16,
              fontWeight: 700,
              lineHeight: 24,
            }}
          >
            {line.text}
          </text>
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
