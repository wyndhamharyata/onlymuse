import { fetchArtist, toArtworkUrl, type Artist } from "../../apple-music.ts";
import { shuffleSongs, playSongs } from "../../queue.ts";
import { colors } from "../../theme.ts";
import { useContentWidthPx } from "../../window/ContentWidth.tsx";
import { ActionButton } from "../../window/ActionButton.tsx";
import { Artwork } from "../../window/Artwork.tsx";
import { CardRow, CardTile } from "../../window/Cards.tsx";
import { PageStatus, useFetched } from "../../window/Fetched.tsx";
import { toRowKeys } from "../../window/PageList.tsx";
import { SongRow } from "../../window/SongRow.tsx";

const headerHeightPx = 300;
// Twice the drawn size, for the Retina screen.
const pixelsPerPoint = 2;
// The photo width steps up by this much, so a resize reuses a photo Apple already sent.
const photoWidthStepPx = 200;
const albumSizePx = 150;
const latestReleaseSizePx = 210;
const similarArtistSizePx = 130;

function Header({ artist }: { artist: Artist }) {
  // An image needs a definite width, so the header is as wide as the page content.
  const widthPx = useContentWidthPx();
  const photoWidthPx = Math.ceil(widthPx / photoWidthStepPx) * photoWidthStepPx * pixelsPerPoint;
  const photoHeightPx = headerHeightPx * pixelsPerPoint;
  const photoUrl = artist.artwork && toArtworkUrl(artist.artwork, photoWidthPx, photoHeightPx);
  const fallbackColor = `#${artist.artwork?.bgColor ?? "2a2a2f"}`;

  return (
    <div
      style={{
        position: "relative",
        height: headerHeightPx,
        borderRadius: 12,
        backgroundColor: fallbackColor,
      }}
    >
      {photoUrl && (
        <Artwork source={photoUrl} widthPx={widthPx} heightPx={headerHeightPx} radiusPx={12} />
      )}
      <div
        style={{
          position: "absolute",
          top: 0,
          left: 0,
          right: 0,
          bottom: 0,
          borderRadius: 12,
          background: {
            type: "linear-gradient",
            angle: 180,
            stops: [
              { color: "#1b1b1e00", position: 0.35 },
              { color: "#1b1b1ef2", position: 1 },
            ],
          },
        }}
      />
      <div
        style={{
          position: "absolute",
          left: 28,
          right: 28,
          bottom: 22,
          display: "flex",
          alignItems: "flex-end",
          gap: 10,
        }}
      >
        <div style={{ display: "flex", flexDirection: "column", flexGrow: 1 }}>
          <text style={{ color: colors.text, fontSize: 40, fontWeight: 800 }}>{artist.name}</text>
          <text style={{ color: "#cfcfd4", fontSize: 14 }}>{artist.genre}</text>
        </div>
        <ActionButton
          label="Play"
          icon="play"
          isPrimary
          onClick={() => playSongs(artist.topSongs, 0)}
        />
        <ActionButton
          label="Shuffle"
          icon="shuffle"
          isPrimary={false}
          onClick={() => shuffleSongs(artist.topSongs)}
        />
      </div>
    </div>
  );
}

export function ArtistPage({ artistId }: { artistId: string }) {
  const { value: artist, statusText } = useFetched(() => fetchArtist(artistId), [artistId]);

  if (!artist) return <PageStatus text={statusText} />;

  const songKeys = toRowKeys(artist.topSongs.map((song) => song.id));

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 26 }}>
      <Header artist={artist} />
      <div style={{ display: "flex", gap: 28 }}>
        {artist.latestRelease && (
          <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
            <text style={{ color: colors.text, fontSize: 17, fontWeight: 700 }}>
              Latest Release
            </text>
            <CardTile card={artist.latestRelease} sizePx={latestReleaseSizePx} />
          </div>
        )}
        <div
          style={{ display: "flex", flexDirection: "column", gap: 10, flexGrow: 1, minWidth: 0 }}
        >
          <text style={{ color: colors.text, fontSize: 17, fontWeight: 700 }}>Top Songs</text>
          <div style={{ display: "grid", gridTemplateColumns: 2, columnGap: 20 }}>
            {artist.topSongs.map((song, index) => (
              <SongRow
                key={songKeys[index]}
                song={song}
                subtitle={song.albumName}
                onPlay={() => playSongs(artist.topSongs, index)}
              />
            ))}
          </div>
        </div>
      </div>
      <CardRow title="In Your Library" cards={artist.libraryAlbums} sizePx={albumSizePx} />
      <CardRow title="Albums" cards={artist.albums} sizePx={albumSizePx} />
      <CardRow
        title="Similar Artists"
        cards={artist.similarArtists}
        sizePx={similarArtistSizePx}
        isRound
      />
    </div>
  );
}
