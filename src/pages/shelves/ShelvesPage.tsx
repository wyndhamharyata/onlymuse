import type { Shelf } from "../../apple-music.ts";
import { colors } from "../../theme.ts";
import { CardRow } from "../../window/Cards.tsx";
import { PageStatus, useFetched } from "../../window/Fetched.tsx";
import { toRowKeys } from "../../window/PageList.tsx";

const tileSizePx = 150;
const firstShelfTileSizePx = 210;

// Home and New. The first shelf takes bigger tiles, as on music.apple.com.
export function ShelvesPage({
  title,
  fetchShelves,
}: {
  title: string;
  fetchShelves: () => Promise<Shelf[]>;
}) {
  const { value: shelves, statusText } = useFetched(fetchShelves, [title]);
  const shelfKeys = toRowKeys((shelves ?? []).map((shelf) => shelf.title));

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 24 }}>
      <text style={{ color: colors.text, fontSize: 28, fontWeight: 700 }}>{title}</text>
      {!shelves && <PageStatus text={statusText} />}
      {shelves?.map((shelf, index) => (
        <CardRow
          key={shelfKeys[index]}
          title={shelf.title}
          cards={shelf.items}
          sizePx={index === 0 ? firstShelfTileSizePx : tileSizePx}
        />
      ))}
    </div>
  );
}
