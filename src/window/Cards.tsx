import { toArtworkUrl, type Card } from "../apple-music.ts";
import { openCard } from "../navigation.ts";
import { colors } from "../theme.ts";

// Twice the drawn size, for the Retina screen.
const pixelsPerPoint = 2;

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
  const artworkUrl = card.artwork ? toArtworkUrl(card.artwork, sizePx * pixelsPerPoint) : undefined;
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
      {artworkUrl ? (
        <img
          src={artworkUrl}
          objectFit="cover"
          style={{ width: sizePx, height: sizePx, borderRadius: radiusPx }}
        />
      ) : (
        <div
          style={{
            width: sizePx,
            height: sizePx,
            borderRadius: radiusPx,
            backgroundColor: colors.card,
          }}
        />
      )}
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

export function CardRow({
  title,
  cards,
  sizePx,
  isRound,
}: {
  title: string;
  cards: Card[];
  sizePx: number;
  isRound?: boolean;
}) {
  if (cards.length === 0) return null;

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
      <text style={{ color: colors.text, fontSize: 17, fontWeight: 700 }}>{title}</text>
      <div style={{ display: "flex", gap: 16, overflowX: "scroll" }}>
        {cards.map((card) => (
          <CardTile key={card.id} card={card} row={cards} sizePx={sizePx} isRound={isRound} />
        ))}
      </div>
    </div>
  );
}
