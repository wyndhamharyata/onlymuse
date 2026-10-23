#!/usr/bin/env -S python3 -I
import json
import os
import sys
import threading
import time
import zlib

speed = float(os.environ.get("OM_FAKE_SPEED", "1"))
missing_name = os.environ.get("OM_FAKE_MISSING", "")
unplayable_name = os.environ.get("OM_FAKE_UNPLAYABLE", "")
stall_name = os.environ.get("OM_FAKE_STALL", "")
slow_start_name = os.environ.get("OM_FAKE_SLOW_START", "")
SLOW_START_SECONDS = 7.0
yt_load_seconds = float(os.environ.get("OM_FAKE_YT_LOAD", "0"))
STALL_SECONDS = 5.0
POSITION_SECONDS = 2.0
TICK_SECONDS = 0.05
HOUR_SECONDS = 3600
DAY_SECONDS = 86400
tokens_folder = os.environ.get("OM_FAKE_TOKENS", "")
log = open(os.environ["OM_FAKE_LOG"], "a") if os.environ.get("OM_FAKE_LOG") else None
lock = threading.Lock()
ask_counts = {}
player = {"state": "stopped", "song": None, "position": 0.0, "read_at": time.time(), "volume": 50}
handoff = {"after": None, "song": None}
favourites = set()
play_counts = {}


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def to_persistent_id(song):
    if song.get("youtubeId"):
        return "yt:" + song["youtubeId"]
    return "%016X" % zlib.crc32(f"{song['name']}|{song['albumName']}".encode())


def position():
    if player["state"] != "playing":
        return player["position"]
    since = max(player["read_at"], player.get("starts_at", 0))
    moved = player["position"] + max(0, time.time() - since) * speed
    return min(moved, STALL_SECONDS) if player.get("is_stalling") else moved


def send_now_playing(**extra):
    if player["song"] is None or player["state"] == "stopped":
        send({"type": "nowPlaying", "state": "stopped", "volumePercent": player["volume"]})
        return
    song = player["song"]
    send({**extra, 
        "type": "nowPlaying", "state": player["state"], "volumePercent": player["volume"],
        "positionSeconds": position(), "positionReadAtMs": time.time() * 1000,
        "song": {"name": song["name"], "artist": song["artistName"], "album": song["albumName"],
                 "persistentID": to_persistent_id(song), "durationSeconds": song["durationSeconds"]},
    })


def to_song_info(persistent_id):
    added = time.time() - DAY_SECONDS * 40
    return {
        "type": "songInfo", "persistentID": persistent_id, "isInLibrary": True, "favorited": persistent_id in favourites,
        "playedCount": play_counts.get(persistent_id, 0), "playedDateMs": (time.time() - HOUR_SECONDS) * 1000, "skippedCount": 2,
        "skippedDateMs": (time.time() - DAY_SECONDS * 11) * 1000, "dateAddedMs": added * 1000, "rating": 0,
        "bitRate": 1411, "sampleRate": 48000, "kind": "Apple Lossless audio file", "bpm": 172, "size": 38200000,
    }


def start(song):
    persistent_id = to_persistent_id(song)
    play_counts[persistent_id] = play_counts.get(persistent_id, 0) + 1
    player["is_stalling"] = song["name"] == stall_name and play_counts[persistent_id] == 1
    is_slow = song["name"] == slow_start_name and play_counts[persistent_id] == 1
    player["starts_at"] = (time.time() + SLOW_START_SECONDS) if is_slow else 0
    player["is_loading"] = bool(song.get("youtubeId")) and yt_load_seconds > 0
    if player["is_loading"]:
        player["starts_at"] = time.time() + yt_load_seconds
    player.update(state="playing", song=song, position=0.0, read_at=time.time())
    if player["is_loading"]:
        send_now_playing(isLoading=True)
    else:
        send_now_playing()


