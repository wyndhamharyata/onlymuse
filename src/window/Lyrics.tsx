import { motion, useGpuixRequired, type PublicInstance } from "@gpuix/react";
import { useEffect, useMemo, useRef, useState } from "react";
import { fetchLyrics, findCatalogSong, type LyricLine, type LyricWord } from "../apple-music.ts";
import { useHelper } from "../helper.ts";
import { readLyricLeadSeconds, useLyricLead } from "../lyric-lead.ts";
import { readCurrentPositionSeconds } from "../position.ts";
import { probe } from "../probe.ts";
import { findQueueSong } from "../queue.ts";
import { colors } from "../theme.ts";
import { PageStatus, useFetched } from "./Fetched.tsx";

const linesBeforeCurrent = 3;
// The timer for the next word fires this much after its start, so a word is never a hair early.
const lineSlackMs = 5;
const shownLineCount = 14;
const lineGapPx = 14;
// Font sizes do not animate, so every line has one size and the current line shows by brightness.
const otherLineOpacity = 0.7;
const wordFade = { duration: 0.15, ease: "easeOut" } as const;
const lineFade = { duration: 0.3, ease: "easeOut" } as const;
const slide = { duration: 0.35, ease: "easeOut" } as const;

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

// The lyrics run this far ahead of Music.app's position.
function readLyricsSeconds(): number {
  return readCurrentPositionSeconds() + readLyricLeadSeconds();
}

// The position, drawn again at each word's own start time: a timer waits for the next one, so the lyrics run on time.
function useLyricsPosition(lines: LyricLine[] | null, isPlaying: boolean): number {
  const [, setTickCount] = useState(0);

  useLyricLead();

  const changeTimes = useMemo(() => toChangeTimes(lines ?? []), [lines]);
  const positionSeconds = readLyricsSeconds();
  const nextChangeSeconds = changeTimes.find((seconds) => seconds > positionSeconds);

  useEffect(() => {
    if (!isPlaying || nextChangeSeconds === undefined) return;

    const waitMs = (nextChangeSeconds - readLyricsSeconds()) * 1000 + lineSlackMs;
    const timer = setTimeout(
      () => {
        // How late the timer fired, past the word's start. A held-up main thread shows here.
        probe("lyricWord", {
          lateMs: Math.round((readLyricsSeconds() - nextChangeSeconds) * 1000),
        });
        setTickCount((count) => count + 1);
      },
      Math.max(0, waitMs)
    );

    return () => clearTimeout(timer);
  });

  return positionSeconds;
}

const leadShownMs = 2000;

// After Cmd [ or Cmd ], the new lead for a moment, so the change can be heard against a number.
function LeadNote() {
  const { leadMs, changedAtMs } = useLyricLead();
  const [, setTickCount] = useState(0);
  const leftMs = changedAtMs + leadShownMs - Date.now();

  useEffect(() => {
    if (leftMs <= 0) return;

    const timer = setTimeout(() => setTickCount((count) => count + 1), leftMs);

    return () => clearTimeout(timer);
  });

  if (leftMs <= 0) return null;

  // It lies over the lyrics, so its coming and going moves no line.
  return (
    <div
      style={{
        position: "absolute",
        top: 0,
        left: 0,
        right: 0,
        padding: 8,
        borderRadius: 8,
        backgroundColor: colors.card,
      }}
    >
      <text style={{ color: colors.text, fontSize: 12 }}>
        {`Lyrics ${(leadMs / 1000).toFixed(2)} s ahead of Music.app. Cmd [ and Cmd ] change it.`}
      </text>
    </div>
  );
}

type LineLook = { fontSize: number; lineHeight: number };

const lineLook: LineLook = { fontSize: 18, lineHeight: 24 };
const pronunciationLook: LineLook = { fontSize: 14, lineHeight: 18 };

// What a line showed in the last render, so a line mounted again starts from it and moves on.
type Shown = { currentIndex: number; positionSeconds: number };

type WordsProps = {
  words: LyricWord[];
  look: LineLook;
  accent: string;
  isLit: (word: LyricWord) => boolean;
  wasLit: (word: LyricWord) => boolean;
  hasOverlay: boolean;
};

// The words of a line in a wrapping row. A lit copy of each word lies over it and fades in as it is sung.
function LyricWords({ words, look, accent, isLit, wasLit, hasOverlay }: WordsProps) {
  const textStyle = { fontSize: look.fontSize, fontWeight: 700, lineHeight: look.lineHeight };

  return (
    <div style={{ display: "flex", flexDirection: "row", flexWrap: "wrap" }}>
      {words.map((word, index) => (
        // A line timed only by line is one word, which must shrink to wrap in the panel.
        <div key={index} style={{ position: "relative", flexShrink: 1, minWidth: 0 }}>
          <text style={{ ...textStyle, color: colors.dim }}>{word.text}</text>
          {hasOverlay && (
            <motion.div
              initial={{ opacity: wasLit(word) ? 1 : 0 }}
              animate={{ opacity: isLit(word) ? 1 : 0 }}
              transition={wordFade}
              style={{ position: "absolute", top: 0, left: 0, right: 0, bottom: 0 }}
            >
              <text style={{ ...textStyle, color: accent }}>{word.text}</text>
            </motion.div>
          )}
        </div>
      ))}
    </div>
  );
}

