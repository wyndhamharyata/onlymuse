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

type ProbeRenderer = { takeProbeEvents?: () => number[] };

let probeRenderer: ProbeRenderer | null = null;
const round = (value: number): number => Math.round(value * 10) / 10;
const phases = ["started", "moved", "ended"];

// Every frame GPUI draws, and every scroll event with how long macOS held it before GPUI got it.
function readNativeEvents(): void {
  const flat = probeRenderer?.takeProbeEvents?.() ?? [];

  for (let index = 0; index + 5 < flat.length; index += 6) {
    const [atMs, kind, first, second, third, fourth] = flat.slice(index, index + 6);
    const fields =
      kind === 0
        ? {
            kind: fourth === 1 ? "presentOnly" : "frame",
            draw: round(first),
            present: round(second),
            drawableWait: round(third),
          }
        : {
            kind: "scroll",
            heldMs: round(first),
            dy: round(second),
            dx: round(third),
            phase: phases[fourth],
          };

    pending.push(JSON.stringify({ atMs: Math.round(atMs), ...fields }));
  }
}

// Lines are written in a batch every second, so the log itself costs no stall.
function writePending(): void {
  readNativeEvents();

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
      probeRenderer ??= this as ProbeRenderer;

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
