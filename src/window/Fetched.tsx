import { useEffect, useState, type DependencyList } from "react";
import { colors } from "../theme.ts";

type Fetched<Value> = { value: Value | null; statusText: string };

// Every page loads its data from Apple once, and again when what it shows changes.
export function useFetched<Value>(
  fetchValue: () => Promise<Value>,
  dependencies: DependencyList
): Fetched<Value> {
  const [fetched, setFetched] = useState<Fetched<Value>>({ value: null, statusText: "Loading…" });

  useEffect(() => {
    let isCurrent = true;

    setFetched({ value: null, statusText: "Loading…" });
    fetchValue().then(
      (value) => isCurrent && setFetched({ value, statusText: "" }),
      (error) =>
        isCurrent &&
        setFetched({ value: null, statusText: `Apple Music could not be reached. ${error}` })
    );

    return () => {
      isCurrent = false;
    };
  }, dependencies);

  return fetched;
}

export function PageStatus({ text }: { text: string }) {
  return <text style={{ color: colors.dim, fontSize: 13 }}>{text}</text>;
}