// How far the rows moved up since the last paint: the top of the new first row less the top of the old one.
function readSlidePx(
  rows: Map<number, PublicInstance>,
  readBounds: (id: number) => { y: number } | null | undefined,
  fromIndex: number,
  toIndex: number
): number {
  const from = rows.get(fromIndex);
  const to = rows.get(toIndex);
  const fromBounds = from && readBounds(from.id);
  const toBounds = to && readBounds(to.id);

  return fromBounds && toBounds ? toBounds.y - fromBounds.y : 0;
}

export function Lyrics() {
  const renderer = useGpuixRequired();
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
  const currentIndex = lines ? findCurrentLineIndex(lines, positionSeconds) : -1;
  const firstShownIndex = Math.max(0, currentIndex - linesBeforeCurrent);
  const rowsRef = useRef(new Map<number, PublicInstance>());
  const shownRef = useRef<Shown>({ currentIndex, positionSeconds });
  const slideRef = useRef({ firstShownIndex, slidePx: 0 });

  // One line on: the rows slide up by the height of the top line, which fades out as it goes.
  if (slideRef.current.firstShownIndex !== firstShownIndex) {
    const isOneOn = firstShownIndex === slideRef.current.firstShownIndex + 1;
    const readBounds = (id: number) => renderer.getElementBounds?.(id);
    const slidePx = isOneOn
      ? readSlidePx(rowsRef.current, readBounds, firstShownIndex - 1, firstShownIndex)
      : 0;

    slideRef.current = { firstShownIndex, slidePx };
  }

  useEffect(() => {
    shownRef.current = { currentIndex, positionSeconds };
  });

  if (!song) return <PageStatus text="Nothing is playing." />;
  if (!lines) return <PageStatus text={statusText} />;
  if (lines.length === 0) return <PageStatus text="Apple Music has no lyrics for this song." />;

  const { slidePx } = slideRef.current;
  const leavingCount = slidePx > 0 ? 1 : 0;
  const startIndex = firstShownIndex - leavingCount;
  const shownLines = lines.slice(startIndex, firstShownIndex + shownLineCount);
  const shown = shownRef.current;

  return (
    // It takes the panel's height under the tabs and clips there, so no line draws over the player bar.
    <div
      style={{
        position: "relative",
        display: "flex",
        flexDirection: "column",
        flexGrow: 1,
        minHeight: 0,
        overflow: "hidden",
        paddingTop: 10,
      }}
    >
      <div style={{ overflow: "hidden", flexGrow: 1, minHeight: 0 }}>
        <motion.div
          key={firstShownIndex}
          initial={{ top: 0 }}
          animate={{ top: -slidePx }}
          transition={slide}
          style={{ position: "relative", display: "flex", flexDirection: "column", gap: lineGapPx }}
        >
          {shownLines.map((line, offset) => {
            const index = startIndex + offset;
            const isCurrent = index === currentIndex;
            const wasCurrent = index === shown.currentIndex;
            const isLeaving = index < firstShownIndex;
            const toOpacity = (current: boolean): number => (current ? 1 : otherLineOpacity);
            const wordsProps = {
              accent,
              isLit: (word: LyricWord) => isCurrent && word.beginSeconds <= positionSeconds,
              wasLit: (word: LyricWord) => wasCurrent && word.beginSeconds <= shown.positionSeconds,
              hasOverlay: isCurrent || wasCurrent || index === currentIndex - 1,
            };

            return (
              <motion.div
                key={index}
                ref={(row: PublicInstance | null) => {
                  if (row) rowsRef.current.set(index, row);
                  else rowsRef.current.delete(index);
                }}
                initial={{ opacity: toOpacity(wasCurrent) }}
                animate={{ opacity: isLeaving ? 0 : toOpacity(isCurrent) }}
                transition={lineFade}
                style={{ display: "flex", flexDirection: "column", gap: 2 }}
              >
                <LyricWords words={line.words} look={lineLook} {...wordsProps} />
                {line.pronunciation.length > 0 && (
                  <LyricWords words={line.pronunciation} look={pronunciationLook} {...wordsProps} />
                )}
              </motion.div>
            );
          })}
        </motion.div>
      </div>
      <LeadNote />
    </div>
  );
}
