// AppKit gives this package the window, its events, text input, the blur, the clipboard and dates.
package platform

import "base:intrinsics"
import "base:runtime"
import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"
import CA "vendor:darwin/QuartzCore"

// objc_send calls the Objective-C method that a selector string names, such as "alloc".
objc_send :: intrinsics.objc_send

// Odin 2026-10 builds objc_send calls only in a program that looks up a class by name.
// @(init) runs this procedure before main. private = "file" hides it from the other files.
@(init, private = "file")
work_around_odin_7793 :: proc "contextless" () {
	_ = intrinsics.objc_find_class("NSObject")
}

// Returns true while it wants another frame, such as during an animation.
Frame_Proc :: proc() -> bool

Window :: struct {
	// The drawable for this frame, from the display link.
	drawable:         ^CA.MetalDrawable,
	device:           ^MTL.Device,
	layer:            ^CA.MetalLayer,
	size_points:      [2]f32,
	pixels_per_point: f32,
}

// @(private) keeps state inside the platform package.
@(private)
state: struct {
	app:                ^NS.Application,
	ns_window:          ^NS.Window,
	view:               ^NS.View,
	input_view:         ^NS.View,
	display_link:       ^Display_Link,
	target:             ^Target,
	timer:              ^NS.Timer,
	// Windows cover a background window. macOS stops its display link, so a timer runs its frames.
	is_background:      bool,
	frame_timer:        ^NS.Timer,
	is_link_running:    bool,
	// request_frame sets this during run_frame, so the link keeps running for one more frame.
	is_frame_requested: bool,
	is_closed:          bool,
	on_frame:           Frame_Proc,
	window:             Window,
	events:             [dynamic]Event,
	event_arena:        [2]runtime.Arena,
	event_arena_index:  int,
	// While a text field has focus, key presses go to input_view and its input method.
	is_text_input:      bool,
	// The length in bytes of the input method's unfinished text, 0 when there is none.
	marked_length:      int,
	// The caret of the focused field, in window points from the top left, for the input method.
	caret_rect:         [4]f32,
	// Odin passes each procedure a context that holds its allocators and logger. AppKit calls
	// each proc "c" with no context, so each one sets context to this copy first.
	odin_context:       runtime.Context,
}

// objc_class binds this struct to the Objective-C class CAMetalDisplayLink.
@(objc_class = "CAMetalDisplayLink")
Display_Link :: struct {
	// using embeds NS.Object, so a ^Display_Link can stand in for a ^NS.Object.
	using _: NS.Object,
}

// objc_implement makes Odin create the class OMTarget at startup, as a subclass of NSObject.
@(objc_class = "OMTarget", objc_superclass = NS.Object, objc_implement)
Target :: struct {
	using _: NS.Object,
}

// The attribute makes this procedure the Target method for metalDisplayLink:needsUpdate:.
// The update holds a drawable for the next screen refresh, so drawing never waits for one.
@(objc_type = Target, objc_implement, objc_name = "metalDisplayLink", objc_selector = "metalDisplayLink:needsUpdate:")
Target_metalDisplayLink :: proc "c" (self: ^Target, link: NS.id, update: ^NS.Object) {
	context = state.odin_context
	state.window.drawable = objc_send(^CA.MetalDrawable, update, "drawable")
	run_frame()
	state.window.drawable = nil
}

