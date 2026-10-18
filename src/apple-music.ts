import { AsyncLocalStorage } from "node:async_hooks";
import { readTokens, refreshTokens, type Tokens } from "./helper.ts";
import {
  markResponseFetched,
  markResponsesStale,
  readResponse,
  saveResponse,
  type StoredResponse,
} from "./store.ts";

const baseUrl = "https://amp-api.music.apple.com";
const language = "en-GB";
const timeoutMs = 15_000;

// The developer token belongs to the web player, so Apple accepts it only from the web player's origin.
const webPlayerHeaders = {
  Origin: "https://music.apple.com",
  Referer: "https://music.apple.com/",
  "User-Agent":
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
};

export type Artwork = { url: string; bgColor?: string };

type Attributes = {
  name?: string;
  artistName?: string;
  albumName?: string;
  curatorName?: string;
  artwork?: Artwork;
  canEdit?: boolean;
  canDelete?: boolean;
  title?: { stringForDisplay: string };
  genreNames?: string[];
  releaseDate?: string;
  durationInMillis?: number;
  trackNumber?: number;
  audioTraits?: string[];
  playParams?: { catalogId?: string };
  ttml?: string;
  description?: { standard?: string; short?: string };
};

type Resource = {
  id: string;
  type: string;
  attributes?: Attributes;
  relationships?: Record<string, { data: Resource[] } | undefined>;
  views?: Record<string, { data: Resource[] } | undefined>;
};

export type CatalogSong = {
  id: string;
  name: string;
  artistName: string;
  albumName: string;
  durationSeconds: number;
  isLossless: boolean;
  artwork?: Artwork;
};

export type Card = {
  id: string;
  kind: "album" | "libraryAlbum" | "artist" | "playlist" | "libraryPlaylist" | "song" | "other";
  name: string;
  subtitle: string;
  artwork?: Artwork;
  // Set on a song card, so the shelf can play its songs in order.
  song?: CatalogSong;
};

export type CatalogPlaylist = {
  name: string;
  curatorName: string;
  description: string;
  songs: CatalogSong[];
};

export type Shelf = { title: string; items: Card[] };
export type Playlist = { id: string; name: string; isFavouriteSongs: boolean };

export type Artist = {
  id: string;
  name: string;
  genre: string;
  artwork?: Artwork;
  latestRelease?: Card;
  topSongs: CatalogSong[];
  albums: Card[];
  libraryAlbums: Card[];
  similarArtists: Card[];
};

export type Album = {
  id: string;
  name: string;
  artistName: string;
  artistId?: string;
  genre: string;
  year: string;
  artwork?: Artwork;
  audioTraits: string[];
  isInLibrary: boolean;
  songs: CatalogSong[];
};

export type LyricLine = { beginSeconds: number; text: string };

export type SearchResults = { songs: CatalogSong[]; albums: Card[]; artists: Card[] };

export class AppleMusicError extends Error {
  constructor(
    readonly status: number,
    path: string
  ) {
    super(`Apple Music answered ${status} for ${path}`);
  }
}

function fetchWithTokens(
  url: string,
  method: "GET" | "POST",
  tokens: Tokens,
  etag: string | null
): Promise<Response> {
  const headers: Record<string, string> = {
    ...webPlayerHeaders,
    Authorization: `Bearer ${tokens.developerToken}`,
    "media-user-token": tokens.userToken,
  };

  if (etag) headers["If-None-Match"] = etag;

  return fetch(url, { method, headers, signal: AbortSignal.timeout(timeoutMs) });
}

// Apple answers 401 or 403 once a token expires, and 304 when the stored body is current.
async function fetchResponse(
  path: string,
  method: "GET" | "POST",
  etag: string | null = null
): Promise<Response> {
  const separator = path.includes("?") ? "&" : "?";
  const url = `${baseUrl}${path}${separator}l=${language}`;

  const firstResponse = await fetchWithTokens(url, method, await readTokens(), etag);
  const isRefused = firstResponse.status === 401 || firstResponse.status === 403;
  const response = isRefused
    ? await fetchWithTokens(url, method, await refreshTokens(), etag)
    : firstResponse;
  const isCurrent = response.status === 304;

  if (!response.ok && !isCurrent) throw new AppleMusicError(response.status, path);

  return response;
}

