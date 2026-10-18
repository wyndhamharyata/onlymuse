import { useSyncExternalStore } from "react";
import { fetchCatalogAlbumId, type Card, type Playlist } from "./apple-music.ts";
import { playSongs } from "./queue.ts";

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

export type Navigation = { pages: Page[]; index: number };

const listeners = new Set<() => void>();

let navigation: Navigation = { pages: [{ id: "home" }], index: 0 };

function setNavigation(next: Navigation): void {
  navigation = next;
  for (const listener of listeners) listener();
}

// A new page drops the pages Forward would have reached, as a browser does.
export function navigate(page: Page): void {
  const pages = [...navigation.pages.slice(0, navigation.index + 1), page];

  setNavigation({ pages, index: pages.length - 1 });
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
