import { useSyncExternalStore } from "react";
import { fetchCatalogAlbumId, type Card, type Playlist } from "./apple-music.ts";
import { hasText, isFields, isWholeNumberIn, type Fields } from "./checks.ts";
import { playSongs } from "./queue.ts";
import { readState, saveState } from "./store.ts";

export type PageId =
  | "home"
  | "new"
  | "favouriteSongs"
  | "recentlyAdded"
  | "artists"
  | "albums"
  | "songs"
  | "downloaded";

export type Page =
  | { id: PageId }
  | { id: "playlist"; playlist: Playlist }
  | { id: "catalogPlaylist"; playlistId: string }
  | { id: "artist"; artistId: string }
  | { id: "album"; albumId: string }
  | { id: "search"; term: string };

// Each page in the history keeps the key of the row at its top, so Back, Forward and the next open return there.
export type Navigation = { pages: Page[]; topRowKeys: (string | null)[]; index: number };

const stateKey = "navigation";
const maxPageCount = 50;

const pageIds = new Set<string>([
  "home",
  "new",
  "favouriteSongs",
  "recentlyAdded",
  "artists",
  "albums",
  "songs",
  "downloaded",
]);

// The text field each page with an ID of its own needs.
const pageFields: Record<string, string> = {
  catalogPlaylist: "playlistId",
  artist: "artistId",
  album: "albumId",
  search: "term",
};

function isPlaylist(value: unknown): boolean {
  return (
    isFields(value) && hasText(value, "id", "name") && typeof value.isFavouriteSongs === "boolean"
  );
}

function isPage(value: unknown): value is Page {
  if (!isFields(value) || typeof value.id !== "string") return false;
  if (pageIds.has(value.id)) return true;
  if (value.id === "playlist") return isPlaylist(value.playlist);

  const field = pageFields[value.id];

  return field !== undefined && hasText(value, field);
}

function isNavigation(value: unknown): value is Navigation {
  if (!isFields(value) || !Array.isArray(value.pages) || !Array.isArray(value.topRowKeys))
    return false;

  const fields: Fields = value;
  const pages = value.pages;
  const hasPages = pages.length > 0 && pages.every(isPage);
  const hasKeys = value.topRowKeys.length === pages.length;

  return hasPages && hasKeys && isWholeNumberIn(fields.index, 0, pages.length - 1);
}

const listeners = new Set<() => void>();
const firstNavigation: Navigation = { pages: [{ id: "home" }], topRowKeys: [null], index: 0 };

let navigation = readState(stateKey, isNavigation, firstNavigation);

function setNavigation(next: Navigation): void {
  navigation = next;
  saveState(stateKey, navigation);
  for (const listener of listeners) listener();
}

// A new page drops the pages Forward would have reached, as a browser does. The oldest pages go past 50.
export function navigate(page: Page): void {
  const keptCount = navigation.index + 1;
  const firstKept = Math.max(0, keptCount + 1 - maxPageCount);
  const pages = [...navigation.pages.slice(firstKept, keptCount), page];
  const topRowKeys = [...navigation.topRowKeys.slice(firstKept, keptCount), null];

  setNavigation({ pages, topRowKeys, index: pages.length - 1 });
}

export function readTopRowKey(index: number): string | null {
  return navigation.topRowKeys[index] ?? null;
}

export function setTopRowKey(index: number, key: string): void {
  if (navigation.topRowKeys[index] === key) return;

  const topRowKeys = navigation.topRowKeys.map((oldKey, keyIndex) =>
    keyIndex === index ? key : oldKey
  );

  // Nothing on screen shows the key, so a scroll saves it without drawing the window again.
  navigation = { ...navigation, topRowKeys };
  saveState(stateKey, navigation);
}

export function goBack(): void {
  if (navigation.index > 0) setNavigation({ ...navigation, index: navigation.index - 1 });
}

export function goForward(): void {
  const hasForward = navigation.index < navigation.pages.length - 1;

  if (hasForward) setNavigation({ ...navigation, index: navigation.index + 1 });
}

// A song plays with the other songs of its row. A library album opens as its catalog album, which knows its quality.
export async function openCard(card: Card, row: Card[]): Promise<void> {
  if (card.kind === "album") return navigate({ id: "album", albumId: card.id });
  if (card.kind === "artist") return navigate({ id: "artist", artistId: card.id });
  if (card.kind === "playlist") return navigate({ id: "catalogPlaylist", playlistId: card.id });

  if (card.kind === "libraryPlaylist") {
    return navigate({
      id: "playlist",
      playlist: { id: card.id, name: card.name, isFavouriteSongs: false },
    });
  }

  if (card.kind === "song" && card.song) {
    const songs = row.flatMap((rowCard) => rowCard.song ?? []);

    return playSongs(songs, songs.indexOf(card.song));
  }

  if (card.kind !== "libraryAlbum") return;

  const albumId = await fetchCatalogAlbumId(card.id);

  navigate({ id: "album", albumId });
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);

  return () => listeners.delete(listener);
}

export function useNavigation(): Navigation {
  return useSyncExternalStore(subscribe, () => navigation);
}
