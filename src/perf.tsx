import { useEffect, type ReactNode } from "react";
import { useGpuixRequired } from "@gpuix/react";
import { existsSync, unlinkSync } from "node:fs";

// With ONLYMUSE_PERF set to a file, the app writes its stalls and draw times there. A ".reset" file next to it starts again.
const reportPath = process.env.ONLYMUSE_PERF;
const reportMs = 250;
// The main thread is asked to wake every 4 ms. Each late wake is time JavaScript held the thread, and no frame could start.
const probeMs = 4;
// A stall past this misses a frame at 120 Hz.
const frameBudgetMs = 8.3;

export const isMeasuring = reportPath !== undefined;

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
      }

      const report = {
        frames: renderer.getDebugFrameOverlayStats?.(),
        stalls: readStalls(),
        rssMb: Math.round(process.memoryUsage().rss / 1_048_576),
        canReset: typeof renderer.resetDebugFrameOverlayStats === "function",
      };

      Bun.write(reportPath ?? "", JSON.stringify(report));
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
