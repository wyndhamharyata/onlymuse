import type { Card } from "../../apple-music.ts";
import { colors } from "../../theme.ts";
import { CardTile } from "../../window/Cards.tsx";
import { PageList, type PageRow } from "../../window/PageList.tsx";
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

  const rows: PageRow[] = [];

  for (let first = 0; first < (cards?.length ?? 0); first += columnCount) {
    const rowCards = (cards ?? []).slice(first, first + columnCount);

    rows.push({
      key: rowCards[0].id,
      cardKeys: rowCards.map((card) => card.id),
      element: (
        <div style={{ display: "flex", gap: gapPx }}>
          {rowCards.map((card) => (
            <CardTile key={card.id} card={card} sizePx={tileSizePx} isRound={isRound} />
          ))}
        </div>
      ),
    });
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
      {cards && <PageList rows={rows} isComplete estimatedRowHeightPx={rowHeightPx} gapPx={20} />}
    </div>
  );
}
