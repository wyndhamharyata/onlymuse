import { render } from "@gpuix/react";
import { App } from "./app.tsx";
import { isMeasuring, Measured } from "./perf.tsx";

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
    trafficLightX: 16,
    trafficLightY: 17,
    focus: process.env.GPUIX_BACKGROUND !== "1",
    debugFrameOverlay: isMeasuring || process.env.ONLYMUSE_FRAMES === "1" ? "full" : "hidden",
  }
);
