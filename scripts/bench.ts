import { launch } from "@gpuix/react/automation";
import { Database } from "bun:sqlite";
import { mkdtempSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";

// Measures JavaScript stalls, draw times and memory in each build, behind the other windows, on a copy of the saved data.

type Report = {
  frames?: { p90Ms?: number; p99Ms?: number; maxMs?: number; frames: number };
  stalls: { p99Ms: number; maxMs: number; missedFrames: number; blockedMs: number };
  rssMb: number;
  canReset: boolean;
  nativeCalls?: Record<string, { count: number; totalMs: number; maxMs: number }>;
  framesPerSecond?: number;
};

const savedData = join(homedir(), "Library", "Application Support", "onlymuse", "onlymuse.sqlite");
const modes =
  process.argv.slice(2).length > 0 ? process.argv.slice(2) : ["development", "production"];
const wheelTickCount = 120;
// A trackpad sends about 120 steps a second. GPUI draws an unfocused window at full rate only under input that fast.
const wheelTickMs = 7;
const wheelTickPx = -60;
const idleMs = 5000;
const loadMs = 9000;

const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

// A WAL database is copied with VACUUM INTO, which reads a consistent snapshot.
function copySavedData(folder: string): void {
  const database = new Database(savedData, { readonly: true });

  database.run(`vacuum into '${join(folder, "onlymuse.sqlite")}'`);
  database.close();
  const copy = new Database(join(folder, "onlymuse.sqlite"));

  // Each run starts on Home with the panel shut, whatever the saved state holds.
  copy.run("delete from state where key in ('navigation', 'panel')");
  copy.close();
}

// The app may be halfway through writing the report, so a read that fails tries again.
async function readReport(reportPath: string): Promise<Report> {
  for (let attempt = 1; ; attempt += 1) {
    try {
      return JSON.parse(await Bun.file(reportPath).text()) as Report;
    } catch (error) {
      if (attempt === 5) throw error;

      await sleep(20);
    }
  }
}

// The frame count keeps growing, so the frames of a scene are the count after it less the count before it.
async function measure(reportPath: string, run: () => Promise<void>): Promise<Report> {
  await Bun.write(`${reportPath}.reset`, "reset");
  stepsPerSecond = 0;
  await sleep(600);
  const framesBefore = (await readReport(reportPath)).frames?.frames ?? 0;
  const startMs = performance.now();

  await run();
  const runMs = performance.now() - startMs;

  await sleep(600);
  const report = await readReport(reportPath);

  return {
    ...report,
    framesPerSecond: (((report.frames?.frames ?? 0) - framesBefore) / runMs) * 1000,
  };
}

function toRow(mode: string, scene: string, report: Report): string {
  const frames = report.frames;
  const stalls = report.stalls;
  const batch = report.nativeCalls?.applyBatch;
  const tick = report.nativeCalls?.tick;
  const nativeText = `batch ${batch?.count ?? 0}x max ${batch?.maxMs.toFixed(0)} total ${batch?.totalMs.toFixed(0)} | tick max ${tick?.maxMs.toFixed(0)} total ${tick?.totalMs.toFixed(0)} ms`;
  const drawText = `draw p90 ${frames?.p90Ms?.toFixed(1)} max ${frames?.maxMs?.toFixed(1)} ms (${frames?.frames ?? 0} frames)`;
  const stallText = `JS stalls p99 ${stalls.p99Ms.toFixed(1)} max ${stalls.maxMs.toFixed(0)} ms, ${stalls.missedFrames} frames missed, ${stalls.blockedMs} ms blocked`;

  const stepsText = stepsPerSecond > 0 ? ` for ${stepsPerSecond.toFixed(0)} steps/s` : "";
  const rateText = `${(report.framesPerSecond ?? 0).toFixed(0).padStart(4)} fps${stepsText}`.padEnd(
    24
  );

  return `${mode.padEnd(12)}${scene.padEnd(22)}${rateText}  ${stallText.padEnd(76)}${nativeText.padEnd(58)}${drawText}  ${report.rssMb} MB`;
}

// The wheel steps a second the last scroll sent, which a frame rate is read against.
let stepsPerSecond = 0;

async function scroll(app: Awaited<ReturnType<typeof launch>>, isSideways = false): Promise<void> {
  const point = isSideways ? { x: 800, y: 300 } : { x: 800, y: 500 };
  const startMs = performance.now();

  for (let tick = 0; tick < wheelTickCount; tick += 1) {
    await app.mouse.wheel(point, isSideways ? wheelTickPx / 2 : 0, isSideways ? 0 : wheelTickPx);
    await sleep(wheelTickMs);
  }

  stepsPerSecond = (wheelTickCount / (performance.now() - startMs)) * 1000;
}

async function clickSidebar(app: Awaited<ReturnType<typeof launch>>, text: string): Promise<void> {
  const nodes = await app.getByText(text).all();
  const bounds = nodes.find(
    (node) => node.bounds && node.bounds.x < 228 && node.text === text
  )?.bounds;

  if (!bounds) throw new Error(`The sidebar has no ${text}`);

  await app.mouse.click({ x: bounds.x + 5, y: bounds.y + bounds.height / 2 });
}

// The Up Next button is the second icon from the left among those at the right of the player bar.
async function clickUpNext(app: Awaited<ReturnType<typeof launch>>): Promise<void> {
  const icons = (await app.getByType("svg").all()).filter(
    (node) => node.bounds && node.bounds.y > 720 && node.bounds.x > 900
  );
  const bounds = icons.sort((left, right) => (left.bounds?.x ?? 0) - (right.bounds?.x ?? 0))[1]
    ?.bounds;

  if (!bounds) throw new Error("The player bar has no Up Next button");

  await app.mouse.click({ x: bounds.x + bounds.width / 2, y: bounds.y + bounds.height / 2 });
}

async function scrollPanel(app: Awaited<ReturnType<typeof launch>>): Promise<void> {
  for (let tick = 0; tick < wheelTickCount; tick += 1) {
    await app.mouse.wheel({ x: 1100, y: 400 }, 0, wheelTickPx);
    await sleep(wheelTickMs);
  }
}

const rows: string[] = [];

for (const mode of modes) {
  const folder = mkdtempSync(join(tmpdir(), "onlymuse-bench-"));
  const reportPath = join(folder, "perf.json");

  copySavedData(folder);

  const app = await launch({
    command: "bun",
    args: ["src/main.tsx"],
    env: {
      GPUIX_BACKGROUND: "1",
      ONLYMUSE_PERF: reportPath,
      ONLYMUSE_DATA: folder,
      NODE_ENV: mode,
    },
  });

  try {
    await sleep(loadMs);
    console.error(`${mode}: frame counts can reset: ${(await readReport(reportPath)).canReset}`);
    rows.push(toRow(mode, "idle on Home", await measure(reportPath, () => sleep(idleMs))));
    rows.push(toRow(mode, "scroll Home", await measure(reportPath, () => scroll(app))));
    rows.push(
      toRow(
        mode,
        "open New",
        await measure(reportPath, () => clickSidebar(app, "New").then(() => sleep(3000)))
      )
    );
    rows.push(
      toRow(mode, "scroll New sideways", await measure(reportPath, () => scroll(app, true)))
    );
    rows.push(toRow(mode, "scroll New", await measure(reportPath, () => scroll(app))));
    rows.push(toRow(mode, "idle on New", await measure(reportPath, () => sleep(idleMs))));
    await clickSidebar(app, "Songs");
    await sleep(4000);
    rows.push(toRow(mode, "scroll Songs", await measure(reportPath, () => scroll(app))));
    rows.push(toRow(mode, "idle on Songs", await measure(reportPath, () => sleep(idleMs))));
    rows.push(
      toRow(
        mode,
        "open Up Next",
        await measure(reportPath, () => clickUpNext(app).then(() => sleep(2000)))
      )
    );
    rows.push(toRow(mode, "scroll Up Next", await measure(reportPath, () => scrollPanel(app))));
    rows.push(toRow(mode, "scroll Songs, panel", await measure(reportPath, () => scroll(app))));
  } finally {
    await app.close();
    rmSync(folder, { recursive: true, force: true });
  }
}

console.log(rows.join("\n"));
