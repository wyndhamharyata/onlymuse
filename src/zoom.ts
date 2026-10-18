import type { EventPayload, NativeRenderer } from "@gpuix/react";
import { readState, saveState } from "./store.ts";

// The zoom of the whole window, as in a browser. The patched gpuix in vendor/ draws it.
const zoomSteps = [0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2];
const stateKey = "zoom";

const isZoomStep = (value: unknown): value is number => zoomSteps.includes(value as number);

let zoom = readState(stateKey, isZoomStep, 1);

// The published gpuix has no setContentZoom, so with it the keys do nothing.
function showZoom(renderer: NativeRenderer): void {
  const zoomRenderer = renderer as NativeRenderer & { setContentZoom?: (zoom: number) => void };

  zoomRenderer.setContentZoom?.(zoom);
}

// Brings back the zoom of the last run.
export function applySavedZoom(renderer: NativeRenderer): void {
  if (zoom !== 1) showZoom(renderer);
}

function toNextZoom(key: string | undefined): number | null {
  const index = zoomSteps.indexOf(zoom);

  if (key === "=" || key === "+") return zoomSteps[Math.min(index + 1, zoomSteps.length - 1)];
  if (key === "-") return zoomSteps[Math.max(index - 1, 0)];

  return key === "0" ? 1 : null;
}

// Cmd = or Cmd + zooms in, Cmd - zooms out, and Cmd 0 goes back to 100%.
export function zoomOnKey(event: EventPayload, renderer: NativeRenderer): void {
  const next = event.modifiers?.cmd ? toNextZoom(event.key) : null;

  if (next === null || next === zoom) return;

  zoom = next;
  showZoom(renderer);
  saveState(stateKey, zoom);
}
