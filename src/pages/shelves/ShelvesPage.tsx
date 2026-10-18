import type { Shelf } from "../../apple-music.ts";
import { colors } from "../../theme.ts";
import { CardRow } from "../../window/Cards.tsx";
import { PageStatus, useFetched } from "../../window/Fetched.tsx";
import { PageList, toRowKeys, type PageRow } from "../../window/PageList.tsx";

const tileSizePx = 150;
const firstShelfTileSizePx = 210;
// A shelf is its title, its tiles, then one or two lines of text.
const shelfHeightPx = tileSizePx + 80;

// Home and New. The first shelf takes bigger tiles, as on music.apple.com.
export function ShelvesPage({
  title,
  fetchShelves,
}: {
  title: string;
  fetchShelves: () => Promise<Shelf[]>;
}) {
  const { value: shelves, statusText } = useFetched(fetchShelves, [title], "untilScrolled");
  const shelfKeys = toRowKeys((shelves ?? []).map((shelf) => shelf.title));
  const rows: PageRow[] = (shelves ?? []).map((shelf, index) => ({
    key: shelfKeys[index],
    element: (
      <CardRow
        title={shelf.title}
        cards={shelf.items}
        sizePx={index === 0 ? firstShelfTileSizePx : tileSizePx}
      />
    ),
  }));

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 24, flexGrow: 1, minHeight: 0 }}>
      <text style={{ color: colors.text, fontSize: 28, fontWeight: 700 }}>{title}</text>
      {!shelves && <PageStatus text={statusText} />}
      {shelves && (
        <PageList rows={rows} isComplete estimatedRowHeightPx={shelfHeightPx} gapPx={24} />
      )}
    </div>
  );
}
