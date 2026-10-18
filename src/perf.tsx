import { useEffect, type ReactNode } from "react";
import { useGpuixRequired } from "@gpuix/react";
import { GpuixRenderer } from "@gpuix/native";
import { existsSync, unlinkSync, writeFileSync } from "node:fs";

// With ONLYMUSE_PERF set to a file, the app writes its stalls and draw times there. A ".reset" file next to it starts again.
const reportPath = process.env.ONLYMUSE_PERF;
const reportMs = 250;
// The main thread is asked to wake every 4 ms. Each late wake is time JavaScript held the thread, and no frame could start.
const probeMs = 4;
// A stall past this misses a frame at 120 Hz.
const frameBudgetMs = 8.3;

export const isMeasuring = reportPath !== undefined;

// How often a list showed a row that React had not mounted, which draws as an empty box.
let unmountedViews = { events: 0, rows: 0 };

export function countUnmountedRows(rowCount: number): void {
  unmountedViews = { events: unmountedViews.events + 1, rows: unmountedViews.rows + rowCount };
}

// Bun writes a --cpu-prof profile on a normal exit only, and the automation stops the app with SIGTERM.
if (isMeasuring) process.on("SIGTERM", () => process.exit(0));

// Counts per 0.25 ms of stall, so a report reads a percentile without sorting every wake.
const bucketMs = 0.25;
const bucketCount = 400;

type Stalls = {
  buckets: number[];
  wakeCount: number;
  maxMs: number;
  missedFrames: number;
  blockedMs: number;
};

const toEmptyStalls = (): Stalls => ({
  buckets: Array.from({ length: bucketCount }, () => 0),
  wakeCount: 0,
  maxMs: 0,
  missedFrames: 0,
  blockedMs: 0,
});

let stalls = toEmptyStalls();

type NativeCalls = { count: number; totalMs: number; maxMs: number };

const toEmptyCalls = (): NativeCalls => ({ count: 0, totalMs: 0, maxMs: 0 });

// The time inside gpuix's native calls: a batch applies React's changes, a tick pumps events and draws.
let nativeCalls: Record<"applyBatch" | "tick", NativeCalls> = {
  applyBatch: toEmptyCalls(),
  tick: toEmptyCalls(),
};

function timeNativeCall(name: "applyBatch" | "tick"): void {
  const prototype = GpuixRenderer.prototype as unknown as Record<
    string,
    (...args: unknown[]) => unknown
  >;
  const call = prototype[name];

  prototype[name] = function (this: unknown, ...args: unknown[]): unknown {
    const startMs = performance.now();
    const result = call.apply(this, args);
    const durationMs = performance.now() - startMs;
    const calls = nativeCalls[name];

    calls.count += 1;
    calls.totalMs += durationMs;
    calls.maxMs = Math.max(calls.maxMs, durationMs);

    return result;
  };
}

if (isMeasuring) {
  timeNativeCall("applyBatch");
  timeNativeCall("tick");
}

function countStall(stallMs: number): void {
  stalls.buckets[Math.min(bucketCount - 1, Math.floor(stallMs / bucketMs))] += 1;
  stalls.wakeCount += 1;
  stalls.maxMs = Math.max(stalls.maxMs, stallMs);

  if (stallMs <= frameBudgetMs) return;

  stalls.missedFrames += Math.floor(stallMs / frameBudgetMs);
  stalls.blockedMs += stallMs;
}

function startStallProbe(): void {
  let expectedMs = performance.now() + probeMs;

  setInterval(() => {
    const nowMs = performance.now();

    countStall(Math.max(0, nowMs - expectedMs));
    expectedMs = nowMs + probeMs;
  }, probeMs);
}

function readP99Ms(): number {
  const wanted = stalls.wakeCount * 0.99;
  let seen = 0;

  for (const [index, count] of stalls.buckets.entries()) {
    seen += count;

    if (seen >= wanted) return (index + 1) * bucketMs;
  }

  return stalls.maxMs;
}

function readStalls(): { p99Ms: number; maxMs: number; missedFrames: number; blockedMs: number } {
  return {
    p99Ms: readP99Ms(),
    maxMs: stalls.maxMs,
    missedFrames: stalls.missedFrames,
    blockedMs: Math.round(stalls.blockedMs),
  };
}

function Reporter() {
  const renderer = useGpuixRequired();

  useEffect(() => {
    const resetPath = `${reportPath}.reset`;

    startStallProbe();

    const timer = setInterval(() => {
      if (existsSync(resetPath)) {
        unlinkSync(resetPath);
        renderer.resetDebugFrameOverlayStats?.();
        stalls = toEmptyStalls();
        nativeCalls = { applyBatch: toEmptyCalls(), tick: toEmptyCalls() };
        unmountedViews = { events: 0, rows: 0 };
      }

      const report = {
        frames: renderer.getDebugFrameOverlayStats?.(),
        stalls: readStalls(),
        nativeCalls,
        unmountedViews,
        rssMb: Math.round(process.memoryUsage().rss / 1_048_576),
        canReset: typeof renderer.resetDebugFrameOverlayStats === "function",
      };

      writeFileSync(reportPath ?? "", JSON.stringify(report));
    }, reportMs);

    return () => clearInterval(timer);
  }, [renderer]);

  return null;
}

export function Measured({ children }: { children: ReactNode }) {
  if (!isMeasuring) return children;

  return (
    <>
      {children}
      <Reporter />
    </>
  );
}
