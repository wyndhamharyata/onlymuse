import { readArtworkSource } from "../artwork.ts";
import { colors } from "../theme.ts";

// An image with a grey square in its place when there is none. Apple's artwork comes from disk once saved.
export function Artwork({
  source,
  widthPx,
  heightPx,
  radiusPx,
}: {
  source?: string;
  widthPx: number;
  heightPx: number;
  radiusPx: number;
}) {
  // A long title next to it must not squeeze it narrower.
  const style = { width: widthPx, height: heightPx, borderRadius: radiusPx, flexShrink: 0 };

  if (!source) return <div style={{ ...style, backgroundColor: colors.card }} />;

  return <img src={readArtworkSource(source)} objectFit="cover" style={style} />;
}
