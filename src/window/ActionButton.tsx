import { useAccent } from "../helper.ts";
import { Icon, type IconName } from "../icons.tsx";
import { colors } from "../theme.ts";

// Play and Shuffle on the artist and album pages. Play takes the accent.
export function ActionButton({
  label,
  icon,
  isPrimary,
  onClick,
}: {
  label: string;
  icon: IconName;
  isPrimary: boolean;
  onClick: () => void;
}) {
  const accent = useAccent();
  const background = isPrimary ? accent : colors.selected;

  return (
    <div
      onClick={onClick}
      style={{
        display: "flex",
        alignItems: "center",
        gap: 7,
        paddingLeft: 16,
        paddingRight: 16,
        paddingTop: 7,
        paddingBottom: 7,
        borderRadius: 8,
        backgroundColor: background,
        cursor: "pointer",
      }}
    >
      <Icon name={icon} color="#ffffff" sizePx={13} />
      <text style={{ color: "#ffffff", fontSize: 13, fontWeight: 600 }}>{label}</text>
    </div>
  );
}
