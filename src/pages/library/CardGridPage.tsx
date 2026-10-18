import type { Card } from "../../apple-music.ts";
import { colors } from "../../theme.ts";
import { CardTile } from "../../window/Cards.tsx";
import { useContentWidthPx } from "../../window/ContentWidth.tsx";
import { PageStatus, useFetched } from "../../window/Fetched.tsx";

const tileSizePx = 160;
const gapPx = 18;
// A tile is its artwork, then one or two lines of text.
const rowHeightPx = tileSizePx + 70;

// Albums, Artists and Recently Added. Each list row holds as many tiles as the page is wide.
export function CardGridPage({
  title,
  fetchCards,
  isRound,
}: {
  title: string;
  fetchCards: () => Promise<Card[]>;
  isRound?: boolean;
}) {
  const { value: cards, statusText } = useFetched(fetchCards, [title]);
  const widthPx = useContentWidthPx();
  const columnCount = Math.max(1, Math.floor((widthPx + gapPx) / (tileSizePx + gapPx)));

  const rows: Card[][] = [];

  for (let first = 0; first < (cards?.length ?? 0); first += columnCount) {
    rows.push((cards ?? []).slice(first, first + columnCount));
  }

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 16, flexGrow: 1, minHeight: 0 }}>
      <div style={{ display: "flex", flexDirection: "column" }}>
        <text style={{ color: colors.text, fontSize: 28, fontWeight: 700 }}>{title}</text>
        {cards && (
          <text style={{ color: colors.dim, fontSize: 13 }}>{`${cards.length} items`}</text>
        )}
      </div>
      {!cards && <PageStatus text={statusText} />}
      <virtual-list estimatedItemHeight={rowHeightPx} style={{ flexGrow: 1, minHeight: 0 }}>
        {rows.map((row) => (
          <div key={row[0].id} style={{ display: "flex", gap: gapPx, paddingBottom: 20 }}>
            {row.map((card) => (
              <CardTile key={card.id} card={card} sizePx={tileSizePx} isRound={isRound} />
            ))}
          </div>
        ))}
      </virtual-list>
    </div>
  );
}
