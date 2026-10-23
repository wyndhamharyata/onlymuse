package platform

import "base:intrinsics"
import NS "core:sys/darwin/Foundation"
import "om:mac"

// The backdrop is the wallpaper of the window's screen, blurred once and kept in a layer, in place
// of AppKit's live blur. After Mission Control, while the screen records, the window server redoes
// a live blur on each frame and scrolling stutters. The layer shows the part of the wallpaper under
// the window.
// shortcut: windows under onlymuse do not show through, and a dynamic wallpaper shows its first
// image. Use the live blur again if the window ever floats over other windows.

// The blur is made at this many pixels per point of the screen, as it hides all fine detail.
BACKDROP_PIXELS_PER_POINT :: 0.5
// The blur's standard deviation in screen points. The live blur matches a Gaussian blur of about
// 30 points, measured on screen against the same content unblurred.
BACKDROP_BLUR_POINTS :: 30
// The live blur and the backdrop fade into each other this fast as a drag starts and ends.
BACKDROP_FADE_SECONDS :: 0.2
// How often a drag checks the mouse button.
DRAG_STEP_SECONDS :: 0.05

@(objc_class = "NSWorkspace")
Workspace :: struct {
	using _: NS.Object,
}

@(objc_class = "CIImage")
CI_Image :: struct {
	using _: NS.Object,
}

@(objc_class = "CIContext")
CI_Context :: struct {
	using _: NS.Object,
}

@(objc_class = "CATransaction")
Transaction :: struct {
	using _: NS.Object,
}

foreign import core_image "system:CoreImage.framework"

@(private = "file")
foreign core_image {
	kCIContextWorkingColorSpace: ^NS.String
}

Affine_Transform :: struct {
	a, b, c, d, tx, ty: NS.Float,
}

// A view whose layer holds the backdrop, or nil when the screen has no wallpaper as a still image.
@(private)
make_backdrop_view :: proc(content_rect: NS.Rect) -> ^NS.View {
	image := make_backdrop_image(state.ns_window->screen())
	if image == nil do return nil

	layer := objc_send(^Layer, Layer, "layer")
	objc_send(nil, layer, "setContentsGravity:", NS.AT("resize"))
	objc_send(nil, layer, "setContents:", image)
	mac.CGImageRelease(mac.Image_Ref(image))

	view := objc_send(
		^NS.View,
		objc_send(^NS.View, NS.View, "alloc"),
		"initWithFrame:",
		content_rect,
	)

	objc_send(nil, view, "setLayer:", layer)
	view->setWantsLayer(true)
	objc_send(nil, view, "setAutoresizingMask:", NS.UInteger(SIZE_WITH_SUPERVIEW))
	state.backdrop = layer
	state.backdrop_view = view

	return view
}

// AppKit says when a drag of the window starts, but not always when it ends. The backdrop moves
// only after the window does, so it fades out over the live blur until the mouse button is up.
@(private)
start_window_drag :: proc() {
	if state.backdrop_view == nil do return

	objc_send(nil, state.blur_view, "setHidden:", NS.BOOL(false))
	fade_backdrop(0)
	state.fade_steps = 0

	if state.drag_timer != nil do return

	state.drag_timer = objc_send(
		^NS.Timer,
		NS.Timer,
		"timerWithTimeInterval:target:selector:userInfo:repeats:",
		NS.TimeInterval(DRAG_STEP_SECONDS),
		state.target,
		intrinsics.objc_find_selector("dragTimerFired:"),
		rawptr(nil),
		NS.BOOL(true),
	)
	objc_send(
		nil,
		objc_send(^NS.RunLoop, NS.RunLoop, "mainRunLoop"),
		"addTimer:forMode:",
		state.drag_timer,
		NS.RunLoopCommonModes,
	)
}

// Waits for the mouse button to come up, then fades the backdrop in at the window's new place.
// The live blur hides once the fade ends.
@(private)
step_window_drag :: proc() {
	if state.fade_steps > 0 {
		state.fade_steps -= 1
		if state.fade_steps > 0 do return

		objc_send(nil, state.blur_view, "setHidden:", NS.BOOL(true))
		objc_send(nil, state.drag_timer, "invalidate")
		state.drag_timer = nil
		return
	}

	if objc_send(NS.UInteger, NS.Event, "pressedMouseButtons") & 1 != 0 do return

	move_backdrop()
	fade_backdrop(1)
	state.fade_steps = int(BACKDROP_FADE_SECONDS / DRAG_STEP_SECONDS) + 1
}

