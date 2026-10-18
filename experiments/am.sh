#!/bin/sh
# usage: am.sh /v1/path?query — a GET to Apple's API with the web player's tokens.
# The tokens are read from $ONLYMUSE_TOKENS/dev and $ONLYMUSE_TOKENS/mut, kept outside the project.
t="${ONLYMUSE_TOKENS:-$TMPDIR/onlymuse}"
curl -s -w '\n%{http_code}' "https://amp-api.music.apple.com$1" \
  -H "Authorization: Bearer $(cat "$t/dev")" -H "media-user-token: $(cat "$t/mut")" \
  -H 'Origin: https://music.apple.com' -H 'Referer: https://music.apple.com/' \
  -H 'User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15'
