package platform

import "base:intrinsics"
import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
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

@(objc_class = "NSAlert")
Alert :: struct {
	using _: NS.Object,
}

// macOS's wallpaper agent keeps a copy of the wallpaper, filled to each screen, named after the
// SHA-256 of the file's path. The copy stays after the file is deleted.
// shortcut: a private folder that a macOS update may move. The live blur shows if it does.
@(private = "file")
SAVED_WALLPAPERS :: "Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/com.apple.wallpaper.caches/extension-com.apple.wallpaper.extension.image"
@(private = "file")
SAVED_WALLPAPER_KEY :: "isSavedWallpaperAllowed"
@(private = "file")
ALERT_FIRST_BUTTON :: 1000
// NSWindowAbove, for a subview over another.
@(private = "file")
ORDER_ABOVE :: 1

foreign import core_image "system:CoreImage.framework"

@(private = "file")
foreign core_image {
	kCIContextWorkingColorSpace: ^NS.String
}

Affine_Transform :: struct {
	a, b, c, d, tx, ty: NS.Float,
}

// Puts the backdrop over the live blur and hides the blur. The live blur stays when the screen
// has no wallpaper as a still image.
@(private)
add_backdrop :: proc() {
	image := make_backdrop_image(state.ns_window->screen())
	if image == nil do return

	layer := objc_send(^Layer, Layer, "layer")
	objc_send(nil, layer, "setContentsGravity:", NS.AT("resize"))
	objc_send(nil, layer, "setContents:", image)
	mac.CGImageRelease(mac.Image_Ref(image))

	content := state.ns_window->contentView()
	view := objc_send(
		^NS.View,
		objc_send(^NS.View, NS.View, "alloc"),
		"initWithFrame:",
		content->bounds(),
	)

	objc_send(nil, view, "setLayer:", layer)
	view->setWantsLayer(true)
	objc_send(nil, view, "setAutoresizingMask:", NS.UInteger(SIZE_WITH_SUPERVIEW))
	state.backdrop = layer
	state.backdrop_view = view
	objc_send(
		nil,
		content,
		"addSubview:positioned:relativeTo:",
		view,
		NS.Integer(ORDER_ABOVE),
		state.blur_view,
	)
	objc_send(nil, state.blur_view, "setHidden:", NS.BOOL(true))
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
	if wallpaper == nil do wallpaper = read_saved_wallpaper(url)
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

// The wallpaper agent's copy of a wallpaper whose file is gone. The folder is another app's data,
// so macOS asks the person before the first read.
@(private = "file")
read_saved_wallpaper :: proc(url: ^NS.URL) -> ^CI_Image {
	defaults := NS.UserDefaults.standardUserDefaults()
	if !objc_send(NS.BOOL, defaults, "boolForKey:", NS.AT(SAVED_WALLPAPER_KEY)) do return nil

	path := objc_send(^NS.String, url, "path")->odinString()
	digest := hash.hash_string(.SHA256, path, context.temp_allocator)
	name := string(hex.encode(digest, context.temp_allocator))
	folder := fmt.tprintf("%s/%s", os.get_env("HOME", context.temp_allocator), SAVED_WALLPAPERS)
	files, _ := os.read_all_directory_by_path(folder, context.temp_allocator)

	// One copy per screen size. The largest keeps the most detail for any screen.
	largest: os.File_Info
	for file in files {
		if strings.has_prefix(file.name, name) && file.size > largest.size do largest = file
	}
	if largest.fullpath == "" do return nil

	saved := NS.URL.alloc()->initFileURLWithPath(
		NS.String.alloc()->initWithOdinString(largest.fullpath),
	)
	defer saved->release()

	return objc_send(^CI_Image, CI_Image, "imageWithContentsOfURL:", saved)
}

// Runs once the window shows, so the live blur is behind the question. onlymuse says why before
// macOS asks, and asks once.
@(private)
ask_for_saved_wallpaper :: proc() {
	if state.backdrop != nil do return

	defaults := NS.UserDefaults.standardUserDefaults()
	key := NS.AT(SAVED_WALLPAPER_KEY)
	if objc_send(^NS.Object, defaults, "objectForKey:", key) != nil do return

	// A moving wallpaper has no file. Only a deleted file has a saved copy to read.
	workspace := objc_send(^Workspace, Workspace, "sharedWorkspace")
	url := objc_send(^NS.URL, workspace, "desktopImageURLForScreen:", state.ns_window->screen())
	if url == nil || os.exists(objc_send(^NS.String, url, "path")->odinString()) do return

	alert := objc_send(^Alert, objc_send(^Alert, Alert, "alloc"), "init")
	defer alert->release()
	objc_send(nil, alert, "setMessageText:", NS.AT("Your wallpaper's file is gone"))
	objc_send(
		nil,
		alert,
		"setInformativeText:",
		NS.AT(
			"OnlyMuse uses a pre-blurred copy of your wallpaper, seamlessly swapping between real and static blur to save system resources.\n\nAllowing access to your wallpaper folder enables this feature. Otherwise, full real-time blur will be used.",
		),
	)
	objc_send(nil, alert, "addButtonWithTitle:", NS.AT("Continue"))
	objc_send(nil, alert, "addButtonWithTitle:", NS.AT("Not Now"))
	is_allowed := objc_send(NS.Integer, alert, "runModal") == ALERT_FIRST_BUTTON

	defaults->setBoolForKey(NS.BOOL(is_allowed), key)
	if is_allowed do add_backdrop()
}
