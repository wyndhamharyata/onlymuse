import {
  fetchCatalogPlaylist,
  fetchFavouriteSongs,
  fetchLibrarySongs,
  fetchPlaylistSongs,
  type Playlist,
} from "../../apple-music.ts";
import { fetchDownloadedSongs } from "../../downloads.ts";
import type { SongList } from "./SongListPage.tsx";

export async function fetchFavouriteSongsList(): Promise<SongList> {
  return { title: "Favourite Songs", description: "", songs: await fetchFavouriteSongs() };
}

export async function fetchSongsList(): Promise<SongList> {
  return { title: "Songs", description: "", songs: await fetchLibrarySongs() };
}

export async function fetchLibraryPlaylistList(playlist: Playlist): Promise<SongList> {
  return { title: playlist.name, description: "", songs: await fetchPlaylistSongs(playlist.id) };
}

export async function fetchCatalogPlaylistList(playlistId: string): Promise<SongList> {
  const playlist = await fetchCatalogPlaylist(playlistId);

  return { title: playlist.name, description: playlist.curatorName, songs: playlist.songs };
}

// The count of lossless downloads shows which songs the quality setting has not reached yet.
export async function fetchDownloadedList(): Promise<SongList> {
  const songs = await fetchDownloadedSongs();
  const losslessCount = songs.filter((song) => song.isLossless).length;

  return { title: "Downloaded", description: `${losslessCount} lossless`, songs };
}
