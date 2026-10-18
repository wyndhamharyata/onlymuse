import {
  existsSync,
  mkdirSync,
  readdirSync,
  renameSync,
  statSync,
  unlinkSync,
  utimesSync,
} from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// Apple's artwork on disk, so the next open draws it at once and with no network.
const folder = join(homedir(), "Library", "Caches", "onlymuse", "images");
const unusedMaxAgeMs = 60 * 24 * 60 * 60 * 1000;
const maxDownloadCount = 4;

const fileExtensions: Record<string, string> = {
  "image/jpeg": "jpg",
  "image/png": "png",
  "image/webp": "webp",
};

mkdirSync(folder, { recursive: true });

// A file is touched when the app first draws it, so its date says when it was last used.
const knownPaths = new Map<string, string | null>();
const waitingUrls: string[] = [];
let downloadCount = 0;

function toBaseName(url: string): string {
  return Bun.hash(url).toString(16);
}

function findSavedPath(url: string): string | null {
  const baseName = toBaseName(url);

  for (const fileExtension of Object.values(fileExtensions)) {
    const path = join(folder, `${baseName}.${fileExtension}`);

    if (existsSync(path)) return path;
  }

  return null;
}

async function download(url: string): Promise<void> {
  const response = await fetch(url);
  const fileExtension = fileExtensions[response.headers.get("content-type") ?? ""];

  if (!response.ok || !fileExtension) return;

  const path = join(folder, `${toBaseName(url)}.${fileExtension}`);
  const partPath = `${path}.part`;

  // The file takes its name once complete, so a quit halfway never makes a broken image.
  await Bun.write(partPath, response);
  renameSync(partPath, path);
  knownPaths.set(url, path);
}

function startDownloads(): void {
  while (downloadCount < maxDownloadCount && waitingUrls.length > 0) {
    const url = waitingUrls.shift() ?? "";

    downloadCount += 1;
    download(url)
      .catch(() => knownPaths.delete(url))
      .finally(() => {
        downloadCount -= 1;
        startDownloads();
      });
  }
}

// The file when it is on disk. Otherwise the URL, and the image is saved for the next draw.
export function readArtworkSource(url: string): string {
  if (!url.startsWith("https://")) return url;

  const knownPath = knownPaths.get(url);

  if (knownPath) return knownPath;
  if (knownPath === null) return url;

  const savedPath = findSavedPath(url);

  knownPaths.set(url, savedPath);

  if (savedPath) {
    const now = new Date();

    utimesSync(savedPath, now, now);

    return savedPath;
  }

  waitingUrls.push(url);
  startDownloads();

  return url;
}

function removeUnusedFiles(): void {
  const oldestKeptMs = Date.now() - unusedMaxAgeMs;

  for (const name of readdirSync(folder)) {
    const path = join(folder, name);

    if (statSync(path).mtimeMs < oldestKeptMs) unlinkSync(path);
  }
}

setTimeout(removeUnusedFiles, 10_000);
