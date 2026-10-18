import { useGpuixRequired, type PublicInstance } from "@gpuix/react";
import { useRef, useState } from "react";
import { toArtworkUrl, type Card } from "../apple-music.ts";
import { openCard } from "../navigation.ts";
import { colors } from "../theme.ts";
import { Artwork } from "./Artwork.tsx";
import { useContentWidthPx } from "./ContentWidth.tsx";
import { toRowKeys } from "./PageList.tsx";

// Twice the drawn size, for the Retina screen.
const pixelsPerPoint = 2;
const cardGapPx = 16;
// Artwork is asked for in steps of this many pixels, so a resized window reuses the saved files.
const artworkStepPx = 100;

// The tile size that fits a whole number of tiles across widthPx, as close to targetPx as it can.
export function fitTileSizePx(widthPx: number, targetPx: number, gapPx: number): number {
  const count = Math.max(1, Math.round((widthPx + gapPx) / (targetPx + gapPx)));

  return Math.floor((widthPx - gapPx * (count - 1)) / count);
}
// Cards drawn past each edge of the shelf, so a fast scroll finds them already drawn.
const extraCardCount = 2;

export function CardTile({
  card,
  row,
  sizePx,
  isRound,
}: {
  card: Card;
  row?: Card[];
  sizePx: number;
  isRound?: boolean;
}) {
  const artworkPx = Math.ceil((sizePx * pixelsPerPoint) / artworkStepPx) * artworkStepPx;
  const artworkUrl = card.artwork ? toArtworkUrl(card.artwork, artworkPx) : undefined;
  const radiusPx = isRound ? sizePx / 2 : 8;
  const canOpen = card.kind !== "other";
  const textAlign = isRound ? "center" : "left";

  return (
    <div
      onClick={canOpen ? () => openCard(card, row ?? [card]) : undefined}
      style={{
        display: "flex",
        flexDirection: "column",
        gap: 3,
        width: sizePx,
        flexShrink: 0,
        cursor: canOpen ? "pointer" : "default",
      }}
    >
      <Artwork source={artworkUrl} widthPx={sizePx} heightPx={sizePx} radiusPx={radiusPx} />
      <text
        style={{
          color: colors.text,
          fontSize: 12.5,
          marginTop: 4,
          textAlign,
          whiteSpace: "nowrap",
          textOverflow: "ellipsis",
        }}
      >
        {card.name}
      </text>
      {!isRound && (
        <text
          style={{
            color: colors.dim,
            fontSize: 12,
            whiteSpace: "nowrap",
            textOverflow: "ellipsis",
          }}
        >
          {card.subtitle}
        </text>
      )}
    </div>
  );
}

// A shelf of whole tiles near sizePx, drawing only those in view. Empty boxes keep the width of the rest.
export function CardRow({
  title,
  cards,
  sizePx: targetSizePx,
  isRound,
}: {
  title: string;
  cards: Card[];
  sizePx: number;
  isRound?: boolean;
}) {
  const renderer = useGpuixRequired();
  const shelfRef = useRef<PublicInstance | null>(null);
  const widthPx = useContentWidthPx();
  const sizePx = fitTileSizePx(widthPx, targetSizePx, cardGapPx);
  const stepPx = sizePx + cardGapPx;
  const shownCount = Math.ceil(widthPx / stepPx) + extraCardCount * 2;
  const [firstIndex, setFirstIndex] = useState(0);

  if (cards.length === 0) return null;

  // A shelf can hold the same album twice.
  const cardKeys = toRowKeys(cards.map((card) => card.id));
  const lastIndex = Math.min(cards.length - 1, firstIndex + shownCount - 1);
  const beforeWidthPx = firstIndex * stepPx - cardGapPx;
  const afterWidthPx = (cards.length - 1 - lastIndex) * stepPx - cardGapPx;

  const moveWindow = (): void => {
    const shelf = shelfRef.current;
    const [offsetXPx] = (shelf && renderer.getScrollOffset?.(shelf.id)) ?? [0];
    const next = Math.max(0, Math.floor(-offsetXPx / stepPx) - extraCardCount);

    if (next !== firstIndex) setFirstIndex(next);
  };

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
      <text style={{ color: colors.text, fontSize: 17, fontWeight: 700 }}>{title}</text>
      <div
        ref={shelfRef}
        onScroll={moveWindow}
        style={{ display: "flex", gap: cardGapPx, overflowX: "scroll" }}
      >
        {beforeWidthPx > 0 && <div style={{ width: beforeWidthPx, flexShrink: 0 }} />}
        {cards.slice(firstIndex, lastIndex + 1).map((card, index) => (
          <CardTile
            key={cardKeys[firstIndex + index]}
            card={card}
            row={cards}
            sizePx={sizePx}
            isRound={isRound}
          />
        ))}
        {afterWidthPx > 0 && <div style={{ width: afterWidthPx, flexShrink: 0 }} />}
      </div>
    </div>
  );
}
