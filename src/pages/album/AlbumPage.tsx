import { fetchAlbum, toArtworkUrl, type Album, type CatalogSong } from "../../apple-music.ts";
import { toClockText } from "../../format.ts";
import { useHelper } from "../../helper.ts";
import { navigate } from "../../navigation.ts";
import { playSongs, shuffleSongs, useQueue } from "../../queue.ts";
import { colors, toAccentTint } from "../../theme.ts";
import { ActionButton } from "../../window/ActionButton.tsx";
import { PageStatus, useFetched } from "../../window/Fetched.tsx";
import { PageList, toRowKeys, type PageRow } from "../../window/PageList.tsx";

const coverSizePx = 240;

const badgeLabels: Record<string, string> = {
  "hi-res-lossless": "HI-RES LOSSLESS",
  lossless: "LOSSLESS",
  atmos: "DOLBY ATMOS",
};

function Badge({ label, color }: { label: string; color: string }) {
  return (
    <div
      style={{
        paddingLeft: 6,
        paddingRight: 6,
        paddingTop: 1,
        paddingBottom: 1,
        borderRadius: 4,
        borderWidth: 1,
        borderColor: color,
      }}
    >
      <text style={{ color, fontSize: 11, fontWeight: 700 }}>{label}</text>
    </div>
  );
}

function SongLine({
  song,
  number,
  isCurrent,
  onPlay,
}: {
  song: CatalogSong;
  number: number;
  isCurrent: boolean;
  onPlay: () => void;
}) {
  const { accent } = useHelper();
  const textColor = isCurrent ? accent : colors.text;
  const background = isCurrent ? toAccentTint(accent) : undefined;

  return (
    <div
      onClick={onPlay}
      style={{
        display: "flex",
        alignItems: "center",
        gap: 12,
        paddingLeft: 10,
        paddingRight: 10,
        paddingTop: 9,
        paddingBottom: 9,
        borderRadius: 7,
        backgroundColor: background,
        cursor: "pointer",
        hover: { backgroundColor: background ?? colors.hover },
      }}
    >
      <text
        style={{ color: isCurrent ? accent : colors.faint, fontSize: 13, width: 24 }}
      >{`${number}`}</text>
      <text
        style={{
          color: textColor,
          fontSize: 13,
          flexGrow: 1,
          whiteSpace: "nowrap",
          textOverflow: "ellipsis",
        }}
      >
        {song.name}
      </text>
      <text style={{ color: colors.faint, fontSize: 12 }}>{toClockText(song.durationSeconds)}</text>
    </div>
  );
}

function Header({ album }: { album: Album }) {
  const { accent } = useHelper();
  const coverUrl = album.artwork ? toArtworkUrl(album.artwork, coverSizePx * 2) : undefined;
  const badges = album.audioTraits
    .filter((trait) => trait in badgeLabels)
    .map((trait) => badgeLabels[trait]);
  const libraryText = album.isInLibrary ? "In Library" : "Not in Library";
  const openArtist = album.artistId
    ? () => navigate({ id: "artist", artistId: album.artistId ?? "" })
    : undefined;

  return (
    <div style={{ display: "flex", alignItems: "flex-end", gap: 28 }}>
      {coverUrl ? (
        <img
          src={coverUrl}
          objectFit="cover"
          style={{ width: coverSizePx, height: coverSizePx, borderRadius: 10 }}
        />
      ) : (
        <div
          style={{
            width: coverSizePx,
            height: coverSizePx,
            borderRadius: 10,
            backgroundColor: colors.card,
          }}
        />
      )}
      <div style={{ display: "flex", flexDirection: "column", gap: 6, flexGrow: 1, minWidth: 0 }}>
        <text style={{ color: colors.text, fontSize: 32, fontWeight: 800 }}>{album.name}</text>
        <div onClick={openArtist} style={{ cursor: openArtist ? "pointer" : "default" }}>
          <text style={{ color: accent, fontSize: 20, fontWeight: 600 }}>{album.artistName}</text>
        </div>
        <text
          style={{ color: colors.dim, fontSize: 13 }}
        >{`${album.genre} · ${album.year} · ${album.songs.length} songs`}</text>
        <div style={{ display: "flex", gap: 8, marginTop: 6, marginBottom: 10 }}>
          {badges.map((label) => (
            <Badge key={label} label={label} color={colors.dim} />
          ))}
          <Badge label={libraryText} color={album.isInLibrary ? "#7ee2a8" : colors.faint} />
        </div>
        <div style={{ display: "flex", gap: 8 }}>
          <ActionButton
            label="Play"
            icon="play"
            isPrimary
            onClick={() => playSongs(album.songs, 0)}
          />
          <ActionButton
            label="Shuffle"
            icon="shuffle"
            isPrimary={false}
            onClick={() => shuffleSongs(album.songs)}
          />
        </div>
      </div>
    </div>
  );
}

export function AlbumPage({ albumId }: { albumId: string }) {
  const { value: album, statusText } = useFetched(() => fetchAlbum(albumId), [albumId]);
  const queue = useQueue();
  const currentSongId = queue.songs[queue.index]?.id;

  if (!album) return <PageStatus text={statusText} />;

  const rowKeys = toRowKeys(album.songs.map((song) => song.id));
  const headerRow: PageRow = {
    key: "header",
    element: (
      <div style={{ paddingBottom: 22 }}>
        <Header album={album} />
      </div>
    ),
  };
  const songRows: PageRow[] = album.songs.map((song, index) => ({
    key: rowKeys[index],
    element: (
      <SongLine
        song={song}
        number={index + 1}
        isCurrent={song.id === currentSongId}
        onPlay={() => playSongs(album.songs, index)}
      />
    ),
  }));

  return (
    <PageList rows={[headerRow, ...songRows]} isComplete estimatedRowHeightPx={40} gapPx={0} />
  );
}
