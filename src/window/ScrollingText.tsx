import { motion, useGpuixRequired, type PublicInstance } from "@gpuix/react";
import { useEffect, useRef, useState } from "react";

type TextStyle = { color: string; fontSize: number; fontWeight?: number };

// The text slides at this speed, so a long title takes longer to show in full.
const pixelsPerSecond = 40;
const slideDelaySeconds = 0.1;
// A row that only passes under the pointer during a scroll is gone before this, and draws nothing new.
const restDelayMs = 300;
// The full text gets a frame or two to be laid out before its width is read.
const measureDelayMs = 50;

type Hover = "none" | "resting" | "measuring" | "measured";

// One line of text that ends in "…" when it does not fit. On hover it slides to show the rest.
export function ScrollingText({ text, style }: { text: string; style: TextStyle }) {
  const renderer = useGpuixRequired();
  const boxRef = useRef<PublicInstance | null>(null);
  const fullTextRef = useRef<PublicInstance | null>(null);
  const hoverRef = useRef<Hover>("none");
  const [hover, setHover] = useState<Hover>("none");
  const [overflowPx, setOverflowPx] = useState(0);

  const moveTo = (next: Hover): void => {
    hoverRef.current = next;
    setHover(next);
  };

  useEffect(() => {
    if (hover !== "resting" && hover !== "measuring") return;

    // The full text is the line itself, freed from its box's width, so nothing new lies over the pointer.
    const timer = setTimeout(
      () => {
        if (hover === "resting") return moveTo("measuring");

        const box = boxRef.current && renderer.getElementBounds?.(boxRef.current.id);
        const fullText = fullTextRef.current && renderer.getElementBounds?.(fullTextRef.current.id);

        setOverflowPx(box && fullText ? Math.max(0, fullText.width - box.width) : 0);
        moveTo("measured");
      },
      hover === "resting" ? restDelayMs : measureDelayMs
    );

    return () => clearTimeout(timer);
  }, [hover, renderer]);

  // GPUI can report the pointer arriving again while it stays, so an arrival counts only from rest.
  const onEnter = (): void => {
    if (hoverRef.current === "none") moveTo("resting");
  };

  const onLeave = (): void => {
    if (hoverRef.current === "none") return;

    moveTo("none");
    setOverflowPx(0);
  };

  const isFull = hover === "measuring" || (hover === "measured" && overflowPx > 0);

  return (
    <div
      ref={boxRef}
      onMouseEnter={onEnter}
      onMouseLeave={onLeave}
      style={{ display: "flex", overflow: "hidden", minWidth: 0, flexShrink: 1 }}
    >
      {isFull ? (
        <motion.div
          initial={{ left: 0 }}
          animate={{ left: hover === "measured" ? -overflowPx : 0 }}
          transition={{
            duration: overflowPx / pixelsPerSecond,
            ease: "linear",
            delay: slideDelaySeconds,
          }}
          style={{ position: "relative", flexShrink: 0 }}
        >
          <text ref={fullTextRef} style={{ ...style, whiteSpace: "nowrap" }}>
            {text}
          </text>
        </motion.div>
      ) : (
        <text
          style={{
            ...style,
            whiteSpace: "nowrap",
            textOverflow: "ellipsis",
            overflow: "hidden",
            minWidth: 0,
          }}
        >
          {text}
        </text>
      )}
    </div>
  );
}