@(private = "file")
fade_backdrop :: proc(opacity: f32) {
	objc_send(nil, Transaction, "begin")
	objc_send(nil, Transaction, "setAnimationDuration:", NS.TimeInterval(BACKDROP_FADE_SECONDS))
	objc_send(nil, state.backdrop, "setOpacity:", opacity)
	objc_send(nil, Transaction, "commit")
}

// Makes the backdrop again, for a new screen, Space or wallpaper. The old one stays if the new
// wallpaper cannot be read.
@(private)
refresh_backdrop :: proc() {
	if state.backdrop == nil do return

	if image := make_backdrop_image(state.ns_window->screen()); image != nil {
		objc_send(nil, state.backdrop, "setContents:", image)
		mac.CGImageRelease(mac.Image_Ref(image))
	}

	move_backdrop()
}

// Shows the part of the blurred wallpaper that is under the window.
@(private)
move_backdrop :: proc() {
	screen := state.ns_window->screen()
	if state.backdrop == nil || screen == nil do return

	window := state.ns_window->frame()
	screen_rect := screen->frame()
	part := NS.Rect {
		{
			(window.origin.x - screen_rect.origin.x) / screen_rect.size.width,
			(window.origin.y - screen_rect.origin.y) / screen_rect.size.height,
		},
		{window.size.width / screen_rect.size.width, window.size.height / screen_rect.size.height},
	}

	// The part changes at once, without Core Animation's fade.
	objc_send(nil, Transaction, "begin")
	objc_send(nil, Transaction, "setDisableActions:", NS.BOOL(true))
	objc_send(nil, state.backdrop, "setContentsRect:", part)
	objc_send(nil, Transaction, "commit")
}

// The screen's wallpaper, filled to the screen as macOS shows it and blurred, as a CGImage the
// caller releases. Nil when the wallpaper is not a still image, such as a moving wallpaper.
@(private = "file")
make_backdrop_image :: proc(screen: ^NS.Screen) -> rawptr {
	if screen == nil do return nil

	workspace := objc_send(^Workspace, Workspace, "sharedWorkspace")
	url := objc_send(^NS.URL, workspace, "desktopImageURLForScreen:", screen)
	if url == nil do return nil

	wallpaper := objc_send(^CI_Image, CI_Image, "imageWithContentsOfURL:", url)
	if wallpaper == nil do return nil

	extent := objc_send(NS.Rect, wallpaper, "extent")
	if extent.size.width <= 0 || extent.size.height <= 0 do return nil

	size := screen->frame().size
	width := size.width * BACKDROP_PIXELS_PER_POINT
	height := size.height * BACKDROP_PIXELS_PER_POINT
	scale := max(width / extent.size.width, height / extent.size.height)

	// Fill: the wallpaper covers the screen at its own proportions, centred, with its edges cut.
	filled := objc_send(
		^CI_Image,
		wallpaper,
		"imageByApplyingTransform:",
		Affine_Transform {
			a = scale,
			d = scale,
			tx = (width - extent.size.width * scale) / 2 - extent.origin.x * scale,
			ty = (height - extent.size.height * scale) / 2 - extent.origin.y * scale,
		},
	)

	// The clamp repeats the edge pixels, so the blur does not darken the screen's edges.
	clamped := objc_send(^CI_Image, filled, "imageByClampingToExtent")
	blurred := objc_send(
		^CI_Image,
		clamped,
		"imageByApplyingGaussianBlurWithSigma:",
		NS.Float(BACKDROP_BLUR_POINTS * BACKDROP_PIXELS_PER_POINT),
	)

	// The live blur mixes sRGB values. Core Image mixes linear light by default, which comes out
	// about 7% brighter.
	srgb := mac.CGColorSpaceCreateWithName(mac.kCGColorSpaceSRGB)
	defer mac.CGColorSpaceRelease(srgb)
	options := objc_send(
		^NS.Dictionary,
		NS.Dictionary,
		"dictionaryWithObject:forKey:",
		rawptr(srgb),
		kCIContextWorkingColorSpace,
	)
	ci_context := objc_send(^CI_Context, CI_Context, "contextWithOptions:", options)

	return objc_send(
		rawptr,
		ci_context,
		"createCGImage:fromRect:",
		blurred,
		NS.Rect{{0, 0}, {width, height}},
	)
}
