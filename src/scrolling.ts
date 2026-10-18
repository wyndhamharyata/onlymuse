// When the user last scrolled a page, so a newer answer from Apple waits for the scroll to end.
let scrolledAtMs = 0;

export function markScrolled(): void {
  scrolledAtMs = Date.now();
}

export function readScrolledAtMs(): number {
  return scrolledAtMs;
}
