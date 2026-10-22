package image

import "core:hash"
import "core:testing"

@(test)
test_to_family :: proc(t: ^testing.T) {
	family :: proc(text: string) -> u64 {return hash.fnv64a(transmute([]u8)text)}

	google :: "https://lh3.googleusercontent.com/__HQP1pw0-A2viS_fBJtlsYASW9dMYoP2B11fM30hMYHHWNHtmSET2bTvTGLZ66ySry6xJjQPx9dLA"
	testing.expect_value(t, to_family(google + "=w120-h120-p-l90-rj"), family(google))
	testing.expect(
		t,
		to_family(google + "=w120-h120") !=
		to_family("https://lh3.googleusercontent.com/other=w120-h120"),
	)
	testing.expect_value(
		t,
		to_family("https://is1-ssl.mzstatic.com/image/thumb/a/b.jpg/300x300bb.jpg"),
		family("https://is1-ssl.mzstatic.com/image/thumb/a/b.jpg"),
	)
	testing.expect_value(
		t,
		to_family("https://i.ytimg.com/vi/abc/hqdefault.jpg"),
		family("https://i.ytimg.com/vi/abc"),
	)
	testing.expect_value(t, to_family("/tmp/cover.jpg"), family("/tmp/cover.jpg"))
}
