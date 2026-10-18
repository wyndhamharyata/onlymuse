import { useGpuixRequired, type NativeRenderer } from "@gpuix/react";
import type { EventPayload } from "@gpuix/native";
import { findCatalogArtistId, toArtworkUrl, type CatalogSong } from "../apple-music.ts";
import { toClockText } from "../format.ts";
import { Icon, type IconName } from "../icons.tsx";
import { sendToHelper, useHelper, type Song } from "../helper.ts";
import { usePositionSeconds } from "../position.ts";
import { navigate } from "../navigation.ts";
import {
  cycleRepeat,
  findQueueSong,
  resumeLastSong,
  skipToNext,
  skipToPrevious,
  toggleShuffle,
  useQueue,
} from "../queue.ts";
import { colors, sizes } from "../theme.ts";
import { Artwork } from "./Artwork.tsx";
import { ScrollingText } from "./ScrollingText.tsx";
import type { Panel } from "./SidePanel.tsx";

const artworkSizePx = 52;

// The share of a bar's width left of the click, from 0 to 1.
function readClickRatio(renderer: NativeRenderer, event: EventPayload): number | null {
  const bounds = renderer.getElementBounds?.(event.elementId);

  if (!bounds || event.x === undefined || bounds.width === 0) return null;

  return Math.min(Math.max((event.x - bounds.x) / bounds.width, 0), 1);
}

// Go to Artist always opens the Apple Music artist, never the library one.
async function openArtist(artistName: string): Promise<void> {
  const artistId = await findCatalogArtistId(artistName);

  if (artistId) navigate({ id: "artist", artistId });
}

function Button({
  icon,
  color,
  sizePx,
  onClick,
}: {
  icon: IconName;
  color: string;
  sizePx: number;
  onClick?: () => void;
}) {
  return (
    <div
      onClick={onClick}
      style={{
        padding: 4,
        borderRadius: 6,
        cursor: onClick ? "pointer" : "default",
        hover: { backgroundColor: onClick ? colors.hover : undefined },
      }}
    >
      <Icon name={icon} color={color} sizePx={sizePx} />
    </div>
  );
}

function Bar({
  ratio,
  widthPx,
  onRatio,
}: {
  ratio: number;
  widthPx?: number;
  onRatio: (ratio: number) => void;
}) {
  const renderer = useGpuixRequired();

  const onClick = (event: EventPayload): void => {
    const clickRatio = readClickRatio(renderer, event);

    if (clickRatio !== null) onRatio(clickRatio);
  };

  return (
    <div
      onClick={onClick}
      style={{
        flexGrow: widthPx ? 0 : 1,
        width: widthPx,
        paddingTop: 6,
        paddingBottom: 6,
        cursor: "pointer",
      }}
    >
      <div style={{ height: 4, borderRadius: 2, backgroundColor: colors.track }}>
        <div
          style={{
            width: `${ratio * 100}%`,
            height: 4,
            borderRadius: 2,
            backgroundColor: colors.text,
            pointerEvents: "none",
          }}
        />
      </div>
    </div>
  );
}

function SongText({
  title,
  badge,
  subtitle,
  onSubtitleClick,
}: {
  title: string;
  badge?: string;
  subtitle: string;
  onSubtitleClick?: () => void;
}) {
  return (
    <div style={{ display: "flex", flexDirection: "column", minWidth: 0, flexGrow: 1 }}>
      <div style={{ display: "flex", alignItems: "center", gap: 7, minWidth: 0 }}>
        <ScrollingText
          text={title}
          style={{ color: colors.text, fontSize: 13.5, fontWeight: 600 }}
        />
        {badge && (
          <div
            style={{
              flexShrink: 0,
              paddingLeft: 4,
              paddingRight: 4,
              borderRadius: 4,
              borderWidth: 1,
              borderColor: colors.faint,
            }}
          >
            <text style={{ color: colors.dim, fontSize: 9.5, fontWeight: 700 }}>{badge}</text>
          </div>
        )}
      </div>
      <div
        onClick={onSubtitleClick}
        style={{ display: "flex", minWidth: 0, cursor: onSubtitleClick ? "pointer" : "default" }}
      >
        <ScrollingText text={subtitle} style={{ color: colors.dim, fontSize: 12.5 }} />
      </div>
    </div>
  );
}

function NowPlayingInfo({
  song,
  addingSong,
  placeholderText,
}: {
  song: Song | null;
  addingSong: CatalogSong | null;
  placeholderText: string;
}) {
  if (addingSong) {
    const artworkUrl = addingSong.artwork
      ? toArtworkUrl(addingSong.artwork, artworkSizePx * 2)
      : undefined;

    return (
      <div style={{ display: "flex", alignItems: "center", gap: 12, minWidth: 0 }}>
        <Artwork
          source={artworkUrl}
          widthPx={artworkSizePx}
          heightPx={artworkSizePx}
          radiusPx={6}
        />
        <SongText title={addingSong.name} subtitle="Adding to library…" />
      </div>
    );
  }

  if (!song) {
    return (
      <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
        <Artwork widthPx={artworkSizePx} heightPx={artworkSizePx} radiusPx={6} />
        <SongText title="Not playing" subtitle={placeholderText} />
      </div>
    );
  }

  const queueSong = findQueueSong(song.persistentID);
  const badge = queueSong?.isLossless ? "LOSSLESS" : undefined;
  const queueArtworkUrl = queueSong?.artwork && toArtworkUrl(queueSong.artwork, artworkSizePx * 2);

  return (
    <div style={{ display: "flex", alignItems: "center", gap: 12, minWidth: 0 }}>
      <Artwork
        source={queueArtworkUrl ?? song.artworkPath}
        widthPx={artworkSizePx}
        heightPx={artworkSizePx}
        radiusPx={6}
      />
      <SongText
        title={song.name}
        badge={badge}
        subtitle={`${song.artist} · ${song.album}`}
        onSubtitleClick={() => openArtist(song.artist)}
      />
    </div>
  );
}

