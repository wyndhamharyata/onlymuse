import { fetchSearchResults } from "../../apple-music.ts";
import { playSongs } from "../../queue.ts";
import { colors } from "../../theme.ts";
import { CardRow, CardTile } from "../../window/Cards.tsx";
import { PageStatus, useFetched } from "../../window/Fetched.tsx";
import { SongRow } from "../../window/SongRow.tsx";

const topResultSizePx = 180;
const albumSizePx = 150;
const artistSizePx = 130;
const shownSongCount = 6;

export function SearchPage({ term }: { term: string }) {
  const { value: results, statusText } = useFetched(() => fetchSearchResults(term), [term]);

  if (!results) return <PageStatus text={statusText} />;

  const topArtist = results.artists[0];
  const shownSongs = results.songs.slice(0, shownSongCount);
  const hasResults = results.songs.length + results.albums.length + results.artists.length > 0;

  if (!hasResults) return <PageStatus text={`Apple Music has nothing for "${term}".`} />;

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 26 }}>
      <text
        style={{ color: colors.text, fontSize: 28, fontWeight: 700 }}
      >{`Results for "${term}"`}</text>
      <div style={{ display: "flex", gap: 28 }}>
        {topArtist && (
          <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
            <text style={{ color: colors.text, fontSize: 17, fontWeight: 700 }}>Top Result</text>
            <CardTile card={topArtist} sizePx={topResultSizePx} isRound />
          </div>
        )}
        <div
          style={{ display: "flex", flexDirection: "column", gap: 10, flexGrow: 1, minWidth: 0 }}
        >
          <text style={{ color: colors.text, fontSize: 17, fontWeight: 700 }}>Songs</text>
          {shownSongs.map((song, index) => (
            <SongRow
              key={song.id}
              song={song}
              subtitle={`${song.artistName} · ${song.albumName}`}
              onPlay={() => playSongs(shownSongs, index)}
            />
          ))}
        </div>
      </div>
      <CardRow title="Albums" cards={results.albums} sizePx={albumSizePx} />
      <CardRow title="Artists" cards={results.artists} sizePx={artistSizePx} isRound />
    </div>
  );
}
