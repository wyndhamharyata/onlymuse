import { useSyncExternalStore } from "react";
import { addToLibrary, type CatalogSong } from "./apple-music.ts";
import { hasNumber, hasText, isFields, isWholeNumberIn } from "./checks.ts";
import {
  playSongInMusic,
  readHelperState,
  sendToHelper,
  subscribeToHelper,
  type Song,
  type SongMatch,
} from "./helper.ts";
import { readState, saveState } from "./store.ts";

export type Repeat = "off" | "all" | "one";

export type QueueState = {
  songs: CatalogSong[];
  // The songs in the order they came, so shuffle can turn off again.
  originalSongs: CatalogSong[];
  index: number;
  isShuffled: boolean;
  repeat: Repeat;
  isAdding: boolean;
  playingPersistentID: string | null;
  // The last song Music.app played and where it was. The player shows it when Music.app has stopped.
  resumePoint: ResumePoint | null;
};

export type ResumePoint = { song: Song; positionSeconds: number };

// Where Music.app was in the song the queue plays, as of its last post.
type Tracking = {
  persistentID: string;
  durationSeconds: number;
  positionSeconds: number;
  receivedAtMs: number;
  isPlaying: boolean;
};

const addPollMs = 1500;
const addTimeoutMs = 45_000;
const endToleranceSeconds = 3;
// Previous starts the song again past this point, as Music.app does.
const restartAfterSeconds = 3;

const listeners = new Set<() => void>();

const stateKey = "queue";
// While a song plays, its position is saved this often, so a force quit loses at most this much.
const positionSaveMs = 5000;
const repeats = new Set<string>(["off", "all", "one"]);

function isCatalogSong(value: unknown): value is CatalogSong {
  if (!isFields(value)) return false;

  return (
    hasText(value, "id", "name", "artistName", "albumName") && hasNumber(value, "durationSeconds")
  );
}

function isSong(value: unknown): value is Song {
  if (!isFields(value)) return false;

  return (
    hasText(value, "name", "artist", "album", "persistentID") && hasNumber(value, "durationSeconds")
  );
}

function isResumePoint(value: unknown): value is ResumePoint {
  return isFields(value) && isSong(value.song) && hasNumber(value, "positionSeconds");
}

function isQueueState(value: unknown): value is QueueState {
  if (!isFields(value) || !Array.isArray(value.songs) || !Array.isArray(value.originalSongs))
    return false;

  const hasSongs = value.songs.every(isCatalogSong) && value.originalSongs.every(isCatalogSong);
  const hasIndex = isWholeNumberIn(value.index, -1, value.songs.length - 1);
  const hasSwitches = typeof value.isShuffled === "boolean" && repeats.has(String(value.repeat));
  const hasPlaying =
    value.playingPersistentID === null || typeof value.playingPersistentID === "string";
  const hasResumePoint = value.resumePoint === null || isResumePoint(value.resumePoint);

  return hasSongs && hasIndex && hasSwitches && hasPlaying && hasResumePoint;
}

const emptyState: QueueState = {
  songs: [],
  originalSongs: [],
  index: -1,
  isShuffled: false,
  repeat: "off",
  isAdding: false,
  playingPersistentID: null,
  resumePoint: null,
};

// A song that was being added when the app quit is not being added any more.
let state: QueueState = { ...readState(stateKey, isQueueState, emptyState), isAdding: false };
let tracking: Tracking | null = null;
// Each new play counts up, so an older play that is still adding a song knows to stop.
let playCount = 0;

function setState(changes: Partial<QueueState>): void {
  state = { ...state, ...changes };
  saveState(stateKey, state);
  for (const listener of listeners) listener();
}

function toSongMatch(song: CatalogSong): SongMatch {
  return {
    name: song.name,
    artistName: song.artistName,
    albumName: song.albumName,
    durationSeconds: song.durationSeconds,
  };
}

