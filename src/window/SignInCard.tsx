import { useState } from "react";
import { sendToHelper, useHelper } from "../helper.ts";
import { colors } from "../theme.ts";

const cardWidthPx = 380;

export function SignInCard() {
  const { accent } = useHelper();
  const [isWaiting, setIsWaiting] = useState(false);

  const signIn = (): void => {
    setIsWaiting(true);
    sendToHelper({ type: "signIn" });
  };

  const buttonText = isWaiting ? "Open the sign-in window again" : "Sign In";

  return (
    <div
      style={{
        position: "absolute",
        top: 0,
        left: 0,
        right: 0,
        bottom: 0,
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        backgroundColor: "#000000a0",
      }}
    >
      <div
        style={{
          width: cardWidthPx,
          display: "flex",
          flexDirection: "column",
          gap: 12,
          padding: 24,
          borderRadius: 14,
          backgroundColor: colors.card,
          borderWidth: 1,
          borderColor: colors.line,
        }}
      >
        <text style={{ color: colors.text, fontSize: 18, fontWeight: 700 }}>
          Sign in to Apple Music
        </text>
        <text style={{ color: colors.dim, fontSize: 13, lineHeight: 19 }}>
          onlymuse reads Apple Music with the sign-in of music.apple.com. Apple's own sign-in page
          opens in a window of its own.
        </text>
        <div
          onClick={signIn}
          style={{
            display: "flex",
            justifyContent: "center",
            marginTop: 6,
            paddingTop: 9,
            paddingBottom: 9,
            borderRadius: 8,
            backgroundColor: accent,
            cursor: "pointer",
          }}
        >
          <text style={{ color: "#ffffff", fontSize: 13, fontWeight: 600 }}>{buttonText}</text>
        </div>
        {isWaiting && (
          <text style={{ color: colors.faint, fontSize: 12 }}>
            Waiting for you to sign in to Apple Music in its own window.
          </text>
        )}
      </div>
    </div>
  );
}
