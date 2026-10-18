import { flushSync, useGpuixRequired, type PublicInstance } from "@gpuix/react";
import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { readTopRowKey, setTopRowKey, useNavigation } from "../navigation.ts";
import { countUnmountedRows, isMeasuring } from "../perf.tsx";

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

// The first row a list mounts. Most of the window lies ahead of the scroll, and it moves before a third is left.
export function toWindowStart(
  windowStart: number,
  event: { startIndex?: number; endIndex?: number },
  windowCount: number,
  previousFirstInView: number
): number {
  const firstInView = Math.floor(event.startIndex ?? 0);
  const lastInView = Math.ceil(event.endIndex ?? firstInView);
  const isGoingUp = firstInView < previousFirstInView;
  const rowsAheadCount = isGoingUp
    ? firstInView - windowStart
    : windowStart + windowCount - 1 - lastInView;
  const isInViewMounted = firstInView >= windowStart && lastInView < windowStart + windowCount;

  const hasRowsAhead = rowsAheadCount > windowCount / 3 || (isGoingUp && windowStart === 0);

  if (isInViewMounted && hasRowsAhead) return windowStart;

  const behindCount = Math.floor(windowCount / 4);

  return isGoingUp
    ? Math.max(0, lastInView + behindCount - windowCount + 1)
    : Math.max(0, firstInView - behindCount);
}

// A list mounts about this much height of rows, whatever its length.
const windowHeightPx = 6000;
const minWindowCount = 24;

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
  const windowCount = Math.max(minWindowCount, Math.ceil(windowHeightPx / estimatedRowHeightPx));
  const [windowStart, setWindowStart] = useState(0);
  const windowStartRef = useRef(0);
  const firstInViewRef = useRef(0);
  const rowStyle = useMemo(() => ({ paddingBottom: gapPx }), [gapPx]);
  const shownStart = Math.min(windowStart, Math.max(0, rows.length - 1));

  // The window moves to the saved row before the list scrolls there, so the list shows rows, not empty boxes.
  useEffect(() => {
    const key = pendingKey.current;
    const list = listRef.current;

    if (!key || !list) return;

    const rowIndex = rows.findIndex((row) => row.key === key || row.cardKeys?.includes(key));

    if (rowIndex >= 0) {
      windowStartRef.current = Math.max(0, rowIndex - Math.floor(windowCount / 4));
      setWindowStart(windowStartRef.current);
      renderer.scrollToItem?.(list.id, rowIndex);
    }

    if (rowIndex >= 0 || isComplete) pendingKey.current = null;
  }, [rows, isComplete, renderer, windowCount]);

  // The key waits until the saved row is back on screen, so a first draw of the top never replaces it.
  const onVisibleRange = (event: { startIndex?: number; endIndex?: number }): void => {
    const list = listRef.current;

    const firstInView = Math.floor(event.startIndex ?? 0);
    const lastInView = Math.ceil(event.endIndex ?? firstInView);
    const mountedEnd = windowStartRef.current + windowCount;
    const unmountedCount =
      Math.max(0, windowStartRef.current - firstInView) + Math.max(0, lastInView - mountedEnd);

    if (isMeasuring && unmountedCount > 0) countUnmountedRows(unmountedCount);

    const nextStart = toWindowStart(
      windowStartRef.current,
      event,
      windowCount,
      firstInViewRef.current
    );

    firstInViewRef.current = firstInView;

    // Only a move renders, and inside the scroll event, so the new rows are there for the frame it draws.
    if (nextStart !== windowStartRef.current) {
      windowStartRef.current = nextStart;
      flushSync(() => setWindowStart(nextStart));
    }

    if (pendingKey.current || !list) return;

    const [topIndex] = renderer.getListScrollTop?.(list.id) ?? [0];
    const topRow = rows[topIndex];

    if (topRow) setTopRowKey(historyIndex, topRow.key);
  };

  return (
    <virtual-list
      ref={listRef}
      itemCount={rows.length}
      windowStart={shownStart}
      estimatedItemHeight={estimatedRowHeightPx}
      onVisibleRange={onVisibleRange}
      style={{ flexGrow: 1, minHeight: 0 }}
    >
      {rows.slice(shownStart, shownStart + windowCount).map((row) => (
        <div key={row.key} style={rowStyle}>
          {row.element}
        </div>
      ))}
    </virtual-list>
  );
}
