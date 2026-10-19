import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// Prints what the app did around each mark in the probe's log. usage: bun scripts/probe-report.ts [seconds before]
const logPath = join(homedir(), "Library", "Logs", "onlymuse", "probe.log");
const beforeMs = Number(process.argv[2] ?? 3) * 1000;
const afterMs = 500;

type Line = { atMs: number; kind: string } & Record<string, unknown>;

if (!existsSync(logPath)) {
  console.error(`No log at ${logPath}. Start the app with ONLYMUSE_PROBE=1 bun run dev.`);
  process.exit(1);
}

const lines = readFileSync(logPath, "utf8")
  .split("\n")
  .filter((text) => text.length > 0)
  .map((text) => JSON.parse(text) as Line);
const marks = lines.filter((line) => line.kind === "mark");

function toText(line: Line, markAtMs: number): string {
  const { atMs, kind, ...fields } = line;
  const offsetText = `${atMs - markAtMs >= 0 ? "+" : ""}${atMs - markAtMs} ms`.padStart(10);
  const fieldText = Object.entries(fields)
    .map(([key, value]) => `${key}=${typeof value === "string" ? value : JSON.stringify(value)}`)
    .join(" ");

  return `${offsetText}  ${kind.padEnd(14)}${fieldText}`;
}

if (marks.length === 0) console.log("No marks yet. Press Cmd Shift L in the app when it lags.");

const bucketMs = 50;

// Frames and scroll events in one line per 50 ms: a stretch of scroll events with no frames, or held long, shows a hold-up.
function toBucketText(bucket: Line[], startMs: number, markAtMs: number): string {
  const frames = bucket.filter((line) => line.kind === "frame");
  const scrolls = bucket.filter((line) => line.kind === "scroll");
  const sum = (items: Line[], key: string): number =>
    items.reduce((total, line) => total + Number(line[key]), 0);
  const max = (items: Line[], key: string): number =>
    Math.max(0, ...items.map((line) => Number(line[key])));
  const offsetText = `${startMs - markAtMs >= 0 ? "+" : ""}${startMs - markAtMs} ms`.padStart(10);
  const scrollText = scrolls.length
    ? `scroll ${String(scrolls.length).padStart(2)} dy=${sum(scrolls, "dy").toFixed(0).padStart(5)} held max ${max(scrolls, "heldMs").toFixed(0)} ms`
    : "scroll  -";
  const frameText = frames.length
    ? `frames ${frames.length} draw max ${max(frames, "draw").toFixed(1)} wait max ${max(frames, "drawableWait").toFixed(1)}`
    : "frames 0";

  return `${offsetText}  ${scrollText.padEnd(36)}${frameText}`;
}

for (const [index, mark] of marks.entries()) {
  const around = lines.filter(
    (line) => line.atMs >= mark.atMs - beforeMs && line.atMs <= mark.atMs + afterMs
  );
  const isTimeline = (line: Line): boolean => line.kind === "frame" || line.kind === "scroll";

  console.log(`\nMark ${index + 1} at ${new Date(mark.atMs).toLocaleTimeString()}`);
  for (const line of around.filter((line) => !isTimeline(line)))
    console.log(toText(line, mark.atMs));
  console.log("  timeline");

  for (let startMs = mark.atMs - beforeMs; startMs < mark.atMs + afterMs; startMs += bucketMs) {
    const bucket = around.filter(
      (line) => isTimeline(line) && line.atMs >= startMs && line.atMs < startMs + bucketMs
    );

    console.log(toBucketText(bucket, startMs, mark.atMs));
  }
}
