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
  | { type: "playSongResult" | "setNextResult"; requestId: number; persistentID: string | null }
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
  | { type: "refreshTokens" | "signIn" | "sendState" }
  | { type: "playSong"; requestId: number; song: SongMatch }
  | {
      type: "setNext";
      requestId: number;
      afterPersistentID: string | null;
      song: SongMatch | null;
    };

export type HelperState = {
  nowPlaying: NowPlaying;
  nowPlayingReceivedAtMs: number;
  accent: string;
  isSignInNeeded: boolean;
};

const helperPath = join(import.meta.dir, "..", "helper", ".build", "release", "onlymuse-helper");

type HelperProcess = Bun.Subprocess<"pipe", "pipe", "inherit">;
type SharedHelper = { process: HelperProcess; onMessage: (message: Incoming) => void };

// bun --hot runs every module again on a save. One helper outlives it, so a save starts no second one and pauses nothing.
const shared = globalThis as typeof globalThis & { onlymuseHelper?: SharedHelper };
const isReload = shared.onlymuseHelper !== undefined;

shared.onlymuseHelper ??= startHelper();

const helper = shared.onlymuseHelper.process;
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

  if (message.type === "playSongResult" || message.type === "setNextResult") {
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

// The reader hands each message to the onMessage of the code loaded last.
async function readMessages(helperProcess: HelperProcess): Promise<void> {
  const decoder = new TextDecoder();
  let buffer = "";

  for await (const chunk of helperProcess.stdout) {
    buffer += decoder.decode(chunk, { stream: true });

    const lines = buffer.split("\n");

    buffer = lines.pop() ?? "";
    for (const line of lines) shared.onlymuseHelper?.onMessage(JSON.parse(line) as Incoming);
  }
}

function startHelper(): SharedHelper {
  const helperProcess = Bun.spawn([helperPath], {
    stdin: "pipe",
    stdout: "pipe",
    stderr: "inherit",
  });

  readMessages(helperProcess);
  process.on("exit", () => helperProcess.kill());

  return { process: helperProcess, onMessage: () => {} };
}

shared.onlymuseHelper.onMessage = applyMessage;

// Reloaded code starts with empty state, so the helper sends again what it sent at its start.
if (isReload) {
  sendToHelper({ type: "sendState" });
  sendToHelper({ type: "refreshTokens" });
}

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

// The helper starts this song just before afterPersistentID ends, so Autoplay never plays. null: not in the library.
export function setNextInMusic(
  afterPersistentID: string | null,
  song: SongMatch | null
): Promise<string | null> {
  lastRequestId += 1;

  const requestId = lastRequestId;

  sendToHelper({ type: "setNext", requestId, afterPersistentID, song });

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

// One value of the state. A component re-renders when that value changes, not on every message.
export function useHelperValue<Value extends string | number | boolean>(
  select: (helper: HelperState) => Value
): Value {
  return useSyncExternalStore(subscribeToHelper, () => select(state));
}

export function useAccent(): string {
  return useHelperValue((helper) => helper.accent);
}
