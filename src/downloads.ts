import { homedir } from "node:os";
import { join } from "node:path";
import { fetchCatalogSongs, type CatalogSong } from "./apple-music.ts";

// Music.app keeps each downloaded Apple Music song as a package of its own in this folder.
const downloadFolder = join(homedir(), "Music", "Music", "Media.localized", "Apple Music");

// The stream's file name holds the catalog ID after "_A", and ends in "_alac" for a lossless download.
const streamPattern = /_A(\d+)_audio_[^"]*?(_alac)?\.m3u8"/;

type Download = { catalogId: string; isLossless: boolean };

async function readDownload(bootPath: string): Promise<Download | null> {
  const boot = await Bun.file(bootPath).text();
  const match = boot.match(streamPattern);
  const isComplete = boot.includes("<Complete>YES</Complete>");

  if (!match || !isComplete) return null;

  return { catalogId: match[1], isLossless: match[2] !== undefined };
}

async function listDownloads(): Promise<Download[]> {
  const bootPaths = await Array.fromAsync(
    new Bun.Glob("*/*/*.movpkg/boot.xml").scan({ cwd: downloadFolder, absolute: true })
  );
  const downloads = await Promise.all(bootPaths.map(readDownload));

  return downloads.filter((download) => download !== null);
}

// The quality comes from the file Music.app saved, not from what Apple offers.
export async function fetchDownloadedSongs(): Promise<CatalogSong[]> {
  const downloads = await listDownloads();
  const losslessIds = new Set(
    downloads.filter((download) => download.isLossless).map((download) => download.catalogId)
  );
  const songs = await fetchCatalogSongs(downloads.map((download) => download.catalogId));
  const downloadedSongs = songs.map((song) => ({ ...song, isLossless: losslessIds.has(song.id) }));

  return downloadedSongs.sort((left, right) => left.name.localeCompare(right.name));
}
