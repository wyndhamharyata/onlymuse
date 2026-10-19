import { useEffect, useState, type DependencyList } from "react";
import { watchFetch } from "../apple-music.ts";
import { readScrolledAtMs } from "../scrolling.ts";
import { colors } from "../theme.ts";
import { probe } from "../probe.ts";

type Fetched<Value> = { value: Value | null; statusText: string };

const loadingState = { value: null, statusText: "Loading…" };
// A newer answer waits until the page has not scrolled for this long.
const scrollRestMs = 1000;

// "untilScrolled" shows a newer answer only before the page is scrolled, else on the next visit. Home changes on every request.
export type NewerAnswer = "whenScrollRests" | "untilScrolled";

// Stored answers show first. When Apple sends something newer, the page fetches again and keeps the old value meanwhile.
export function useFetched<Value>(
  fetchValue: () => Promise<Value>,
  dependencies: DependencyList,
  newerAnswer: NewerAnswer = "whenScrollRests"
): Fetched<Value> {
  const [fetched, setFetched] = useState<Fetched<Value>>(loadingState);

  useEffect(() => {
    const openedAtMs = Date.now();
    let isCurrent = true;
    let hasValue = false;
    let restTimer: ReturnType<typeof setTimeout> | undefined;
    let watched = startFetch();

    // The first answer shows at once. A newer one waits, as newerAnswer says, so a scroll is never cut into.
    function showValue(value: Value): void {
      clearTimeout(restTimer);

      const scrolledAtMs = readScrolledAtMs();
      const hasScrolled = scrolledAtMs > openedAtMs;
      const restLeftMs = scrolledAtMs + scrollRestMs - Date.now();

      if (hasValue && newerAnswer === "untilScrolled" && hasScrolled) return probe("newerHeld");
      if (hasValue && restLeftMs > 0) {
        probe("newerWaits", { ms: Math.round(restLeftMs) });
        restTimer = setTimeout(() => isCurrent && showValue(value), restLeftMs);
        return;
      }

      probe(hasValue ? "newerShown" : "firstShown");
      hasValue = true;
      setFetched({ value, statusText: "" });
    }

    function startFetch(): ReturnType<typeof watchFetch<Value>> {
      const next = watchFetch(fetchValue, () => {
        next.stop();
        if (isCurrent) watched = startFetch();
      });

      next.value.then(
        (value) => isCurrent && showValue(value),
        (error) =>
          isCurrent &&
          setFetched({ value: null, statusText: `Apple Music could not be reached. ${error}` })
      );

      return next;
    }

    setFetched(loadingState);

    return () => {
      isCurrent = false;
      clearTimeout(restTimer);
      watched.stop();
    };
  }, dependencies);

  return fetched;
}

export function PageStatus({ text }: { text: string }) {
  return <text style={{ color: colors.dim, fontSize: 13 }}>{text}</text>;
}
