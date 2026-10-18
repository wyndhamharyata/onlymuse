import { motion, useGpuixRequired, type PublicInstance } from "@gpuix/react";
import { useRef, useState } from "react";

type TextStyle = { color: string; fontSize: number; fontWeight?: number };

// The text slides at this speed, so a long title takes longer to show in full.
const pixelsPerSecond = 40;
const slideDelaySeconds = 0.4;

// One line of text that ends in "…" when it does not fit. On hover it slides to show the rest.
export function ScrollingText({ text, style }: { text: string; style: TextStyle }) {
  const renderer = useGpuixRequired();
  const boxRef = useRef<PublicInstance | null>(null);
  const fullTextRef = useRef<PublicInstance | null>(null);
  const [overflowPx, setOverflowPx] = useState(0);

  // The full text is drawn unseen, so its width is known. Both widths are read when the pointer arrives.
  const startSliding = (): void => {
    const box = boxRef.current && renderer.getElementBounds?.(boxRef.current.id);
    const fullText = fullTextRef.current && renderer.getElementBounds?.(fullTextRef.current.id);

    if (box && fullText) setOverflowPx(Math.max(0, fullText.width - box.width));
  };

  return (
    <div
      ref={boxRef}
      onMouseEnter={startSliding}
      onMouseLeave={() => setOverflowPx(0)}
      style={{ position: "relative", overflow: "hidden", minWidth: 0, flexShrink: 1 }}
    >
      <text
        ref={fullTextRef}
        style={{ ...style, position: "absolute", whiteSpace: "nowrap", opacity: 0 }}
      >
        {text}
      </text>
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