const minuteMs = 60 * 1000;
const dayMs = 24 * 60 * minuteMs;

// How long an answer counts as fresh. The first rule whose text the path holds applies.
const freshRules: [string, number][] = [
  ["/v1/me/storefront", 30 * dayMs],
  ["/lyrics", 30 * dayMs],
  ["/v1/me/recommendations", 10 * minuteMs],
  ["/v1/me/", 0],
  ["/v1/editorial/", 60 * minuteMs],
  ["/search?", 10 * minuteMs],
  ["/v1/catalog/", dayMs],
];

function toFreshMs(path: string): number {
  const rule = freshRules.find(([pathPart]) => path.includes(pathPart));

  return rule?.[1] ?? 0;
}

// The paths each page read, so a newer answer from Apple redraws the pages that showed the old one.
const readPaths = new AsyncLocalStorage<Set<string>>();
const changeListeners = new Set<(path: string) => void>();
const checks = new Map<string, Promise<void>>();

async function checkResponse(path: string, stored: StoredResponse): Promise<void> {
  const response = await fetchResponse(path, "GET", stored.etag);

  if (response.status === 304) return markResponseFetched(path);

  const body = await response.text();

  saveResponse(path, body, response.headers.get("etag"));
  // A listener starts a new watch, which joins the set. The loop walks a copy, so it ends.
  if (body !== stored.body) for (const listener of [...changeListeners]) listener(path);
}

// One check per path at a time. A check that fails keeps the stored answer, so the app works offline.
function startCheck(path: string, stored: StoredResponse): void {
  if (checks.has(path)) return;

  const check = checkResponse(path, stored)
    .catch(() => undefined)
    .finally(() => checks.delete(path));

  checks.set(path, check);
}

// A stored answer shows at once, without waiting for the tokens. A stale one is checked with Apple meanwhile.
async function fetchJson<Body>(path: string): Promise<Body> {
  const stored = readResponse(path);

  readPaths.getStore()?.add(path);

  if (stored) {
    const isFresh = Date.now() - stored.fetchedAtMs < toFreshMs(path);

    if (!isFresh) startCheck(path, stored);

    return JSON.parse(stored.body) as Body;
  }

  const response = await fetchResponse(path, "GET");
  const body = await response.text();

  saveResponse(path, body, response.headers.get("etag"));

  return JSON.parse(body) as Body;
}

export type Watched<Value> = { value: Promise<Value>; stop: () => void };

// Runs a fetch and calls onChange when Apple sends something newer for any path it read.
export function watchFetch<Value>(
  fetchValue: () => Promise<Value>,
  onChange: () => void
): Watched<Value> {
  const paths = new Set<string>();
  const listener = (path: string): void => {
    if (paths.has(path)) onChange();
  };

  changeListeners.add(listener);

  return { value: readPaths.run(paths, fetchValue), stop: () => changeListeners.delete(listener) };
}

async function fetchData(path: string): Promise<Resource[]> {
  const body = await fetchJson<{ data: Resource[] }>(path);

  return body.data;
}

const pageLimit = 100;

// The library answers at most 100 items at a time. Its link to the next page drops the query, so only its offset is kept.
async function fetchAllPages(path: string): Promise<Resource[]> {
  const resources: Resource[] = [];
  const separator = path.includes("?") ? "&" : "?";
  let offset: string | null = "0";

  while (offset !== null) {
    const body: { data: Resource[]; next?: string } = await fetchJson(
      `${path}${separator}limit=${pageLimit}&offset=${offset}`
    );

    resources.push(...body.data);
    offset = body.next ? new URL(body.next, baseUrl).searchParams.get("offset") : null;
  }

  return resources;
}

let storefront: Promise<string> | null = null;

// The storefront is the account's country, the same for every catalog call.
function readStorefront(): Promise<string> {
  storefront ??= fetchData("/v1/me/storefront").then((data) => data[0].id);

  return storefront;
}