export function PlayerBar({
  panel,
  onTogglePanel,
}: {
  panel: Panel | null;
  onTogglePanel: (panel: Panel) => void;
}) {
  const helper = useHelper();
  const queue = useQueue();
  const toToggleColor = (isOn: boolean): string => (isOn ? helper.accent : colors.faint);
  const nowPlaying = helper.nowPlaying;
  const isPlaying = nowPlaying.state === "playing";

  const playingPositionSeconds = usePositionSeconds();
  const hasSong = nowPlaying.state === "playing" || nowPlaying.state === "paused";
  const volumePercent = nowPlaying.state === "closed" ? 0 : nowPlaying.volumePercent;
  const addingSong = queue.isAdding ? queue.songs[queue.index] : null;

  // With Music.app stopped or closed, the player shows the last song, paused where it was.
  const resumePoint = hasSong ? null : queue.resumePoint;
  const shownSong = hasSong ? nowPlaying.song : (resumePoint?.song ?? null);
  const positionSeconds = resumePoint ? resumePoint.positionSeconds : playingPositionSeconds;
  const durationSeconds = shownSong?.durationSeconds ?? 0;
  const placeholderText =
    nowPlaying.state === "closed" ? "Music.app is closed" : "Nothing in Music.app";
  const playPause = resumePoint ? resumeLastSong : () => sendToHelper({ type: "playPause" });

  const progressRatio = durationSeconds > 0 ? positionSeconds / durationSeconds : 0;
  const playIcon = isPlaying ? "pause" : "play";

  const seek = (ratio: number): void => {
    if (hasSong) sendToHelper({ type: "seek", positionSeconds: ratio * durationSeconds });
  };

  const setVolume = (ratio: number): void =>
    sendToHelper({ type: "setVolume", volumePercent: Math.round(ratio * 100) });

  return (
    <div
      style={{
        height: sizes.playerHeightPx,
        flexShrink: 0,
        display: "flex",
        alignItems: "center",
        gap: 20,
        paddingLeft: 20,
        paddingRight: 20,
        borderTopWidth: 1,
        borderColor: colors.line,
        backgroundColor: colors.player,
      }}
    >
      <div style={{ flexGrow: 1, flexBasis: 0, minWidth: 0 }}>
        <NowPlayingInfo
          song={shownSong}
          addingSong={addingSong}
          placeholderText={placeholderText}
        />
      </div>
      <div
        style={{
          display: "flex",
          flexDirection: "column",
          alignItems: "center",
          gap: 6,
          flexGrow: 1.25,
          flexBasis: 0,
        }}
      >
        <div style={{ display: "flex", alignItems: "center", gap: 16 }}>
          <Button
            icon="shuffle"
            color={toToggleColor(queue.isShuffled)}
            sizePx={15}
            onClick={toggleShuffle}
          />
          <Button
            icon="previous"
            color={colors.text}
            sizePx={18}
            onClick={() => skipToPrevious(positionSeconds)}
          />
          <div
            onClick={playPause}
            style={{
              width: 34,
              height: 34,
              borderRadius: 17,
              backgroundColor: colors.text,
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              cursor: "pointer",
            }}
          >
            <Icon name={playIcon} color={colors.window} sizePx={16} />
          </div>
          <Button icon="next" color={colors.text} sizePx={18} onClick={skipToNext} />
          <div style={{ display: "flex", alignItems: "center" }}>
            <Button
              icon="repeat"
              color={toToggleColor(queue.repeat !== "off")}
              sizePx={15}
              onClick={cycleRepeat}
            />
            {queue.repeat === "one" && (
              <text style={{ color: helper.accent, fontSize: 10, fontWeight: 700 }}>1</text>
            )}
          </div>
        </div>
        <div style={{ display: "flex", alignItems: "center", gap: 10, width: "100%" }}>
          <text style={{ color: colors.faint, fontSize: 11 }}>{toClockText(positionSeconds)}</text>
          <Bar ratio={progressRatio} onRatio={seek} />
          <text style={{ color: colors.faint, fontSize: 11 }}>{toClockText(durationSeconds)}</text>
        </div>
      </div>
      <div
        style={{
          display: "flex",
          alignItems: "center",
          justifyContent: "flex-end",
          gap: 12,
          flexGrow: 1,
          flexBasis: 0,
        }}
      >
        <Button
          icon="lyrics"
          color={toToggleColor(panel === "lyrics")}
          sizePx={17}
          onClick={() => onTogglePanel("lyrics")}
        />
        <Button
          icon="queue"
          color={toToggleColor(panel === "queue")}
          sizePx={17}
          onClick={() => onTogglePanel("queue")}
        />
        <Icon name="volume" color={colors.dim} sizePx={16} />
        <Bar ratio={volumePercent / 100} widthPx={80} onRatio={setVolume} />
      </div>
    </div>
  );
}
