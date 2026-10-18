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

let stallsMs: number[] = [];

function startStallProbe(): void {
  let expectedMs = performance.now() + probeMs;

  setInterval(() => {
    const nowMs = performance.now();

    stallsMs.push(Math.max(0, nowMs - expectedMs));
    expectedMs = nowMs + probeMs;
  }, probeMs);
}

function toPercentile(sortedMs: number[], share: number): number {
  return sortedMs[Math.min(sortedMs.length - 1, Math.floor(sortedMs.length * share))] ?? 0;
}

function readStalls(): { p99Ms: number; maxMs: number; missedFrames: number; blockedMs: number } {
  const sortedMs = [...stallsMs].sort((left, right) => left - right);
  const longStallsMs = sortedMs.filter((stallMs) => stallMs > frameBudgetMs);

  return {
    p99Ms: toPercentile(sortedMs, 0.99),
    maxMs: sortedMs.at(-1) ?? 0,
    missedFrames: longStallsMs.reduce(
      (count, stallMs) => count + Math.floor(stallMs / frameBudgetMs),
      0
    ),
    blockedMs: Math.round(longStallsMs.reduce((total, stallMs) => total + stallMs, 0)),
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
        stallsMs = [];
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
