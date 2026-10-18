import { toArtworkUrl, type CatalogSong } from "../apple-music.ts";
import { toClockText } from "../format.ts";
import { useHelper } from "../helper.ts";
import { useQueue } from "../queue.ts";
import { colors, toAccentTint } from "../theme.ts";

const artworkSizePx = 40;

export function SongRow({
  song,
  subtitle,
  onPlay,
}: {
  song: CatalogSong;
  subtitle: string;
  onPlay: () => void;
}) {
  const { accent } = useHelper();
  const queue = useQueue();
  const isCurrent = queue.songs[queue.index]?.id === song.id;
  const artworkUrl = song.artwork ? toArtworkUrl(song.artwork, artworkSizePx * 2) : undefined;
  const nameColor = isCurrent ? accent : colors.text;

  return (
    <div
      onClick={onPlay}
      style={{
        display: "flex",
        alignItems: "center",
        gap: 11,
        padding: 6,
        borderRadius: 7,
        width: "100%",
        minWidth: 0,
        backgroundColor: isCurrent ? toAccentTint(accent) : undefined,
        cursor: "pointer",
        hover: { backgroundColor: isCurrent ? toAccentTint(accent) : colors.hover },
      }}
    >
      {artworkUrl ? (
        <img
          src={artworkUrl}
          objectFit="cover"
          style={{ width: artworkSizePx, height: artworkSizePx, borderRadius: 5 }}
        />
      ) : (
        <div
          style={{
            width: artworkSizePx,
            height: artworkSizePx,
            borderRadius: 5,
            backgroundColor: colors.card,
          }}
        />
      )}
      <div style={{ display: "flex", flexDirection: "column", flexGrow: 1, minWidth: 0 }}>
        <text
          style={{ color: nameColor, fontSize: 13, whiteSpace: "nowrap", textOverflow: "ellipsis" }}
        >
          {song.name}
        </text>
        <text
          style={{
            color: colors.dim,
            fontSize: 12,
            whiteSpace: "nowrap",
            textOverflow: "ellipsis",
          }}
        >
          {subtitle}
        </text>
      </div>
      <text style={{ color: colors.faint, fontSize: 12 }}>{toClockText(song.durationSeconds)}</text>
    </div>
  );
}
