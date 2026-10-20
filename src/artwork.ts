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
import { probe } from "./probe.ts";

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
// The tiles that wait for an image, told when it is saved.
const waiters = new Map<string, Set<() => void>>();
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

// Apple's image server resets a connection now and then, and answers 429 or 5xx when busy. Those are tried again.
const retryDelaysMs = [250, 500, 1000];
// A download that still fails is tried again this much later, so its tile does not stay grey.
const laterRetryMs = 30_000;

async function fetchWithRetries(url: string): Promise<Response | null> {
  for (let attempt = 0; ; attempt += 1) {
    const response = await fetch(url).catch(() => null);
    const isPassing = !response || response.status === 429 || response.status >= 500;

    if (!isPassing || attempt >= retryDelaysMs.length) return response;

    await Bun.sleep(retryDelaysMs[attempt]);
  }
}

function tellWaiters(url: string): void {
  for (const waiter of waiters.get(url) ?? []) waiter();
}

// True once the file is on disk.
async function download(url: string): Promise<boolean> {
  const startMs = performance.now();
  const response = await fetchWithRetries(url);

  probe("artwork", { ms: Math.round(performance.now() - startMs), status: response?.status ?? 0 });

  const fileExtension = fileExtensions[response?.headers.get("content-type") ?? ""];

  if (!response?.ok || !fileExtension) return false;

  const path = join(folder, `${toBaseName(url)}.${fileExtension}`);
  const partPath = `${path}.part`;

  // The file takes its name once complete, so a quit halfway never makes a broken image.
  await Bun.write(partPath, response);
  renameSync(partPath, path);
  knownPaths.set(url, path);
  tellWaiters(url);

  return true;
}

// The tile asks again when told, and its next read starts a new download.
function retryLater(url: string): void {
  setTimeout(() => {
    knownPaths.delete(url);
    tellWaiters(url);
  }, laterRetryMs);
}

function startDownloads(): void {
  while (downloadCount < maxDownloadCount && waitingUrls.length > 0) {
    const url = waitingUrls.shift() ?? "";

    downloadCount += 1;
    download(url)
      .catch(() => false)
      .then((isSaved) => {
        if (!isSaved) retryLater(url);
      })
      .finally(() => {
        downloadCount -= 1;
        startDownloads();
      });
  }
}

export function subscribeToArtwork(url: string, onSaved: () => void): () => void {
  const urlWaiters = waiters.get(url) ?? new Set();

  urlWaiters.add(onSaved);
  waiters.set(url, urlWaiters);

  return () => {
    urlWaiters.delete(onSaved);
    if (urlWaiters.size === 0) waiters.delete(url);
  };
}

// The file once on disk, else null. A URL would make GPUI download it again, and Apple resets the extra connections.
export function readArtworkPath(url: string): string | null {
  if (!url.startsWith("https://")) return url;

  const knownPath = knownPaths.get(url);

  if (knownPath !== undefined) return knownPath;

  const savedPath = findSavedPath(url);

  knownPaths.set(url, savedPath);

  if (savedPath) {
    const now = new Date();

    utimesSync(savedPath, now, now);

    return savedPath;
  }

  waitingUrls.push(url);
  startDownloads();

  return null;
}

function removeUnusedFiles(): void {
  const oldestKeptMs = Date.now() - unusedMaxAgeMs;

  for (const name of readdirSync(folder)) {
    const path = join(folder, name);

    if (statSync(path).mtimeMs < oldestKeptMs) unlinkSync(path);
  }
}

setTimeout(removeUnusedFiles, 10_000);
