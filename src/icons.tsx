// The paths of design/index.html, drawn on a 24 by 24 grid.
const paths = {
  home: '<path d="M3 10.5 12 3l9 7.5V21h-6v-6H9v6H3z"/>',
  new: '<path d="M12 3l2.4 5.6L20 11l-5.6 2.4L12 19l-2.4-5.6L4 11l5.6-2.4z"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  mic: '<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/>',
  album: '<rect x="3" y="3" width="18" height="18" rx="3"/><circle cx="12" cy="12" r="3"/>',
  note: '<path d="M9 18V5l11-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="17" cy="16" r="3"/>',
  download: '<circle cx="12" cy="12" r="9"/><path d="M12 7v9M8 12l4 4 4-4"/>',
  list: '<path d="M4 6h16M4 12h16M4 18h10"/>',
  search: '<circle cx="11" cy="11" r="7"/><path d="m20 20-4-4"/>',
  shuffle:
    '<path d="M3 7h3c4 0 6 10 10 10h4M3 17h3c1.6 0 2.8-1.6 3.9-3.5M14 9.5C15 8 16.1 7 18 7h2M18 4l3 3-3 3M18 14l3 3-3 3"/>',
  repeat: '<path d="M4 11V9a3 3 0 0 1 3-3h13M17 3l3 3-3 3M20 13v2a3 3 0 0 1-3 3H4M7 21l-3-3 3-3"/>',
  queue: '<path d="M4 6h12M4 12h12M4 18h8M18 15v6l4-3z"/>',
  lyrics: '<path d="M4 5h16v11H9l-5 4z"/><path d="M8 9h8M8 12h5"/>',
  volume: '<path d="M4 9h4l5-4v14l-5-4H4z"/><path d="M16 9a4 4 0 0 1 0 6"/>',
  back: '<path d="m15 5-7 7 7 7"/>',
  forward: '<path d="m9 5 7 7-7 7"/>',
};

// A filled icon takes the colour as its fill instead of its stroke.
const filledPaths = {
  play: '<path d="M7 4v16l13-8z"/>',
  pause:
    '<rect x="6" y="4" width="4" height="16" rx="1"/><rect x="14" y="4" width="4" height="16" rx="1"/>',
  previous: '<path d="M11 6v12L3 12zM21 6v12l-8-6z"/>',
  next: '<path d="M3 6v12l8-6zM13 6v12l8-6z"/>',
  star: '<path d="M12 3.5l2.6 5.4 5.9.8-4.3 4.1 1 5.8L12 16.8l-5.2 2.8 1-5.8-4.3-4.1 5.9-.8z"/>',
};

type FilledName = keyof typeof filledPaths;
type StrokedName = keyof typeof paths;

export type IconName = StrokedName | FilledName;

function toSvg(body: string, paint: string): string {
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" ${paint} stroke-linecap="round" stroke-linejoin="round">${body}</svg>`;
}

// GPUI draws an icon as a mask tinted with style.color, so the markup paints in black.
function toIconSource(name: IconName): string {
  if (name in filledPaths) return toSvg(filledPaths[name as FilledName], 'fill="#000"');

  return toSvg(paths[name as StrokedName], 'fill="none" stroke="#000" stroke-width="1.9"');
}

export function Icon({ name, color, sizePx }: { name: IconName; color: string; sizePx: number }) {
  return (
    <svg
      source={toIconSource(name)}
      style={{ width: sizePx, height: sizePx, flexShrink: 0, color }}
    />
  );
}
