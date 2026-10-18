import { motion, useGpuixRequired, type PublicInstance } from "@gpuix/react";
import { useEffect, useRef, useState } from "react";

type TextStyle = { color: string; fontSize: number; fontWeight?: number };

// The text slides at this speed, so a long title takes longer to show in full.
const pixelsPerSecond = 40;
const slideDelaySeconds = 0.1;
// A row that only passes under the pointer during a scroll is gone before this, and draws nothing new.
const restDelayMs = 300;
// The unseen copy gets a frame or two to be laid out before its width is read.
const measureDelayMs = 50;

// One line of text that ends in "…" when it does not fit. On hover it slides to show the rest.
export function ScrollingText({ text, style }: { text: string; style: TextStyle }) {
  const renderer = useGpuixRequired();
  const boxRef = useRef<PublicInstance | null>(null);
  const fullTextRef = useRef<PublicInstance | null>(null);
  const [isMeasuring, setIsMeasuring] = useState(false);
  const [overflowPx, setOverflowPx] = useState(0);
  const restTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);

  // Every frame lays out every element, so the full text is drawn unseen only while the pointer is on it.
  useEffect(() => {
    if (!isMeasuring) return;

    const timer = setTimeout(() => {
      const box = boxRef.current && renderer.getElementBounds?.(boxRef.current.id);
      const fullText = fullTextRef.current && renderer.getElementBounds?.(fullTextRef.current.id);

      if (box && fullText) setOverflowPx(Math.max(0, fullText.width - box.width));

      setIsMeasuring(false);
    }, measureDelayMs);

    return () => clearTimeout(timer);
  }, [isMeasuring, renderer]);

  useEffect(() => () => clearTimeout(restTimer.current), []);

  const waitForRest = (): void => {
    clearTimeout(restTimer.current);
    restTimer.current = setTimeout(() => setIsMeasuring(true), restDelayMs);
  };

  const stopSliding = (): void => {
    clearTimeout(restTimer.current);

    if (isMeasuring) setIsMeasuring(false);
    if (overflowPx > 0) setOverflowPx(0);
  };

  return (
    <div
      ref={boxRef}
      onMouseEnter={waitForRest}
      onMouseLeave={stopSliding}
      style={{ position: "relative", overflow: "hidden", minWidth: 0, flexShrink: 1 }}
    >
      {isMeasuring && (
        <text
          ref={fullTextRef}
          style={{ ...style, position: "absolute", whiteSpace: "nowrap", opacity: 0 }}
        >
          {text}
        </text>
      )}
      {overflowPx > 0 ? (
        <motion.div
          initial={{ left: 0 }}
          animate={{ left: -overflowPx }}
          transition={{
            duration: overflowPx / pixelsPerSecond,
            ease: "linear",
            delay: slideDelaySeconds,
          }}
          style={{ position: "relative" }}
        >
          <text style={{ ...style, whiteSpace: "nowrap" }}>{text}</text>
        </motion.div>
      ) : (
        <text
          style={{ ...style, whiteSpace: "nowrap", textOverflow: "ellipsis", overflow: "hidden" }}
        >
          {text}
        </text>
      )}
    </div>
  );
}
