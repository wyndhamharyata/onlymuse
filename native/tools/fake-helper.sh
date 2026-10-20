#!/bin/sh
# Stands in for the Swift helper in the tests: it says a song plays and never touches Music.app.
# OM_HELPER=tools/fake-helper.sh ./build/onlymuse. OM_FAKE_POSITION sets the song's position in seconds.
now_ms=$(python3 -c 'import time; print(int(time.time() * 1000))')
echo '{"type":"accent","color":"#F7821B"}'
echo "{\"type\":\"nowPlaying\",\"state\":\"playing\",\"volumePercent\":50,\"positionSeconds\":${OM_FAKE_POSITION:-30},\"positionReadAtMs\":$now_ms,\"song\":{\"name\":\"soldier game\",\"artist\":\"ADO\",\"album\":\"soldier game - Single\",\"persistentID\":\"F00D\",\"durationSeconds\":221}}"
# The app closes the pipe when it quits.
cat > /dev/null