async function toCatalogPath(path: string): Promise<string> {
  return `/v1/catalog/${await readStorefront()}${path}`;
}

export function toArtworkUrl(artwork: Artwork, widthPx: number, heightPx = widthPx): string {
  return artwork.url
    .replace("{w}", `${widthPx}`)
    .replace("{h}", `${heightPx}`)
    .replace("{f}", "jpg");
}

const cardKinds: Record<string, Card["kind"]> = {
  albums: "album",
  "library-albums": "libraryAlbum",
  artists: "artist",
  playlists: "playlist",
  "library-playlists": "libraryPlaylist",
  songs: "song",
};

function toCard(resource: Resource): Card {
  const attributes = resource.attributes ?? {};

  return {
    id: resource.id,
    kind: cardKinds[resource.type] ?? "other",
    name: attributes.name ?? "",
    subtitle: attributes.curatorName ?? attributes.artistName ?? "",
    artwork: attributes.artwork,
    song: resource.type === "songs" ? toCatalogSong(resource) : undefined,
  };
}

// A shelf can hold stations, radio shows and videos. onlymuse has no page for those, so they stay out.
function listCards(resources: Resource[]): Card[] {
  const cards: Card[] = [];

  for (const resource of resources) {
    const card = toCard(resource);

    if (card.kind !== "other") cards.push(card);
  }

  return cards;
}

function toCatalogSong(resource: Resource): CatalogSong {
  const attributes = resource.attributes ?? {};

  return {
    id: resource.id,
    name: attributes.name ?? "",
    artistName: attributes.artistName ?? "",
    albumName: attributes.albumName ?? "",
    durationSeconds: (attributes.durationInMillis ?? 0) / 1000,
    isLossless: attributes.audioTraits?.includes("lossless") ?? false,
    artwork: attributes.artwork,
  };
}

// A library song plays by its catalog ID. A song uploaded from a Mac has none, so it keeps its library ID.
function toLibrarySong(resource: Resource): CatalogSong {
  return {
    ...toCatalogSong(resource),
    id: resource.attributes?.playParams?.catalogId ?? resource.id,
  };
}

function listView(resource: Resource, view: string): Resource[] {
  return resource.views?.[view]?.data ?? [];
}

export async function fetchHomeShelves(): Promise<Shelf[]> {
  const shelves = await fetchData("/v1/me/recommendations?limit=10");

  return shelves.map((shelf) => ({
    title: shelf.attributes?.title?.stringForDisplay ?? "",
    items: listCards(shelf.relationships?.contents?.data ?? []),
  }));
}

// Favourite Songs is the one library playlist a person can neither edit nor delete.
export async function fetchLibraryPlaylists(): Promise<Playlist[]> {
  const playlists = await fetchData("/v1/me/library/playlists?limit=100");

  return playlists.map((playlist) => ({
    id: playlist.id,
    name: playlist.attributes?.name ?? "",
    isFavouriteSongs:
      playlist.attributes?.canEdit === false && playlist.attributes.canDelete === false,
  }));
}

// Library search misses a term with an apostrophe, so it searches the longest word and checks the full name.
async function fetchLibraryAlbumsOfArtist(artistName: string): Promise<Card[]> {
  const words = artistName.split(/[^\p{L}\p{N}]+/u);
  const longestWord = words.reduce(
    (longest, word) => (word.length > longest.length ? word : longest),
    ""
  );
  const path = `/v1/me/library/search?term=${encodeURIComponent(longestWord)}&types=library-artists&limit=25`;

  const body = await fetchJson<{ results: { "library-artists"?: { data: Resource[] } } }>(path);
  const libraryArtist = body.results["library-artists"]?.data.find(
    (artist) => artist.attributes?.name === artistName
  );

  if (!libraryArtist) return [];

  const albums = await fetchData(`/v1/me/library/artists/${libraryArtist.id}/albums`);

  return albums.map(toCard);
}

