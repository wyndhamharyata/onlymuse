import { useGpuixRequired, type PublicInstance } from "@gpuix/react";
import { useEffect, useRef, useState, type ReactNode } from "react";
import { readTopRowKey, setTopRowKey, useNavigation } from "../navigation.ts";

// A grid row lists the keys of all its cards, so a saved card is found in whichever row holds it now.
export type PageRow = { key: string; element: ReactNode; cardKeys?: string[] };

// A key for each row, from what the row shows. A song that shows twice gets "#2" on its second key.
export function toRowKeys(ids: string[]): string[] {
  const counts = new Map<string, number>();

  return ids.map((id) => {
    const count = (counts.get(id) ?? 0) + 1;

    counts.set(id, count);

    return count === 1 ? id : `${id}#${count}`;
  });
}

// The first row a list mounts. It moves by a sixth of the window or more, so a scroll mounts rows in small groups.
export function toWindowStart(
  windowStart: number,
  event: { startIndex?: number; endIndex?: number },
  windowCount: number
): number {
  const firstInView = Math.floor(event.startIndex ?? 0);
  const lastInView = Math.ceil(event.endIndex ?? firstInView);
  const wantedStart = Math.max(0, firstInView - Math.floor(windowCount / 4));
  const isInViewMounted = firstInView >= windowStart && lastInView < windowStart + windowCount;
  const hasDrifted = Math.abs(wantedStart - windowStart) >= Math.floor(windowCount / 6);

  return isInViewMounted && !hasDrifted ? windowStart : wantedStart;
}

// A page that scrolls as rows. It saves the key of its top row, never a pixel offset, and returns to that row on the next visit.
export function PageList({
  rows,
  isComplete,
  estimatedRowHeightPx,
  gapPx,
}: {
  rows: PageRow[];
  isComplete: boolean;
  estimatedRowHeightPx: number;
  gapPx: number;
}) {
  const renderer = useGpuixRequired();
  const listRef = useRef<PublicInstance | null>(null);
  const [historyIndex] = useState(useNavigation().index);
  const pendingKey = useRef(readTopRowKey(historyIndex));

  useEffect(() => {
    const key = pendingKey.current;
    const list = listRef.current;

    if (!key || !list) return;

    const rowIndex = rows.findIndex((row) => row.key === key || row.cardKeys?.includes(key));

    if (rowIndex >= 0) renderer.scrollToItem?.(list.id, rowIndex);
    if (rowIndex >= 0 || isComplete) pendingKey.current = null;
  }, [rows, isComplete, renderer]);

  // The key waits until the saved row is back on screen, so a first draw of the top never replaces it.
  const saveTopRow = (): void => {
    const list = listRef.current;

    if (pendingKey.current || !list) return;

    const [topIndex] = renderer.getListScrollTop?.(list.id) ?? [0];
    const topRow = rows[topIndex];

    if (topRow) setTopRowKey(historyIndex, topRow.key);
  };

  return (
    <virtual-list
      ref={listRef}
      estimatedItemHeight={estimatedRowHeightPx}
      onVisibleRange={saveTopRow}
      style={{ flexGrow: 1, minHeight: 0 }}
    >
      {rows.map((row) => (
        <div key={row.key} style={{ paddingBottom: gapPx }}>
          {row.element}
        </div>
      ))}
    </virtual-list>
  );
}
