import type { CatalogSong } from "../../apple-music.ts";

export type SongList = { title: string; description: string; songs: CatalogSong[] };
import { playSongs, shuffleSongs } from "../../queue.ts";
import { colors } from "../../theme.ts";
import { ActionButton } from "../../window/ActionButton.tsx";
import { PageStatus, useFetched } from "../../window/Fetched.tsx";
import { SongRow } from "../../window/SongRow.tsx";

const rowHeightPx = 54;

// Favourite Songs, Songs, Downloaded and every playlist. The list scrolls on its own, so a long one draws only what shows.
export function SongListPage({
  fetchList,
  listKey,
}: {
  fetchList: () => Promise<SongList>;
  listKey: string;
}) {
  const { value: list, statusText } = useFetched(fetchList, [listKey]);
  const songs = list?.songs;
  const songCountText = `${list?.songs.length ?? 0} songs`;
  const listText = list?.description ? `${songCountText} · ${list.description}` : songCountText;
  const countText = list ? listText : statusText;
  const hasSongs = (songs?.length ?? 0) > 0;

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 16, flexGrow: 1, minHeight: 0 }}>
      <div style={{ display: "flex", alignItems: "flex-end", gap: 10 }}>
        <div style={{ display: "flex", flexDirection: "column", flexGrow: 1 }}>
          <text style={{ color: colors.text, fontSize: 28, fontWeight: 700 }}>
            {list?.title ?? ""}
          </text>
          <text style={{ color: colors.dim, fontSize: 13 }}>{countText}</text>
        </div>
        {songs && hasSongs && (
          <>
            <ActionButton label="Play" icon="play" isPrimary onClick={() => playSongs(songs, 0)} />
            <ActionButton
              label="Shuffle"
              icon="shuffle"
              isPrimary={false}
              onClick={() => shuffleSongs(songs)}
            />
          </>
        )}
      </div>
      {songs && !hasSongs && <PageStatus text="Nothing here yet." />}
      {songs && hasSongs && (
        <virtual-list estimatedItemHeight={rowHeightPx} style={{ flexGrow: 1, minHeight: 0 }}>
          {songs.map((song, index) => (
            <SongRow
              key={`${index}-${song.id}`}
              song={song}
              subtitle={`${song.artistName} · ${song.albumName}`}
              onPlay={() => playSongs(songs, index)}
            />
          ))}
        </virtual-list>
      )}
    </div>
  );
}