export async function fetchArtist(artistId: string): Promise<Artist> {
  const views = "top-songs,latest-release,full-albums,similar-artists";
  const [artist] = await fetchData(await toCatalogPath(`/artists/${artistId}?views=${views}`));
  const attributes = artist.attributes ?? {};
  const name = attributes.name ?? "";

  const latestRelease = listView(artist, "latest-release")[0];

  return {
    id: artist.id,
    name,
    genre: attributes.genreNames?.[0] ?? "",
    artwork: attributes.artwork,
    latestRelease: latestRelease ? toCard(latestRelease) : undefined,
    topSongs: listView(artist, "top-songs").map(toCatalogSong),
    albums: listView(artist, "full-albums").map(toCard),
    libraryAlbums: await fetchLibraryAlbumsOfArtist(name),
    similarArtists: listView(artist, "similar-artists").map(toCard),
  };
}

export async function fetchAlbum(albumId: string): Promise<Album> {
  const [album] = await fetchData(
    await toCatalogPath(`/albums/${albumId}?include=artists&relate=library`)
  );
  const attributes = album.attributes ?? {};

  return {
    id: album.id,
    name: attributes.name ?? "",
    artistName: attributes.artistName ?? "",
    artistId: album.relationships?.artists?.data[0]?.id,
    genre: attributes.genreNames?.[0] ?? "",
    year: (attributes.releaseDate ?? "").slice(0, 4),
    artwork: attributes.artwork,
    audioTraits: attributes.audioTraits ?? [],
    isInLibrary: (album.relationships?.library?.data.length ?? 0) > 0,
    songs: (album.relationships?.tracks?.data ?? []).map(toCatalogSong),
  };
}

export async function fetchCatalogAlbumId(libraryAlbumId: string): Promise<string> {
  const [album] = await fetchData(`/v1/me/library/albums/${libraryAlbumId}/catalog`);

  return album.id;
}

export async function fetchSearchResults(term: string): Promise<SearchResults> {
  const query = `term=${encodeURIComponent(term)}&types=songs,albums,artists&limit=12`;
  const path = await toCatalogPath(`/search?${query}`);

  const body = await fetchJson<{ results: Record<string, { data: Resource[] } | undefined> }>(path);
  const results = body.results;

  return {
    songs: (results.songs?.data ?? []).map(toCatalogSong),
    albums: (results.albums?.data ?? []).map(toCard),
    artists: (results.artists?.data ?? []).map(toCard),
  };
}

// Music.app gives a song's artist only as a name. The catalog artist with that exact name is the one.
export async function findCatalogArtistId(artistName: string): Promise<string | null> {
  const results = await fetchSearchResults(artistName);
  const artist = results.artists.find((card) => card.name === artistName) ?? results.artists[0];

  return artist?.id ?? null;
}

// The library pages check with Apple on their next visit, so the new song shows there.
export async function addToLibrary(kind: "songs" | "albums", catalogId: string): Promise<void> {
  await fetchResponse(`/v1/me/library?ids[${kind}]=${catalogId}`, "POST");
  markResponsesStale("/v1/me/library");
}

export async function fetchPlaylistSongs(playlistId: string): Promise<CatalogSong[]> {
  const songs = await fetchAllPages(`/v1/me/library/playlists/${playlistId}/tracks`);

  return songs.map(toLibrarySong);
}

export async function fetchLibrarySongs(): Promise<CatalogSong[]> {
  const songs = await fetchAllPages("/v1/me/library/songs?sort=name");

  return songs.map(toLibrarySong);
}

export async function fetchLibraryAlbums(): Promise<Card[]> {
  const albums = await fetchAllPages("/v1/me/library/albums?sort=name");

  return albums.map(toCard);
}

// A library artist has no photo. Its catalog artist has one and opens the full artist page.
export async function fetchLibraryArtists(): Promise<Card[]> {
  const artists = await fetchAllPages("/v1/me/library/artists?sort=name&include=catalog");
  const cards = new Map<string, Card>();

  // Two library artists can share one catalog artist, such as a name spelled two ways. It shows once.
  for (const artist of artists) {
    const catalogArtist = artist.relationships?.catalog?.data[0];

    if (catalogArtist && !cards.has(catalogArtist.id))
      cards.set(catalogArtist.id, toCard(catalogArtist));
  }

  return [...cards.values()];
}

