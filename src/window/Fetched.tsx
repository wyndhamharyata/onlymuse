import { useEffect, useState, type DependencyList } from "react";
import { watchFetch } from "../apple-music.ts";
import { colors } from "../theme.ts";

type Fetched<Value> = { value: Value | null; statusText: string };

const loadingState = { value: null, statusText: "Loading…" };

// Stored answers show first. When Apple sends something newer, the page fetches again and keeps the old value meanwhile.
export function useFetched<Value>(
  fetchValue: () => Promise<Value>,
  dependencies: DependencyList
): Fetched<Value> {
  const [fetched, setFetched] = useState<Fetched<Value>>(loadingState);

  useEffect(() => {
    let isCurrent = true;
    let watched = startFetch();

    function startFetch(): ReturnType<typeof watchFetch<Value>> {
      const next = watchFetch(fetchValue, () => {
        next.stop();
        if (isCurrent) watched = startFetch();
      });

      next.value.then(
        (value) => isCurrent && setFetched({ value, statusText: "" }),
        (error) =>
          isCurrent &&
          setFetched({ value: null, statusText: `Apple Music could not be reached. ${error}` })
      );

      return next;
    }

    setFetched(loadingState);

    return () => {
      isCurrent = false;
      watched.stop();
    };
  }, dependencies);

  return fetched;
}

export function PageStatus({ text }: { text: string }) {
  return <text style={{ color: colors.dim, fontSize: 13 }}>{text}</text>;
}