def play_song(command):
    song = command["song"]
    ask_counts[song["name"]] = ask_counts.get(song["name"], 0) + 1
    if song["name"] == missing_name and ask_counts[song["name"]] <= 3:
        send({"type": "playSongResult", "requestId": command["requestId"], "persistentID": None})
        return
    if song["name"] != unplayable_name or song.get("youtubeId"):
        start(song)
    send({"type": "playSongResult", "requestId": command["requestId"], "persistentID": to_persistent_id(song)})


def set_next(command):
    handoff["after"] = command.get("afterPersistentID")
    handoff["song"] = command.get("song")
    result = to_persistent_id(handoff["song"]) if handoff["song"] else None
    send({"type": "setNextResult", "requestId": command["requestId"], "persistentID": result})


def play_pause(command):
    if not player["song"]:
        return
    player["position"] = position()
    player["read_at"] = time.time()
    player["state"] = "paused" if player["state"] == "playing" else "playing"
    send_now_playing()


def seek(command):
    if not player["song"]:
        return
    player["position"] = command["positionSeconds"]
    player["read_at"] = time.time()
    send_now_playing()


def song_info(command):
    send(to_song_info(command["persistentID"]))


def set_favorite(command):
    persistent_id = command.get("persistentID") or (to_persistent_id(command["song"]) if command.get("song") else None)
    if persistent_id and command["favorited"]:
        favourites.add(persistent_id)
    elif persistent_id:
        favourites.discard(persistent_id)
    message = {"type": "setFavoriteResult", "favorited": command["favorited"], "persistentID": persistent_id}
    if "requestId" in command:
        message["requestId"] = command["requestId"]
    send(message)
    if persistent_id:
        send(to_song_info(persistent_id))


def set_volume(command):
    player["volume"] = command["volumePercent"]
    send({"type": "volume", "volumePercent": player["volume"]})


HANDLERS = {
    "playSong": play_song,
    "setNext": set_next,
    "playPause": play_pause,
    "seek": seek,
    "songInfo": song_info,
    "setFavorite": set_favorite,
    "setVolume": set_volume,
}


def apply(command):
    handler = HANDLERS.get(command["type"])
    if handler:
        handler(command)


def tick():
    last_position_sent = time.time()
    while True:
        time.sleep(TICK_SECONDS)
        with lock:
            song = player["song"]
            is_loading = player.get("is_loading")
            if is_loading and time.time() < player["starts_at"]:
                continue
            if is_loading:
                player["is_loading"] = False
                send_now_playing(hasStarted=True)
                last_position_sent = time.time()
            is_playing = player["state"] == "playing" and song is not None
            is_position_due = is_playing and time.time() - last_position_sent >= POSITION_SECONDS
            if is_position_due:
                last_position_sent = time.time()
                send({"type": "position", "persistentID": to_persistent_id(song), "positionSeconds": position(), "positionReadAtMs": time.time() * 1000})
            is_song_over = is_playing and position() >= song["durationSeconds"]
            if not is_song_over:
                continue
            if handoff["song"] and handoff["after"] == to_persistent_id(song):
                next_song = handoff["song"]
                handoff.update(after=None, song=None)
                start(next_song)
                continue
            player.update(state="paused", position=0.0, read_at=time.time())
            send_now_playing()
            player["state"] = "stopped"
            send_now_playing()


send({"type": "accent", "color": "#F7821B"})
if tokens_folder:
    with open(os.path.join(tokens_folder, "dev")) as dev, open(os.path.join(tokens_folder, "mut")) as mut:
        send({"type": "tokens", "developerToken": dev.read().strip(), "userToken": mut.read().strip()})
cookie_path = os.path.join(tokens_folder, "yt-cookie")
cookie = open(cookie_path).read().strip() if tokens_folder and os.path.exists(cookie_path) else ""
send({"type": "youtubeCookie", "cookie": cookie})
send_now_playing()
threading.Thread(target=tick, daemon=True).start()

for line in sys.stdin:
    if log:
        log.write(line)
        log.flush()
    with lock:
        apply(json.loads(line))
