package platform

import "base:intrinsics"
import "base:runtime"
import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"
import "om:mac"
import CA "vendor:darwin/QuartzCore"

msg_send :: intrinsics.objc_send

// The 2026-10 compiler builds a message send only once the program looks up a class directly (odin-lang/Odin#7793).
@(init, private = "file")
work_around_odin_7793 :: proc "contextless" () {
	_ = intrinsics.objc_find_class("NSObject")
}

// Returns true while it wants another frame, such as during an animation.
Frame_Proc :: proc() -> bool

Window :: struct {
	// The drawable for this frame, from the display link.
	drawable:      ^CA.MetalDrawable,
	device:        ^MTL.Device,
	layer:         ^CA.MetalLayer,
	size_points:   [2]f32,
	pixels_per_point: f32,
}

@(private)
state: struct {
	app:             ^NS.Application,
	ns_window:       ^NS.Window,
	view:            ^NS.View,
	input_view:      ^NS.View,
	display_link:    ^Display_Link,
	target:          ^Target,
	timer:           ^NS.Timer,
	// A background window is covered, and macOS stops its display link, so a timer runs its frames.
	is_background:   bool,
	frame_timer:     ^NS.Timer,
	is_link_running: bool,
	// Set by request_frame while a frame is drawn, so the link keeps running for the next one.
	is_frame_requested: bool,
	is_closed:       bool,
	on_frame:        Frame_Proc,
	window:          Window,
	events:          [dynamic]Event,
	event_arena:     [2]runtime.Arena,
	event_arena_index: int,
	// While a text field is focused, key presses go through the view's input method.
	is_text_input:   bool,
	marked_length:   int,
	// The caret of the focused field, in window points from the top left, for the input method.
	caret_rect:      [4]f32,
	odin_context:    runtime.Context,
}

@(objc_class = "CAMetalDisplayLink")
Display_Link :: struct {
	using _: NS.Object,
}

@(objc_class = "OMTarget", objc_superclass = NS.Object, objc_implement)
Target :: struct {
	using _: NS.Object,
}

// CAMetalDisplayLinkDelegate. The update holds a drawable timed for the next refresh, so drawing never waits for one.
@(objc_type = Target, objc_implement, objc_name = "metalDisplayLink", objc_selector = "metalDisplayLink:needsUpdate:")
Target_metalDisplayLink :: proc "c" (self: ^Target, link: NS.id, update: ^NS.Object) {
	context = state.odin_context
	state.window.drawable = msg_send(^CA.MetalDrawable, update, "drawable")
	draw_frame()
	state.window.drawable = nil
}

@(objc_type = Target, objc_implement, objc_name = "frameTimerFired", objc_selector = "frameTimerFired:")
Target_frameTimerFired :: proc "c" (self: ^Target, timer: NS.id) {
	context = state.odin_context
	draw_frame()
}

@(objc_type = Target, objc_implement, objc_name = "timerFired", objc_selector = "timerFired:")
Target_timerFired :: proc "c" (self: ^Target, timer: NS.id) {
	state.timer = nil
	request_frame()
}

@(objc_type = Target, objc_implement, objc_name = "windowDidResize", objc_selector = "windowDidResize:")
Target_windowDidResize :: proc "c" (self: ^Target, notification: NS.id) {
	request_frame()
}

@(objc_type = Target, objc_implement, objc_name = "windowShouldClose", objc_selector = "windowShouldClose:")
Target_windowShouldClose :: proc "c" (self: ^Target, sender: NS.id) -> NS.BOOL {
	state.is_closed = true

	return true
}

