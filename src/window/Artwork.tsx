import { useCallback, useSyncExternalStore } from "react";
import { readArtworkPath, subscribeToArtwork } from "../artwork.ts";
import { colors } from "../theme.ts";

// An image with a grey square in its place until it is on disk, or when there is none.
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
  const subscribe = useCallback(
    (onSaved: () => void) => (source ? subscribeToArtwork(source, onSaved) : () => {}),
    [source]
  );
  const path = useSyncExternalStore(subscribe, () => (source ? readArtworkPath(source) : null));

  if (!path) return <div style={{ ...style, backgroundColor: colors.card }} />;

  return <img src={path} objectFit="cover" style={style} />;
}
