import { join } from "node:path";
import { useSyncExternalStore } from "react";
import { isText } from "./checks.ts";
import { readState, saveState } from "./store.ts";

export type Song = {
  name: string;
  artist: string;
  album: string;
  persistentID: string;
  durationSeconds: number;
  artworkPath?: string;
};

export type NowPlaying =
  | { state: "closed" }
  | { state: "stopped"; volumePercent: number }
  | { state: "playing" | "paused"; volumePercent: number; positionSeconds: number; song: Song };

export type Tokens = { developerToken: string; userToken: string };

// Each message the helper sends, as send() in helper/Sources/onlymuse-helper names it.
type Incoming =
  | ({ type: "nowPlaying" } & NowPlaying)
  | { type: "accent"; color: string }
  | ({ type: "tokens" } & Tokens)
  | { type: "signInNeeded" }
  | { type: "playSongResult"; requestId: number; persistentID: string | null }
  | { type: "error"; text: string };

// What the helper needs to find a catalog song in Music.app's library.
export type SongMatch = {
  name: string;
  artistName: string;
  albumName: string;
  durationSeconds: number;
};

// Each command the helper reads, as Command in helper/Sources/onlymuse-helper/Link.swift names it.
export type Outgoing =
  | { type: "playPause" | "next" | "previous" }
  | { type: "seek"; positionSeconds: number }
  | { type: "setVolume"; volumePercent: number }
  | { type: "refreshTokens" | "signIn" }
  | { type: "playSong"; requestId: number; song: SongMatch };

export type HelperState = {
  nowPlaying: NowPlaying;
  nowPlayingReceivedAtMs: number;
  accent: string;
  isSignInNeeded: boolean;
};

const helperPath = join(import.meta.dir, "..", "helper", ".build", "release", "onlymuse-helper");

const helper = Bun.spawn([helperPath], { stdin: "pipe", stdout: "pipe", stderr: "inherit" });
const listeners = new Set<() => void>();

let state: HelperState = {
  nowPlaying: { state: "closed" },
  nowPlayingReceivedAtMs: Date.now(),
  // The accent of the last run, so the first frame has the right colour before the helper answers.
  accent: readState("accent", isText, "#0A84FF"),
  isSignInNeeded: false,
};

let tokens: Tokens | null = null;
const tokenWaiters: ((tokens: Tokens) => void)[] = [];

let lastRequestId = 0;
const playSongWaiters = new Map<number, (persistentID: string | null) => void>();

function applyMessage(message: Incoming): void {
  if (message.type === "error") {
    console.error(`The helper reported an error. ${message.text}`);
    return;
  }

  if (message.type === "playSongResult") {
    playSongWaiters.get(message.requestId)?.(message.persistentID);
    playSongWaiters.delete(message.requestId);
    return;
  }

  if (message.type === "tokens") {
    tokens = { developerToken: message.developerToken, userToken: message.userToken };
    state = { ...state, isSignInNeeded: false };
    for (const resolve of tokenWaiters.splice(0)) resolve(tokens);
  }

  if (message.type === "signInNeeded") state = { ...state, isSignInNeeded: true };

  if (message.type === "accent") {
    state = { ...state, accent: message.color };
    saveState("accent", message.color);
  }

  if (message.type === "nowPlaying") {
    state = { ...state, nowPlaying: message, nowPlayingReceivedAtMs: Date.now() };
  }

  for (const listener of listeners) listener();
}

async function startReadingMessages(): Promise<void> {
  const decoder = new TextDecoder();
  let buffer = "";

  for await (const chunk of helper.stdout) {
    buffer += decoder.decode(chunk, { stream: true });

    const lines = buffer.split("\n");

    buffer = lines.pop() ?? "";
    for (const line of lines) applyMessage(JSON.parse(line) as Incoming);
  }
}

startReadingMessages();
process.on("exit", () => helper.kill());

export function sendToHelper(command: Outgoing): void {
  helper.stdin.write(JSON.stringify(command) + "\n");
  helper.stdin.flush();
}

// Waits for the helper when it has sent no tokens yet, or while it reads new ones.
export function readTokens(): Promise<Tokens> {
  if (tokens) return Promise.resolve(tokens);

  return new Promise((resolve) => tokenWaiters.push(resolve));
}

export function refreshTokens(): Promise<Tokens> {
  tokens = null;
  sendToHelper({ type: "refreshTokens" });

  return readTokens();
}

// Answers with the persistent ID of the song Music.app plays, or null when its library has no such song.
export function playSongInMusic(song: SongMatch): Promise<string | null> {
  lastRequestId += 1;

  const requestId = lastRequestId;

  sendToHelper({ type: "playSong", requestId, song });

  return new Promise((resolve) => playSongWaiters.set(requestId, resolve));
}

export function subscribeToHelper(listener: () => void): () => void {
  listeners.add(listener);

  return () => listeners.delete(listener);
}

export function readHelperState(): HelperState {
  return state;
}

export function useHelper(): HelperState {
  return useSyncExternalStore(subscribeToHelper, readHelperState);
}