// Music.app shows a song added to the library after a few seconds, about 6 in the tests.
async function waitForSongInMusic(song: CatalogSong, count: number): Promise<string | null> {
  const deadlineMs = Date.now() + addTimeoutMs;

  while (Date.now() < deadlineMs && count === playCount) {
    await Bun.sleep(addPollMs);

    const persistentID = await playSongInMusic(toSongMatch(song));

    if (persistentID) return persistentID;
  }

  return null;
}

async function playAt(index: number): Promise<void> {
  playCount += 1;

  const count = playCount;
  const song = state.songs[index];

  setState({ index, isAdding: false, playingPersistentID: null });

  const persistentID = await playSongInMusic(toSongMatch(song));

  if (count !== playCount) return;
  if (persistentID) return setState({ playingPersistentID: persistentID });

  setState({ isAdding: true });
  await addToLibrary("songs", song.id);

  const addedPersistentID = await waitForSongInMusic(song, count);

  if (count !== playCount) return;
  if (!addedPersistentID) console.error(`${song.name} did not reach the library of Music.app.`);

  setState({ isAdding: false, playingPersistentID: addedPersistentID });
}

function toShuffled(songs: CatalogSong[]): CatalogSong[] {
  const shuffled = [...songs];

  // Fisher-Yates shuffle: https://en.wikipedia.org/wiki/Fisher%E2%80%93Yates_shuffle
  for (let last = shuffled.length - 1; last > 0; last -= 1) {
    const pick = Math.floor(Math.random() * (last + 1));

    [shuffled[last], shuffled[pick]] = [shuffled[pick], shuffled[last]];
  }

  return shuffled;
}

// With shuffle on, the chosen song plays first and the others follow in a random order.
function toPlayOrder(songs: CatalogSong[], first: CatalogSong): CatalogSong[] {
  const others = songs.filter((song) => song !== first);

  return [first, ...toShuffled(others)];
}

export function playSongs(songs: CatalogSong[], index: number): void {
  if (!state.isShuffled) {
    setState({ songs, originalSongs: songs });
    return void playAt(index);
  }

  setState({ songs: toPlayOrder(songs, songs[index]), originalSongs: songs });
  playAt(0);
}

export function shuffleSongs(songs: CatalogSong[]): void {
  setState({ songs: toShuffled(songs), originalSongs: songs, isShuffled: true });
  playAt(0);
}

export function playQueueAt(index: number): void {
  playAt(index);
}

export function removeFromQueue(index: number): void {
  if (index === state.index) return;

  const removed = state.songs[index];
  const songs = state.songs.filter((_, songIndex) => songIndex !== index);
  const originalSongs = state.originalSongs.filter((song) => song !== removed);

  setState({ songs, originalSongs, index: index < state.index ? state.index - 1 : state.index });
}

export function toggleShuffle(): void {
  const current = state.songs[state.index];

  if (!current) return setState({ isShuffled: !state.isShuffled });

  if (state.isShuffled) {
    const songs = state.originalSongs;

    return setState({ songs, index: songs.indexOf(current), isShuffled: false });
  }

  setState({ songs: toPlayOrder(state.originalSongs, current), index: 0, isShuffled: true });
}

const nextRepeat: Record<Repeat, Repeat> = { off: "all", all: "one", one: "off" };

export function cycleRepeat(): void {
  setState({ repeat: nextRepeat[state.repeat] });
}

// Repeat all goes from the last song back to the first. null when the queue is over.
function findNextIndex(): number | null {
  if (state.index + 1 < state.songs.length) return state.index + 1;

  return state.repeat === "all" && state.songs.length > 0 ? 0 : null;
}

// The queue leads only while Music.app plays the song it started. Otherwise Music.app's own order applies.
function isQueueLeading(): boolean {
  const nowPlaying = readHelperState().nowPlaying;
  const hasSong = nowPlaying.state === "playing" || nowPlaying.state === "paused";
  const playingID = hasSong ? nowPlaying.song.persistentID : null;

  return state.isAdding || (playingID !== null && playingID === state.playingPersistentID);
}

export function skipToNext(): void {
  const nextIndex = findNextIndex();

  if (!isQueueLeading()) return sendToHelper({ type: "next" });
  if (nextIndex !== null) playAt(nextIndex);
}

