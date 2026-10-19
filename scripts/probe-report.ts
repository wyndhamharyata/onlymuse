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

for (const [index, mark] of marks.entries()) {
  const around = lines.filter(
    (line) => line.atMs >= mark.atMs - beforeMs && line.atMs <= mark.atMs + afterMs
  );

  console.log(`\nMark ${index + 1} at ${new Date(mark.atMs).toLocaleTimeString()}`);
  for (const line of around) console.log(toText(line, mark.atMs));
}
