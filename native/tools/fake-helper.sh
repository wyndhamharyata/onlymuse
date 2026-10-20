#!/bin/sh
# Stands in for the Swift helper in the tests: it says a song plays and never touches Music.app.
# OM_HELPER=tools/fake-helper.sh ./build/onlymuse. OM_FAKE_POSITION sets the song's position in seconds.
# OM_FAKE_NAME, OM_FAKE_ARTIST, OM_FAKE_ALBUM and OM_FAKE_DURATION name another song than soldier game.
now_ms=$(python3 -c 'import time; print(int(time.time() * 1000))')
echo '{"type":"accent","color":"#F7821B"}'
echo "{\"type\":\"nowPlaying\",\"state\":\"playing\",\"volumePercent\":50,\"positionSeconds\":${OM_FAKE_POSITION:-30},\"positionReadAtMs\":$now_ms,\"song\":{\"name\":\"${OM_FAKE_NAME:-soldier game}\",\"artist\":\"${OM_FAKE_ARTIST:-ADO}\",\"album\":\"${OM_FAKE_ALBUM:-soldier game - Single}\",\"persistentID\":\"F00D\",\"durationSeconds\":${OM_FAKE_DURATION:-221}}}"
# The app closes the pipe when it quits. OM_FAKE_LOG keeps the commands it sent.
cat > "${OM_FAKE_LOG:-/dev/null}"
