import { createContext, useContext } from "react";

// The width a page has, inside its padding. The window works it out once, with the side panel open or closed.
export const ContentWidthContext = createContext(0);

export function useContentWidthPx(): number {
  return useContext(ContentWidthContext);
}
