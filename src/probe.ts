import { GpuixRenderer } from "@gpuix/native";
import { appendFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// ONLYMUSE_PROBE=1 logs what the app does, so a lag shows its cause. Cmd Shift L marks one for scripts/probe-report.ts.
const logFolder = join(homedir(), "Library", "Logs", "onlymuse");

export const probeLogPath = join(logFolder, "probe.log");
export const isProbing = process.env.ONLYMUSE_PROBE === "1";

// The main thread is asked to wake every 4 ms. A wake later than this is a stall, and a frame at 120 Hz missed.
const probeMs = 4;
const stallMs = 12;
// Native calls and saves shorter than these are left out of the log.
const slowNativeMs = 8;
const slowSaveMs = 2;

let pending: string[] = [];

export function probe(kind: string, fields: Record<string, unknown> = {}): void {
  if (!isProbing) return;

  pending.push(JSON.stringify({ atMs: Date.now(), kind, ...fields }));
}

type FrameRenderer = { takeSlowFrames?: () => number[] };

let frameRenderer: FrameRenderer | null = null;

// A slow frame in two halves: draw builds and paints it, present waits for macOS, which the blur can slow.
function readSlowFrames(): void {
  const flat = frameRenderer?.takeSlowFrames?.() ?? [];

  for (let index = 0; index + 2 < flat.length; index += 3) {
    const round = (ms: number): number => Math.round(ms * 10) / 10;

    pending.push(
      JSON.stringify({
        atMs: Math.round(flat[index]),
        kind: "frame",
        draw: round(flat[index + 1]),
        present: round(flat[index + 2]),
      })
    );
  }
}

// Lines are written in a batch every second, so the log itself costs no stall.
function writePending(): void {
  readSlowFrames();

  if (pending.length === 0) return;

  appendFileSync(probeLogPath, `${pending.join("\n")}\n`);
  pending = [];
}

// Times a function and logs it when it takes over minMs.
export function probeTimed<Value>(
  kind: string,
  minMs: number,
  fields: Record<string, unknown>,
  run: () => Value
): Value {
  if (!isProbing) return run();

  const startMs = performance.now();
  const value = run();
  const durationMs = performance.now() - startMs;

  if (durationMs >= minMs) probe(kind, { ...fields, ms: Math.round(durationMs * 10) / 10 });

  return value;
}

export const slowSaveThresholdMs = slowSaveMs;

// Cmd Shift L marks a lag in the log, at the moment the user felt it.
export function markOnKey(event: {
  key?: string;
  modifiers?: { cmd: boolean; shift: boolean };
}): void {
  if (event.modifiers?.cmd && event.modifiers.shift && event.key?.toLowerCase() === "l")
    probe("mark");
}

function startStallProbe(): void {
  let expectedMs = performance.now() + probeMs;

  setInterval(() => {
    const nowMs = performance.now();
    const lateMs = nowMs - expectedMs;

    if (lateMs > stallMs) probe("stall", { ms: Math.round(lateMs) });

    expectedMs = nowMs + probeMs;
  }, probeMs);
}

// A batch is one React commit sent to gpuix, and its size is the length of its JSON. A tick pumps events and draws.
function probeNativeCalls(): void {
  const prototype = GpuixRenderer.prototype as unknown as Record<
    string,
    (...args: unknown[]) => unknown
  >;

  for (const name of ["applyBatch", "tick"]) {
    const call = prototype[name];

    prototype[name] = function (this: unknown, ...args: unknown[]): unknown {
      frameRenderer ??= this as FrameRenderer;

      const startMs = performance.now();
      const result = call.apply(this, args);
      const durationMs = performance.now() - startMs;

      if (durationMs >= slowNativeMs) {
        const size = typeof args[0] === "string" ? args[0].length : undefined;

        probe(name, { ms: Math.round(durationMs * 10) / 10, size });
      }

      return result;
    };
  }
}

if (isProbing) {
  mkdirSync(logFolder, { recursive: true });
  probe("start");
  probeNativeCalls();
  startStallProbe();
  setInterval(writePending, 1000);
  process.on("exit", writePending);
}