@(objc_type = Target, objc_implement, objc_name = "frameTimerFired", objc_selector = "frameTimerFired:")
Target_frameTimerFired :: proc "c" (self: ^Target, timer: NS.id) {
	context = state.odin_context
	run_frame()
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

// foreign import links a library under a name. The foreign block below declares its C procedures.
// The procedures live in libobjc, which Odin links into every Objective-C program.
foreign import objc_runtime "system:Foundation.framework"

@(private)
Objc_Super :: struct {
	receiver:    ^Blur_View,
	super_class: NS.Class,
}

// The procedures in this block use the C calling convention. private keeps them in this package.
@(default_calling_convention = "c", private)
foreign objc_runtime {
	objc_msgSendSuper :: proc(super: ^Objc_Super, selector: NS.SEL) ---
	sel_getName :: proc(selector: NS.SEL) -> cstring ---
	objc_getProtocol :: proc(name: cstring) -> rawptr ---
	class_addProtocol :: proc(class: rawptr, protocol: rawptr) -> NS.BOOL ---
}

@(private)
update_window_size :: proc() {
	bounds := state.view->bounds()
	pixels_per_point := f32(state.ns_window->backingScaleFactor())
	window := &state.window

	window.size_points = {f32(bounds.size.width), f32(bounds.size.height)}
	window.pixels_per_point = pixels_per_point

	window.layer->setDrawableSize(
		{
			bounds.size.width * NS.Float(pixels_per_point),
			bounds.size.height * NS.Float(pixels_per_point),
		},
	)
	objc_send(nil, window.layer, "setContentsScale:", NS.Float(pixels_per_point))
}

// Wakes the display link, or the timer of a background window, to run a frame on the next refresh.
request_frame :: proc "contextless" () {
	state.is_frame_requested = true
	if state.is_link_running do return

	state.is_link_running = true

	if !state.is_background {
		objc_send(nil, state.display_link, "setPaused:", NS.BOOL(false))
		return
	}

	FRAME_SECONDS :: 1.0 / 60

	state.frame_timer = objc_send(
		^NS.Timer,
		NS.Timer,
		"scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:",
		NS.TimeInterval(FRAME_SECONDS),
		state.target,
		intrinsics.objc_find_selector("frameTimerFired:"),
		rawptr(nil),
		NS.BOOL(true),
	)
	objc_send(
		nil,
		objc_send(^NS.RunLoop, NS.RunLoop, "mainRunLoop"),
		"addTimer:forMode:",
		state.frame_timer,
		NS.RunLoopCommonModes,
	)
}

// Runs the frame proc at the window's current size. It stops the display link, or the timer of a
// background window, once the app wants no more frames.
@(private)
run_frame :: proc() {
	pool := NS.AutoreleasePool.alloc()->init()
	// defer runs drain when run_frame returns, so the pool frees what the frame autoreleased.
	defer pool->drain()

	update_window_size()

	state.is_frame_requested = false
	wants_more := state.on_frame() || state.is_frame_requested

	clear(&state.events)
	// Two arenas take turns, so the text of this frame's events lasts through the next frame.
	state.event_arena_index = 1 - state.event_arena_index
	runtime.arena_free_all(&state.event_arena[state.event_arena_index])

	if wants_more || !state.is_link_running do return

	state.is_link_running = false

	if state.is_background {
		objc_send(nil, state.frame_timer, "invalidate")
		state.frame_timer = nil
	} else {
		objc_send(nil, state.display_link, "setPaused:", NS.BOOL(true))
	}
}

// Runs AppKit's events until the window closes.
run :: proc() {
	for !state.is_closed {
		pool := NS.AutoreleasePool.alloc()->init()
		event := state.app->nextEventMatchingMask(
			NS.EventMaskAny,
			NS.Date.distantFuture(),
			NS.DefaultRunLoopMode,
			true,
		)

		if event != nil && !take_event(event) do state.app->sendEvent(event)

		pool->drain()
	}
}

// Draws a frame after this many seconds, such as when the next lyric word starts.
request_frame_after :: proc(seconds: f64) {
	fire_date := objc_send(
		^NS.Date,
		NS.Date,
		"dateWithTimeIntervalSinceNow:",
		NS.TimeInterval(max(0, seconds)),
	)

	// An earlier timer stays. The frame it draws asks again for the later one.
	if state.timer != nil {
		pending := objc_send(^NS.Date, state.timer, "fireDate")

		if objc_send(NS.TimeInterval, pending, "timeIntervalSinceDate:", fire_date) <= 0 do return

		objc_send(nil, state.timer, "invalidate")
	}

	state.timer = objc_send(
		^NS.Timer,
		NS.Timer,
		"scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:",
		NS.TimeInterval(max(0, seconds)),
		state.target,
		intrinsics.objc_find_selector("timerFired:"),
		rawptr(nil),
		NS.BOOL(false),
	)
	// The timer also fires while the person resizes a window or a menu is open.
	objc_send(
		nil,
		NS.RunLoop.mainRunLoop(),
		"addTimer:forMode:",
		state.timer,
		NS.RunLoopCommonModes,
	)
}

// Wakes the event loop from any thread, so it sees a change made outside an event.
wake :: proc "contextless" () {
	// Worker threads call this. They have no autorelease pool for the event.
	pool := NS.AutoreleasePool.alloc()->init()
	defer pool->drain()

	event := NS.Event.otherEventWithType(.ApplicationDefined, {0, 0}, {}, 0, 0, nil, 0, 0, 0)
	state.app->postEvent(event, true)
}

// The largest the window can be on its screen, in points. The menu bar and the Dock take the rest.
screen_size_points :: proc() -> [2]f32 {
	visible := find_visible_frame()

	return {f32(visible.size.width), f32(visible.size.height)}
}

// Sets the smallest the window can be. A smaller window grows and keeps its top left where it is.
// It moves only as far as it must to stay on its screen.
set_min_size :: proc(min_size_points: [2]f32) {
	min_size := NS.Size{NS.Float(min_size_points.x), NS.Float(min_size_points.y)}

	objc_send(nil, state.ns_window, "setContentMinSize:", min_size)

	// The content fills the window, title bar included.
	frame := state.ns_window->frame()

	if frame.size.width >= min_size.width && frame.size.height >= min_size.height do return

	visible := find_visible_frame()
	size := NS.Size{max(frame.size.width, min_size.width), max(frame.size.height, min_size.height)}
	// AppKit's y goes up, so the top is the origin plus the height.
	top := frame.origin.y + frame.size.height
	origin := NS.Point{frame.origin.x, top - size.height}

	origin.x = max(
		visible.origin.x,
		min(origin.x, visible.origin.x + visible.size.width - size.width),
	)
	origin.y = max(
		visible.origin.y,
		min(origin.y, visible.origin.y + visible.size.height - size.height),
	)

	objc_send(
		nil,
		state.ns_window,
		"setFrame:display:animate:",
		NS.Rect{origin, size},
		NS.BOOL(true),
		NS.BOOL(!state.is_background),
	)
}

@(private)
find_visible_frame :: proc() -> NS.Rect {
	screen := objc_send(^NS.Screen, state.ns_window, "screen")
	if screen == nil do screen = NS.Screen.mainScreen()

	return screen->visibleFrame()
}

quit :: proc() {
	state.is_closed = true
	wake()
}
