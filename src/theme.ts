export const colors = {
  window: "#1b1b1e",
  sidebar: "#212125",
  player: "#1f1f23",
  line: "#2e2e33",
  card: "#2a2a2f",
  hover: "#ffffff12",
  selected: "#ffffff1a",
  field: "#ffffff12",
  text: "#f2f2f4",
  dim: "#9b9ba3",
  faint: "#6b6b73",
  track: "#3a3a40",
};

export const sizes = {
  sidebarWidthPx: 228,
  playerHeightPx: 80,
  toolbarHeightPx: 52,
  pagePaddingPx: 30,
};

// Two hex digits of alpha, 0x2e of 0xff, about 18 percent, as the selected rows in the design.
export function toAccentTint(accent: string): string {
  return `${accent}2e`;
}