export function skipToPrevious(positionSeconds: number): void {
  const canRestart = positionSeconds > restartAfterSeconds || state.index === 0;

  if (!isQueueLeading()) return sendToHelper({ type: "previous" });
  if (canRestart) return sendToHelper({ type: "seek", positionSeconds: 0 });

  playAt(state.index - 1);
}

export function findQueueSong(persistentID: string): CatalogSong | null {
  const isCurrent = persistentID === state.playingPersistentID;

  return isCurrent ? state.songs[state.index] : null;
}

function toEstimateSeconds(current: Tracking, nowMs: number): number {
  if (!current.isPlaying) return current.positionSeconds;

  return current.positionSeconds + (nowMs - current.receivedAtMs) / 1000;
}

// At a song's end Music.app posts Paused, then Stopped. The paused position it posts may be 0.
function applyNowPlaying(): void {
  const nowPlaying = readHelperState().nowPlaying;
  const nowMs = Date.now();

  if (nowPlaying.state === "playing" || nowPlaying.state === "paused") {
    const isSameSong = tracking?.persistentID === nowPlaying.song.persistentID;
    const estimateSeconds = tracking && isSameSong ? toEstimateSeconds(tracking, nowMs) : 0;
    const isPaused = nowPlaying.state === "paused";
    const pausedSeconds = Math.max(nowPlaying.positionSeconds, estimateSeconds);

    tracking = {
      persistentID: nowPlaying.song.persistentID,
      durationSeconds: nowPlaying.song.durationSeconds,
      positionSeconds: isPaused ? pausedSeconds : nowPlaying.positionSeconds,
      receivedAtMs: nowMs,
      isPlaying: !isPaused,
    };
    return;
  }

  const finished = tracking;
  const isQueueSong = finished?.persistentID === state.playingPersistentID;
  const endSeconds = (finished?.durationSeconds ?? 0) - endToleranceSeconds;
  const hasEnded = finished !== null && toEstimateSeconds(finished, nowMs) >= endSeconds;
  const nextIndex = state.repeat === "one" ? state.index : findNextIndex();

  const resumePoint = state.resumePoint;

  tracking = null;
  if (hasEnded && resumePoint) setState({ resumePoint: { ...resumePoint, positionSeconds: 0 } });
  if (isQueueSong && hasEnded && nextIndex !== null) playAt(nextIndex);
}

// Keeps the resume point on each post from Music.app, and every few seconds while a song plays.
function applyResumePoint(): void {
  const nowPlaying = readHelperState().nowPlaying;
  const hasSong = nowPlaying.state === "playing" || nowPlaying.state === "paused";

  if (!hasSong || !tracking) return;

  const resumePoint = {
    song: nowPlaying.song,
    positionSeconds: toEstimateSeconds(tracking, Date.now()),
  };
  const isSameSong = state.resumePoint?.song.persistentID === nowPlaying.song.persistentID;

  if (isSameSong) {
    state = { ...state, resumePoint };
    return saveState(stateKey, state);
  }

  setState({ resumePoint });
}

// Plays the last song again from where it was. Music.app may have quit or stopped since.
export async function resumeLastSong(): Promise<void> {
  const resumePoint = state.resumePoint;

  if (!resumePoint) return;

  const song = resumePoint.song;
  const isQueueSong = song.persistentID === state.playingPersistentID;
  const match = {
    name: song.name,
    artistName: song.artist,
    albumName: song.album,
    durationSeconds: song.durationSeconds,
  };

  playCount += 1;

  const persistentID = await playSongInMusic(match);

  if (!persistentID) return;
  if (isQueueSong) setState({ playingPersistentID: persistentID });

  sendToHelper({ type: "seek", positionSeconds: resumePoint.positionSeconds });
}

subscribeToHelper(() => {
  applyNowPlaying();
  applyResumePoint();
});
setInterval(applyResumePoint, positionSaveMs);

function subscribe(listener: () => void): () => void {
  listeners.add(listener);

  return () => listeners.delete(listener);
}

export function useQueue(): QueueState {
  return useSyncExternalStore(subscribe, () => state);
}
