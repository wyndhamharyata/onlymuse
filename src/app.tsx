import { useWindowSize } from "@gpuix/react";
import { useState } from "react";
import {
  fetchNewShelves,
  fetchHomeShelves,
  fetchLibraryAlbums,
  fetchLibraryArtists,
  fetchRecentlyAdded,
} from "./apple-music.ts";
import { useHelper } from "./helper.ts";
import { Icon, type IconName } from "./icons.tsx";
import { goBack, goForward, useNavigation, type Page } from "./navigation.ts";
import { AlbumPage } from "./pages/album/AlbumPage.tsx";
import { ArtistPage } from "./pages/artist/ArtistPage.tsx";
import { CardGridPage } from "./pages/library/CardGridPage.tsx";
import {
  fetchCatalogPlaylistList,
  fetchDownloadedList,
  fetchFavouriteSongsList,
  fetchLibraryPlaylistList,
  fetchSongsList,
} from "./pages/library/lists.ts";
import { SongListPage } from "./pages/library/SongListPage.tsx";
import { ShelvesPage } from "./pages/shelves/ShelvesPage.tsx";
import { SearchPage } from "./pages/search/SearchPage.tsx";
import { colors, sizes } from "./theme.ts";
import { ContentWidthContext } from "./window/ContentWidth.tsx";
import { PlayerBar } from "./window/PlayerBar.tsx";
import { Sidebar } from "./window/Sidebar.tsx";
import { SidePanel, isPanel, panelWidthPx, type Panel } from "./window/SidePanel.tsx";
import { readState, saveState } from "./store.ts";
import { SignInCard } from "./window/SignInCard.tsx";

// The key makes each visit a new page, so a page never shows what the one before it loaded.
function PageContent({ page, visit }: { page: Page; visit: number }) {
  if (page.id === "home")
    return <ShelvesPage key={visit} title="Home" fetchShelves={fetchHomeShelves} />;
  if (page.id === "new")
    return <ShelvesPage key={visit} title="New" fetchShelves={fetchNewShelves} />;
  if (page.id === "artist") return <ArtistPage key={visit} artistId={page.artistId} />;
  if (page.id === "album") return <AlbumPage key={visit} albumId={page.albumId} />;
  if (page.id === "search") return <SearchPage key={visit} term={page.term} />;
  if (page.id === "albums")
    return <CardGridPage key={visit} title="Albums" fetchCards={fetchLibraryAlbums} />;
  if (page.id === "artists")
    return <CardGridPage key={visit} title="Artists" fetchCards={fetchLibraryArtists} isRound />;
  if (page.id === "recentlyAdded")
    return <CardGridPage key={visit} title="Recently Added" fetchCards={fetchRecentlyAdded} />;
  if (page.id === "favouriteSongs")
    return (
      <SongListPage key={visit} fetchList={fetchFavouriteSongsList} listKey="favouriteSongs" />
    );
  if (page.id === "songs")
    return <SongListPage key={visit} fetchList={fetchSongsList} listKey="songs" />;
  if (page.id === "downloaded")
    return <SongListPage key={visit} fetchList={fetchDownloadedList} listKey="downloaded" />;

  if (page.id === "catalogPlaylist") {
    const playlistId = page.playlistId;

    return (
      <SongListPage
        key={visit}
        fetchList={() => fetchCatalogPlaylistList(playlistId)}
        listKey={playlistId}
      />
    );
  }

  if (page.id !== "playlist") return null;

  const playlist = page.playlist;

  return (
    <SongListPage
      key={visit}
      fetchList={() => fetchLibraryPlaylistList(playlist)}
      listKey={playlist.id}
    />
  );
}

// These pages scroll inside their own list, so the page area around them stays still.
const listPageIds = new Set<Page["id"]>([
  "favouriteSongs",
  "songs",
  "downloaded",
  "playlist",
  "catalogPlaylist",
  "albums",
  "artists",
  "recentlyAdded",
  "album",
]);

function NavigationButton({
  icon,
  isEnabled,
  onClick,
}: {
  icon: IconName;
  isEnabled: boolean;
  onClick: () => void;
}) {
  return (
    <div
      onClick={isEnabled ? onClick : undefined}
      style={{
        padding: 5,
        borderRadius: 6,
        cursor: isEnabled ? "pointer" : "default",
        hover: { backgroundColor: isEnabled ? colors.hover : undefined },
      }}
    >
      <Icon name={icon} color={isEnabled ? colors.text : colors.faint} sizePx={18} />
    </div>
  );
}

export function App() {
  const navigation = useNavigation();
  const { isSignInNeeded } = useHelper();
  const [panel, setShownPanel] = useState(readState("panel", isPanel, null));
  const setPanel = (next: Panel | null): void => {
    setShownPanel(next);
    saveState("panel", next);
  };
  const togglePanel = (next: Panel): void => setPanel(panel === next ? null : next);
  const windowSize = useWindowSize();
  const panelWidth = panel ? panelWidthPx : 0;
  const contentWidthPx =
    windowSize.width - sizes.sidebarWidthPx - panelWidth - sizes.pagePaddingPx * 2;
  const page = navigation.pages[navigation.index];
  const canGoBack = navigation.index > 0;
  const canGoForward = navigation.index < navigation.pages.length - 1;
  const isListPage = listPageIds.has(page.id);

  return (
    <div
      style={{
        position: "relative",
        display: "flex",
        flexDirection: "column",
        width: "100%",
        height: "100%",
        backgroundColor: colors.window,
      }}
    >
      <div style={{ display: "flex", flexGrow: 1, minHeight: 0 }}>
        <Sidebar page={page} />
        <div style={{ display: "flex", flexDirection: "column", flexGrow: 1, minWidth: 0 }}>
          <div
            style={{
              display: "flex",
              alignItems: "center",
              gap: 4,
              height: sizes.toolbarHeightPx,
              flexShrink: 0,
              paddingLeft: 18,
            }}
          >
            <NavigationButton icon="back" isEnabled={canGoBack} onClick={goBack} />
            <NavigationButton icon="forward" isEnabled={canGoForward} onClick={goForward} />
          </div>
          <div
            style={{
              display: "flex",
              flexDirection: "column",
              flexGrow: 1,
              minHeight: 0,
              overflowY: isListPage ? "hidden" : "scroll",
              paddingLeft: sizes.pagePaddingPx,
              paddingRight: sizes.pagePaddingPx,
              paddingBottom: sizes.pagePaddingPx,
            }}
          >
            <ContentWidthContext.Provider value={contentWidthPx}>
              <PageContent page={page} visit={navigation.index} />
            </ContentWidthContext.Provider>
          </div>
        </div>
        {panel && <SidePanel panel={panel} onPanel={setPanel} />}
      </div>
      <PlayerBar panel={panel} onTogglePanel={togglePanel} />
      {isSignInNeeded && <SignInCard />}
    </div>
  );
}