export async function fetchRecentlyAdded(): Promise<Card[]> {
  const items = await fetchData(`/v1/me/library/recently-added?limit=25`);

  return listCards(items);
}

// Music.app gives a song only by its name, artist and album. The catalog song with all three is the one.
export async function findCatalogSong(
  name: string,
  artistName: string,
  albumName: string
): Promise<CatalogSong | null> {
  const results = await fetchSearchResults(`${name} ${artistName}`);
  const sameSongs = results.songs.filter(
    (song) => song.name === name && song.artistName === artistName
  );

  return sameSongs.find((song) => song.albumName === albumName) ?? sameSongs[0] ?? null;
}

// TTML writes a time as seconds, as "3:22.434", or as "1:03:22.434".
function toSeconds(time: string): number {
  return time.split(":").reduce((total, part) => total * 60 + Number(part), 0);
}

function toLyricLines(ttml: string): LyricLine[] {
  const lines: LyricLine[] = [];

  for (const match of ttml.matchAll(/<p begin="([^"]+)"[^>]*>(.*?)<\/p>/g)) {
    const text = match[2]
      .replace(/<[^>]+>/g, "")
      .replaceAll("&amp;", "&")
      .replaceAll("&apos;", "'")
      .replaceAll("&quot;", '"');

    lines.push({ beginSeconds: toSeconds(match[1]), text });
  }

  return lines;
}

// Apple answers 404 for a song with no lyrics.
export async function fetchLyrics(songId: string): Promise<LyricLine[]> {
  try {
    const [lyrics] = await fetchData(await toCatalogPath(`/songs/${songId}/lyrics`));

    return toLyricLines(lyrics?.attributes?.ttml ?? "");
  } catch (error) {
    if (error instanceof AppleMusicError && error.status === 404) return [];

    throw error;
  }
}

export async function fetchFavouriteSongs(): Promise<CatalogSong[]> {
  const playlists = await fetchLibraryPlaylists();
  const favouriteSongs = playlists.find((playlist) => playlist.isFavouriteSongs);

  return favouriteSongs ? fetchPlaylistSongs(favouriteSongs.id) : [];
}

type EditorialElement = Resource & { attributes?: Attributes & { editorialElementKind?: string } };

// New is Apple's editorial page "music", a list of named shelves. A shelf with no name is a banner, which onlymuse skips.
export async function fetchNewShelves(): Promise<Shelf[]> {
  const [grouping] = await fetchData(
    `/v1/editorial/${await readStorefront()}/groupings?platform=web&name=music`
  );
  const elements: EditorialElement[] =
    grouping.relationships?.tabs?.data[0]?.relationships?.children?.data ?? [];
  const shelves: Shelf[] = [];

  for (const element of elements) {
    const items = listCards(element.relationships?.contents?.data ?? []);

    if (element.attributes?.name && items.length > 0)
      shelves.push({ title: element.attributes.name, items });
  }

  return shelves;
}

export async function fetchCatalogPlaylist(playlistId: string): Promise<CatalogPlaylist> {
  const [playlist] = await fetchData(await toCatalogPath(`/playlists/${playlistId}`));
  const songs = await fetchAllPages(await toCatalogPath(`/playlists/${playlistId}/tracks`));
  const attributes = playlist.attributes ?? {};

  return {
    name: attributes.name ?? "",
    curatorName: attributes.curatorName ?? "",
    description: attributes.description?.short ?? attributes.description?.standard ?? "",
    songs: songs.map(toCatalogSong),
  };
}

const songsPerRequest = 100;

// Answers in the order of the IDs. A song Apple has taken down is left out.
export async function fetchCatalogSongs(songIds: string[]): Promise<CatalogSong[]> {
  const songs = new Map<string, CatalogSong>();

  for (let first = 0; first < songIds.length; first += songsPerRequest) {
    const ids = songIds.slice(first, first + songsPerRequest).join(",");
    const data = await fetchData(await toCatalogPath(`/songs?ids=${ids}`));

    for (const resource of data) songs.set(resource.id, toCatalogSong(resource));
  }

  return songIds.flatMap((id) => songs.get(id) ?? []);
}
