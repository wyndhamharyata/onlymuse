import { render } from "@gpuix/react";
import { App } from "./app.tsx";
import { isMeasuring, Measured } from "./perf.tsx";
import { markOnKey } from "./probe.ts";
import { isOpaque } from "./theme.ts";
import { zoomOnKey } from "./zoom.ts";

render(
  <Measured>
    <App />
  </Measured>,
  {
    title: "onlymuse",
    appName: "onlymuse",
    width: 1240,
    height: 800,
    minWidth: 900,
    minHeight: 560,
    titlebarTransparent: true,
    windowBackground: isOpaque ? "opaque" : "blurred",
    trafficLightX: 16,
    trafficLightY: 17,
    focus: process.env.GPUIX_BACKGROUND !== "1",
    onKeyDown: (event, renderer) => {
      zoomOnKey(event, renderer);

      markOnKey(event);
    },
    debugFrameOverlay: isMeasuring || process.env.ONLYMUSE_FRAMES === "1" ? "full" : "hidden",
  }
);