// A background window, for the tests and the bench, opens behind the others and never takes focus.
// Its app is an accessory, so a tiling window manager such as AeroSpace leaves it alone.
open_window :: proc(title: string, size_points, min_size_points: [2]f32, on_frame: Frame_Proc, is_background := false) -> ^Window {
	state.odin_context = context
	state.on_frame = on_frame
	state.is_background = is_background

	app := NS.Application.sharedApplication()
	app->setActivationPolicy(.Accessory if is_background else .Regular)
	msg_send(nil, app, "finishLaunching")
	state.app = app

	content_rect := NS.Rect{{0, 0}, {NS.Float(size_points.x), NS.Float(size_points.y)}}
	style := NS.WindowStyleMask{.Titled, .Closable, .Miniaturizable, .Resizable, .FullSizeContentView}
	ns_window := NS.Window.alloc()->initWithContentRect(content_rect, style, .Buffered, false)
	ns_window->setTitle(NS.String.alloc()->initWithOdinString(title))
	ns_window->setTitlebarAppearsTransparent(true)
	msg_send(nil, ns_window, "setTitleVisibility:", NS.Integer(1))
	msg_send(nil, ns_window, "setReleasedWhenClosed:", NS.BOOL(false))
	msg_send(nil, ns_window, "setAcceptsMouseMovedEvents:", NS.BOOL(true))
	msg_send(nil, ns_window, "setContentMinSize:", NS.Size{NS.Float(min_size_points.x), NS.Float(min_size_points.y)})
	ns_window->setOpaque(false)
	ns_window->setBackgroundColor(msg_send(^NS.Color, NS.Color, "clearColor"))
	state.ns_window = ns_window

	blur := msg_send(^Blur_View, msg_send(^Blur_View, Blur_View, "alloc"), "initWithFrame:", content_rect)
	// NSVisualEffectMaterialSelection is colourless, NSVisualEffectStateActive keeps the blur when the window is not key.
	msg_send(nil, blur, "setMaterial:", NS.Integer(4))
	msg_send(nil, blur, "setState:", NS.Integer(1))
	ns_window->setContentView(blur)

	device := MTL.CreateSystemDefaultDevice()
	layer := CA.MetalLayer.layer()
	layer->setDevice(device)
	layer->setPixelFormat(.BGRA8Unorm)
	layer->setOpaque(false)
	layer->setFramebufferOnly(true)
	msg_send(nil, layer, "setColorspace:", srgb_color_space())

	view := msg_send(^NS.View, msg_send(^NS.View, NS.View, "alloc"), "initWithFrame:", content_rect)
	view->setLayer(layer)
	view->setWantsLayer(true)
	// NSViewWidthSizable | NSViewHeightSizable
	msg_send(nil, view, "setAutoresizingMask:", NS.UInteger(2 | 16))
	blur->addSubview(view)
	state.view = view

	// AppKit gives a view an input context only when its class says it is an NSTextInputClient. Without
	// one, keys go to NSResponder's insertText: and an input method never starts.
	input_class := intrinsics.objc_find_class("OMInputView")
	class_addProtocol(rawptr(input_class), objc_getProtocol("NSTextInputClient"))
	input_view := msg_send(^NS.View, msg_send(^Text_View, Text_View, "alloc"), "initWithFrame:", NS.Rect{{0, 0}, {1, 1}})
	blur->addSubview(input_view)
	state.input_view = input_view

	target := msg_send(^Target, msg_send(^Target, Target, "alloc"), "init")
	ns_window->setDelegate(cast(^NS.WindowDelegate)target)
	state.target = target

	link := msg_send(^Display_Link, msg_send(^Display_Link, Display_Link, "alloc"), "initWithMetalLayer:", layer)
	msg_send(nil, link, "setDelegate:", target)
	// Frames queued ahead of the screen. 1 is the shortest wait from input to screen.
	msg_send(nil, link, "setPreferredFrameLatency:", f32(1))
	msg_send(nil, link, "addToRunLoop:forMode:", NS.RunLoop.mainRunLoop(), NS.RunLoopCommonModes)
	msg_send(nil, link, "setPaused:", NS.BOOL(true))
	state.display_link = link

	state.window = Window {
		device = device,
		layer  = layer,
	}
	update_window_size()

	ns_window->center()

	if is_background {
		// NSWindowCollectionBehaviorTransient | IgnoresCycle: no Spaces, Mission Control or Cmd ` for it.
		msg_send(nil, ns_window, "setCollectionBehavior:", NS.UInteger(1 << 3 | 1 << 6))
		msg_send(nil, ns_window, "orderBack:", rawptr(nil))
	} else {
		ns_window->makeKeyAndOrderFront(nil)
		app->activate()
	}
	request_frame()

	return &state.window
}

// Odin links libobjc for every Objective-C program, so the symbol comes through Foundation.
foreign import objc_runtime "system:Foundation.framework"

@(private)
Objc_Super :: struct {
	receiver:    ^Blur_View,
	super_class: NS.Class,
}

@(default_calling_convention = "c", private)
foreign objc_runtime {
	objc_msgSendSuper :: proc(super: ^Objc_Super, selector: NS.SEL) ---
	sel_getName :: proc(selector: NS.SEL) -> cstring ---
	objc_getProtocol :: proc(name: cstring) -> rawptr ---
	class_addProtocol :: proc(class: rawptr, protocol: rawptr) -> NS.BOOL ---
}

@(private)
srgb_color_space :: proc() -> rawptr {
	return rawptr(mac.CGColorSpaceCreateWithName(mac.kCGColorSpaceSRGB))
}

@(private)
update_window_size :: proc() {
	bounds := state.view->bounds()
	pixels_per_point := f32(state.ns_window->backingScaleFactor())
	window := &state.window
	window.size_points = {f32(bounds.size.width), f32(bounds.size.height)}
	window.pixels_per_point = pixels_per_point
	window.layer->setDrawableSize({bounds.size.width * NS.Float(pixels_per_point), bounds.size.height * NS.Float(pixels_per_point)})
	msg_send(nil, window.layer, "setContentsScale:", NS.Float(pixels_per_point))
}

