import type { EventPayload } from "@gpuix/native";
import { useEffect, useState } from "react";
import { fetchLibraryPlaylists, type Playlist } from "../apple-music.ts";
import { Icon, type IconName } from "../icons.tsx";
import { useAccent } from "../helper.ts";
import { navigate, type Page, type PageId } from "../navigation.ts";
import { isText } from "../checks.ts";
import { readState, saveState } from "../store.ts";
import { colors, sizes } from "../theme.ts";

type Item = { id: PageId; label: string; icon: IconName };

const appleMusicItems: Item[] = [
  { id: "home", label: "Home", icon: "home" },
  { id: "new", label: "New", icon: "new" },
];

const libraryItems: Item[] = [
  { id: "favouriteSongs", label: "Favourite Songs", icon: "star" },
  { id: "recentlyAdded", label: "Recently Added", icon: "clock" },
  { id: "artists", label: "Artists", icon: "mic" },
  { id: "albums", label: "Albums", icon: "album" },
  { id: "songs", label: "Songs", icon: "note" },
  { id: "downloaded", label: "Downloaded", icon: "download" },
];

// The traffic lights take the top of the sidebar, from y = 17.
const trafficLightsHeightPx = 44;

function Group({ title }: { title: string }) {
  return (
    <text
      style={{
        color: colors.faint,
        fontSize: 11,
        fontWeight: 600,
        paddingLeft: 10,
        paddingTop: 14,
        paddingBottom: 4,
      }}
    >
      {title}
    </text>
  );
}

function Row({
  label,
  icon,
  iconColor,
  isSelected,
  onClick,
}: {
  label: string;
  icon: IconName;
  iconColor: string;
  isSelected: boolean;
  onClick: () => void;
}) {
  const background = isSelected ? colors.selected : undefined;

  return (
    <div
      onClick={onClick}
      style={{
        display: "flex",
        alignItems: "center",
        gap: 9,
        paddingLeft: 10,
        paddingRight: 10,
        paddingTop: 6,
        paddingBottom: 6,
        borderRadius: 7,
        backgroundColor: background,
        cursor: "pointer",
        hover: { backgroundColor: isSelected ? colors.selected : colors.hover },
      }}
    >
      <Icon name={icon} color={iconColor} sizePx={16} />
      <text
        style={{
          color: colors.text,
          fontSize: 13,
          whiteSpace: "nowrap",
          textOverflow: "ellipsis",
          minWidth: 0,
          flexShrink: 1,
          overflow: "hidden",
        }}
      >
        {label}
      </text>
    </div>
  );
}

function SearchField({ accent }: { accent: string }) {
  const [term, setShownTerm] = useState(readState("searchTerm", isText, ""));
  const setTerm = (next: string): void => {
    setShownTerm(next);
    saveState("searchTerm", next);
  };

  const search = (event: EventPayload): void => {
    const trimmedTerm = (event.value ?? term).trim();

    if (trimmedTerm) navigate({ id: "search", term: trimmedTerm });
  };

  return (
    <div
      style={{
        display: "flex",
        alignItems: "center",
        gap: 7,
        marginLeft: 2,
        marginRight: 2,
        marginBottom: 6,
        paddingLeft: 9,
        paddingRight: 9,
        paddingTop: 6,
        paddingBottom: 6,
        borderRadius: 8,
        backgroundColor: colors.field,
      }}
    >
      <Icon name="search" color={colors.faint} sizePx={14} />
      <input
        value={term}
        placeholder="Search"
        onChange={(event) => setTerm(event.value ?? "")}
        onSubmit={search}
        theme={{ caret: accent }}
        style={{ flexGrow: 1, minWidth: 0, color: colors.text, fontSize: 13 }}
      />
    </div>
  );
}

export function Sidebar({ page }: { page: Page }) {
  const accent = useAccent();
  const [playlists, setPlaylists] = useState<Playlist[]>([]);

  useEffect(() => {
    fetchLibraryPlaylists().then(setPlaylists, (error) =>
      console.error(`The playlists could not be fetched. ${error}`)
    );
  }, []);

  const shownPlaylists = playlists.filter((playlist) => !playlist.isFavouriteSongs);
  const isPlaylistSelected = (playlist: Playlist): boolean =>
    page.id === "playlist" && page.playlist.id === playlist.id;

  const renderItem = (item: Item) => (
    <Row
      key={item.id}
      label={item.label}
      icon={item.icon}
      iconColor={accent}
      isSelected={page.id === item.id}
      onClick={() => navigate({ id: item.id })}
    />
  );

  return (
    <div
      style={{
        width: sizes.sidebarWidthPx,
        flexShrink: 0,
        display: "flex",
        flexDirection: "column",
        paddingLeft: 10,
        paddingRight: 10,
        paddingTop: trafficLightsHeightPx,
        backgroundColor: colors.sidebar,
        borderRightWidth: 1,
        borderColor: colors.line,
      }}
    >
      <SearchField accent={accent} />
      <div
        style={{
          display: "flex",
          flexDirection: "column",
          gap: 1,
          flexGrow: 1,
          minHeight: 0,
          overflowY: "scroll",
          paddingBottom: 12,
        }}
      >
        <Group title="Apple Music" />
        {appleMusicItems.map(renderItem)}
        <Group title="Library" />
        {libraryItems.map(renderItem)}
        <Group title="Playlists" />
        {shownPlaylists.map((playlist) => (
          <Row
            key={playlist.id}
            label={playlist.name}
            icon="list"
            iconColor={colors.dim}
            isSelected={isPlaylistSelected(playlist)}
            onClick={() => navigate({ id: "playlist", playlist })}
          />
        ))}
      </div>
    </div>
  );
}
