#!/usr/bin/env -S python3 -I
# Stands in for the Swift helper and Music.app in the tests. It never touches Music.app.
#   OM_HELPER=tools/fake-music.py ./build/onlymuse
# OM_FAKE_LOG      file that keeps every command the app sent
# OM_FAKE_SPEED    how many song seconds pass in one real second, 1 by default
# OM_FAKE_MISSING  a song name that is not in the library until it has been asked for 3 times
import json
import os
import sys
import threading
import time
import zlib

speed = float(os.environ.get("OM_FAKE_SPEED", "1"))
missing_name = os.environ.get("OM_FAKE_MISSING", "")
log = open(os.environ["OM_FAKE_LOG"], "a") if os.environ.get("OM_FAKE_LOG") else None
lock = threading.Lock()
asked = {}
player = {"state": "stopped", "song": None, "position": 0.0, "read_at": time.time(), "volume": 50}
handoff = {"after": None, "song": None}


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def to_persistent_id(match):
    return "%016X" % zlib.crc32(f"{match['name']}|{match['albumName']}".encode())


def position():
    if player["state"] != "playing":
        return player["position"]
    return player["position"] + (time.time() - player["read_at"]) * speed


def send_now_playing():
    if player["song"] is None or player["state"] == "stopped":
        send({"type": "nowPlaying", "state": "stopped", "volumePercent": player["volume"]})
        return
    song = player["song"]
    send({
        "type": "nowPlaying", "state": player["state"], "volumePercent": player["volume"],
        "positionSeconds": position(), "positionReadAtMs": time.time() * 1000,
        "song": {"name": song["name"], "artist": song["artistName"], "album": song["albumName"],
                 "persistentID": to_persistent_id(song), "durationSeconds": song["durationSeconds"]},
    })


def start(match):
    player.update(state="playing", song=match, position=0.0, read_at=time.time())
    send_now_playing()


def apply(command):
    kind = command["type"]
    if kind == "playSong":
        match = command["song"]
        asked[match["name"]] = asked.get(match["name"], 0) + 1
        if match["name"] == missing_name and asked[match["name"]] <= 3:
            send({"type": "playSongResult", "requestId": command["requestId"], "persistentID": None})
            return
        start(match)
        send({"type": "playSongResult", "requestId": command["requestId"], "persistentID": to_persistent_id(match)})
    elif kind == "setNext":
        handoff["after"] = command.get("afterPersistentID")
        handoff["song"] = command.get("song")
        result = to_persistent_id(handoff["song"]) if handoff["song"] else None
        send({"type": "setNextResult", "requestId": command["requestId"], "persistentID": result})
    elif kind == "playPause" and player["song"]:
        player["position"] = position()
        player["read_at"] = time.time()
        player["state"] = "paused" if player["state"] == "playing" else "playing"
        send_now_playing()
    elif kind == "seek" and player["song"]:
        player["position"] = command["positionSeconds"]
        player["read_at"] = time.time()
        send_now_playing()
    elif kind == "setVolume":
        player["volume"] = command["volumePercent"]
        send({"type": "volume", "volumePercent": player["volume"]})


# At a song's end Music.app posts Paused, then Stopped, unless the handoff starts the next song.
def tick():
    while True:
        time.sleep(0.05)
        with lock:
            song = player["song"]
            if player["state"] != "playing" or song is None or position() < song["durationSeconds"]:
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
send_now_playing()
threading.Thread(target=tick, daemon=True).start()

for line in sys.stdin:
    if log:
        log.write(line)
        log.flush()
    with lock:
        apply(json.loads(line))
