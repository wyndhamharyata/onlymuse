import { GpuixRenderer } from "@gpuix/native";
import { App, browserRendererAsTest, InProcessBackend, liveRendererAsTest, serveAutomationStdio, } from "./automation/client.js";
import { createRendererState } from "./renderer-state.js";
const DEFAULT_FRAME_MS = 8;
const FRAME_WAKE_FALLBACK_MS = 100;
export function createNativeRenderer(options = {}) {
    let renderer;
    renderer = new GpuixRenderer((error, event) => {
        if (error) {
            options.onError?.(error);
            return;
        }
        try {
            if (createRendererState(renderer).dispatch(event))
                options.onEvent?.(event);
        }
        catch (dispatchError) {
            options.onError?.(dispatchError);
        }
    });
    if (typeof process !== "undefined" && process.stdin && !process.stdin.isTTY) {
        const init = renderer.init.bind(renderer);
        renderer.init = (windowOptions) => {
            init(windowOptions);
            enableAutomation(renderer);
        };
    }
    return renderer;
}
export function startFrameLoop(renderer, options = {}) {
    if (!renderer.requiresTick())
        return { stop() { } };
    let timer;
    let stopped = false;
    const stop = () => {
        if (stopped)
            return;
        stopped = true;
        if (frameWake)
            renderer.setFrameWakeCallback?.(null);
        if (timer !== undefined)
            clearTimeout(timer);
        timer = undefined;
    };
    const loop = () => {
        if (stopped)
            return;
        if (timer !== undefined)
            clearTimeout(timer);
        timer = undefined;
        const started = performance.now();
        let running = true;
        try {
            running = renderer.tick();
        }
        catch (error) {
            options.onError?.(error);
        }
        if (running === false) {
            stop();
            options.onTerminated?.();
            return;
        }
        if (stopped)
            return;
        const delay = frameWake
            ? FRAME_WAKE_FALLBACK_MS
            : Math.max(0, (options.frameMs ?? DEFAULT_FRAME_MS) - (performance.now() - started));
        timer = setTimeout(loop, delay);
    };
    const frameWake = options.frameMs === undefined &&
        renderer.setFrameWakeCallback?.(loop) === true;
    loop();
    return { stop };
}
export function enableAutomation(renderer) {
    serveAutomationStdio(new InProcessBackend(liveRendererAsTest(renderer)));
}
export function installBrowserAutomation(renderer, existing) {
    if (existing)
        return existing;
    return new App(new InProcessBackend(browserRendererAsTest(renderer)));
}
//# sourceMappingURL=runtime.js.map