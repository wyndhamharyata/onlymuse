import type { EventPayload } from "@gpuix/react";
import { useSyncExternalStore } from "react";
import { readState, saveState } from "./store.ts";

// How far ahead of Music.app's position the lyrics run. Of the half second they sounded late, onlymuse made under 90 ms.
const defaultLeadMs = 500;
const stepMs = 50;
const maxLeadMs = 2000;
const stateKey = "lyricLeadMs";

const isLeadMs = (value: unknown): value is number =>
  typeof value === "number" && Math.abs(value) <= maxLeadMs;

let leadMs = readState(stateKey, isLeadMs, defaultLeadMs);
let changedAtMs = 0;
const listeners = new Set<() => void>();

export function readLyricLeadSeconds(): number {
  return leadMs / 1000;
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);

  return () => listeners.delete(listener);
}

// The lead, and when a key last changed it, so the panel can show the new value for a moment.
export function useLyricLead(): { leadMs: number; changedAtMs: number } {
  const current = useSyncExternalStore(subscribe, () => leadMs);

  return { leadMs: current, changedAtMs };
}

// Cmd ] runs the lyrics 50 ms earlier, Cmd [ 50 ms later.
export function leadOnKey(event: EventPayload): void {
  if (!event.modifiers?.cmd || (event.key !== "[" && event.key !== "]")) return;

  const next = leadMs + (event.key === "]" ? stepMs : -stepMs);

  if (!isLeadMs(next)) return;

  leadMs = next;
  changedAtMs = Date.now();
  saveState(stateKey, leadMs);

  for (const listener of listeners) listener();
}
