export function toClockText(totalSeconds: number): string {
  const wholeSeconds = Math.floor(totalSeconds);
  const minutes = Math.floor(wholeSeconds / 60);
  const seconds = wholeSeconds % 60;

  return `${minutes}:${String(seconds).padStart(2, "0")}`;
}