// Wakes the display link, which calls the frame proc on the next refresh of the screen.
request_frame :: proc "contextless" () {
	state.is_frame_requested = true
	if state.is_link_running do return

	state.is_link_running = true

	if !state.is_background {
		msg_send(nil, state.display_link, "setPaused:", NS.BOOL(false))
		return
	}

	FRAME_SECONDS :: 1.0 / 60
	state.frame_timer = msg_send(^NS.Timer, NS.Timer, "scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:", NS.TimeInterval(FRAME_SECONDS), state.target, intrinsics.objc_find_selector("frameTimerFired:"), rawptr(nil), NS.BOOL(true))
	msg_send(nil, msg_send(^NS.RunLoop, NS.RunLoop, "mainRunLoop"), "addTimer:forMode:", state.frame_timer, NS.RunLoopCommonModes)
}

@(private)
draw_frame :: proc() {
	pool := NS.AutoreleasePool.alloc()->init()
	defer pool->drain()

	update_window_size()

	state.is_frame_requested = false
	wants_more := state.on_frame() || state.is_frame_requested

	clear(&state.events)
	state.event_arena_index = 1 - state.event_arena_index
	runtime.arena_free_all(&state.event_arena[state.event_arena_index])

	if !wants_more && state.is_link_running {
		state.is_link_running = false

		if state.is_background {
			msg_send(nil, state.frame_timer, "invalidate")
			state.frame_timer = nil
		} else {
			msg_send(nil, state.display_link, "setPaused:", NS.BOOL(true))
		}
	}
}

// Runs AppKit's events until the window closes.
run :: proc() {
	for !state.is_closed {
		pool := NS.AutoreleasePool.alloc()->init()
		event := state.app->nextEventMatchingMask(NS.EventMaskAny, NS.Date.distantFuture(), NS.DefaultRunLoopMode, true)

		if event != nil {
			is_taken := take_event(event)

			if !is_taken do state.app->sendEvent(event)
		}
		pool->drain()
	}
}

// Draws a frame after this many seconds, such as when the next lyric word starts.
request_frame_after :: proc(seconds: f64) {
	fire_date := msg_send(^NS.Date, NS.Date, "dateWithTimeIntervalSinceNow:", NS.TimeInterval(max(0, seconds)))

	// An earlier timer stays. The frame it draws asks again for the later one.
	if state.timer != nil {
		pending := msg_send(^NS.Date, state.timer, "fireDate")
		if msg_send(NS.TimeInterval, pending, "timeIntervalSinceDate:", fire_date) <= 0 do return

		msg_send(nil, state.timer, "invalidate")
	}

	state.timer = msg_send(^NS.Timer, NS.Timer, "scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:", NS.TimeInterval(max(0, seconds)), state.target, intrinsics.objc_find_selector("timerFired:"), rawptr(nil), NS.BOOL(false))
	// The timer also fires while a window is resized or a menu is open.
	msg_send(nil, NS.RunLoop.mainRunLoop(), "addTimer:forMode:", state.timer, NS.RunLoopCommonModes)
}

// Wakes the event loop from any thread, so it sees a change made outside an event.
wake :: proc "contextless" () {
	// Worker threads call this, and they have no autorelease pool for the event.
	pool := NS.AutoreleasePool.alloc()->init()
	defer pool->drain()

	event := NS.Event.otherEventWithType(.ApplicationDefined, {0, 0}, {}, 0, 0, nil, 0, 0, 0)
	state.app->postEvent(event, true)
}

// The most the window can be on its screen, in points: the screen less the menu bar and the Dock.
screen_size_points :: proc() -> [2]f32 {
	visible := find_visible_frame()

	return {f32(visible.size.width), f32(visible.size.height)}
}

// Sets the smallest the window can be. A window smaller than that grows, keeping its top left where it
// is, and moves only as far as it must to stay on its screen.
set_min_size :: proc(min_size_points: [2]f32) {
	min_size := NS.Size{NS.Float(min_size_points.x), NS.Float(min_size_points.y)}
	msg_send(nil, state.ns_window, "setContentMinSize:", min_size)

	// The content fills the window, title bar included.
	frame := state.ns_window->frame()
	if frame.size.width >= min_size.width && frame.size.height >= min_size.height do return

	visible := find_visible_frame()
	size := NS.Size{max(frame.size.width, min_size.width), max(frame.size.height, min_size.height)}
	// AppKit's y goes up, so the top is the origin plus the height.
	top := frame.origin.y + frame.size.height
	origin := NS.Point{frame.origin.x, top - size.height}
	origin.x = max(visible.origin.x, min(origin.x, visible.origin.x + visible.size.width - size.width))
	origin.y = max(visible.origin.y, min(origin.y, visible.origin.y + visible.size.height - size.height))

	msg_send(nil, state.ns_window, "setFrame:display:animate:", NS.Rect{origin, size}, NS.BOOL(true), NS.BOOL(!state.is_background))
}

@(private)
find_visible_frame :: proc() -> NS.Rect {
	screen := msg_send(^NS.Screen, state.ns_window, "screen")
	if screen == nil do screen = NS.Screen.mainScreen()

	return screen->visibleFrame()
}

quit :: proc() {
	state.is_closed = true
	wake()
}
