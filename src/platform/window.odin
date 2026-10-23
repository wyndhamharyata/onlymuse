package platform

import "base:intrinsics"
import "base:runtime"
import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"
import CA "vendor:darwin/QuartzCore"

objc_send :: intrinsics.objc_send

// Odin 2026-10 builds objc_send calls only in a program that looks up a class by name.
@(init, private = "file")
find_class_for_objc_send :: proc "contextless" () {
	_ = intrinsics.objc_find_class("NSObject")
}

Frame_Proc :: proc() -> bool

Window :: struct {
	drawable:         ^CA.MetalDrawable,
	device:           ^MTL.Device,
	layer:            ^CA.MetalLayer,
	size_points:      [2]f32,
	pixels_per_point: f32,
}

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
	is_frame_requested: bool,
	is_closed:          bool,
	on_frame:           Frame_Proc,
	window:             Window,
	events:             [dynamic]Event,
	event_arena:        [2]runtime.Arena,
	event_arena_index:  int,
	is_text_input:      bool,
	marked_byte_count:  int,
	caret_rect:         [4]f32,
	blur_view:          ^NS.View,
	backdrop:           ^Layer,
	backdrop_view:      ^NS.View,
	drag_timer:         ^NS.Timer,
	fade_steps:         int,
	odin_context:       runtime.Context,
}

@(objc_class = "CAMetalDisplayLink")
Display_Link :: struct {
	using _: NS.Object,
}

@(objc_class = "OMTarget", objc_superclass = NS.Object, objc_implement)
Target :: struct {
	using _: NS.Object,
}

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
	context = state.odin_context
	set_backdrop_part()
	request_frame()
}

@(objc_type = Target, objc_implement, objc_name = "windowDidMove", objc_selector = "windowDidMove:")
Target_windowDidMove :: proc "c" (self: ^Target, notification: NS.id) {
	context = state.odin_context
	set_backdrop_part()
}

@(objc_type = Target, objc_implement, objc_name = "windowWillMove", objc_selector = "windowWillMove:")
Target_windowWillMove :: proc "c" (self: ^Target, notification: NS.id) {
	context = state.odin_context
	start_window_drag()
}

@(objc_type = Target, objc_implement, objc_name = "dragTimerFired", objc_selector = "dragTimerFired:")
Target_dragTimerFired :: proc "c" (self: ^Target, timer: NS.id) {
	context = state.odin_context
	step_window_drag()
}

@(objc_type = Target, objc_implement, objc_name = "windowDidChangeScreen", objc_selector = "windowDidChangeScreen:")
Target_windowDidChangeScreen :: proc "c" (self: ^Target, notification: NS.id) {
	context = state.odin_context
	apply_screen_change()
	request_frame()
}

@(objc_type = Target, objc_implement, objc_name = "windowDidBecomeKey", objc_selector = "windowDidBecomeKey:")
Target_windowDidBecomeKey :: proc "c" (self: ^Target, notification: NS.id) {
	context = state.odin_context
	apply_screen_change()
}

@(objc_type = Target, objc_implement, objc_name = "askForSavedWallpaper", objc_selector = "askForSavedWallpaper:")
Target_askForSavedWallpaper :: proc "c" (self: ^Target, sender: NS.id) {
	context = state.odin_context
	ask_for_saved_wallpaper()
}

@(objc_type = Target, objc_implement, objc_name = "windowShouldClose", objc_selector = "windowShouldClose:")
Target_windowShouldClose :: proc "c" (self: ^Target, sender: NS.id) -> NS.BOOL {
	state.is_closed = true

	return true
}

foreign import objc_runtime "system:Foundation.framework"

@(default_calling_convention = "c", private)
foreign objc_runtime {
	objc_msgSendSuper :: proc(super: ^Objc_Super, selector: NS.SEL) ---
	sel_getName :: proc(selector: NS.SEL) -> cstring ---
	objc_getProtocol :: proc(name: cstring) -> rawptr ---
	class_addProtocol :: proc(class: rawptr, protocol: rawptr) -> NS.BOOL ---
}

request_frame :: proc "contextless" () {
	state.is_frame_requested = true
	if state.is_link_running do return

	state.is_link_running = true

	if !state.is_background {
		objc_send(nil, state.display_link, "setPaused:", NS.BOOL(false))
		return
	}

	FRAME_SECONDS :: 1.0 / 60

	state.frame_timer = start_timer(
		FRAME_SECONDS,
		intrinsics.objc_find_selector("frameTimerFired:"),
		true,
	)
}

@(private)
start_timer :: proc "contextless" (
	seconds: f64,
	selector: NS.SEL,
	is_repeating: bool,
) -> ^NS.Timer {
	timer := objc_send(
		^NS.Timer,
		NS.Timer,
		"timerWithTimeInterval:target:selector:userInfo:repeats:",
		NS.TimeInterval(seconds),
		state.target,
		selector,
		rawptr(nil),
		NS.BOOL(is_repeating),
	)

	main_run_loop := objc_send(^NS.RunLoop, NS.RunLoop, "mainRunLoop")
	objc_send(nil, main_run_loop, "addTimer:forMode:", timer, NS.RunLoopCommonModes)

	return timer
}

@(private)
run_frame :: proc() {
	pool := NS.AutoreleasePool.alloc()->init()
	defer pool->drain()

	is_resized := apply_window_size()

	state.is_frame_requested = false
	is_frame_wanted := state.on_frame() || state.is_frame_requested || is_resized

	clear(&state.events)
	state.event_arena_index = 1 - state.event_arena_index
	runtime.arena_free_all(&state.event_arena[state.event_arena_index])

	if is_frame_wanted || !state.is_link_running do return

	state.is_link_running = false

	if state.is_background {
		objc_send(nil, state.frame_timer, "invalidate")
		state.frame_timer = nil
	} else {
		objc_send(nil, state.display_link, "setPaused:", NS.BOOL(true))
	}
}

run :: proc() {
	for !state.is_closed {
		pool := NS.AutoreleasePool.alloc()->init()
		event := state.app->nextEventMatchingMask(
			NS.EventMaskAny,
			NS.Date.distantFuture(),
			NS.DefaultRunLoopMode,
			true,
		)

		if event != nil && !apply_event(event) do state.app->sendEvent(event)

		pool->drain()
	}
}

request_frame_after :: proc(seconds: f64) {
	delay_seconds := max(0, seconds)
	fire_date := objc_send(
		^NS.Date,
		NS.Date,
		"dateWithTimeIntervalSinceNow:",
		NS.TimeInterval(delay_seconds),
	)

	if state.timer != nil {
		pending := objc_send(^NS.Date, state.timer, "fireDate")

		if objc_send(NS.TimeInterval, pending, "timeIntervalSinceDate:", fire_date) <= 0 do return

		objc_send(nil, state.timer, "invalidate")
	}

	state.timer = start_timer(delay_seconds, intrinsics.objc_find_selector("timerFired:"), false)
}

wake :: proc "contextless" () {
	// Worker threads call this. They have no autorelease pool for the event.
	pool := NS.AutoreleasePool.alloc()->init()
	defer pool->drain()

	event := NS.Event.otherEventWithType(.ApplicationDefined, {0, 0}, {}, 0, 0, nil, 0, 0, 0)
	state.app->postEvent(event, true)
}

read_screen_size_points :: proc() -> [2]f32 {
	visible := read_visible_frame()

	return {f32(visible.size.width), f32(visible.size.height)}
}

set_min_size :: proc(min_size_points: [2]f32) {
	min_size := NS.Size{NS.Float(min_size_points.x), NS.Float(min_size_points.y)}

	objc_send(nil, state.ns_window, "setContentMinSize:", min_size)

	frame := state.ns_window->frame()
	is_large_enough := frame.size.width >= min_size.width && frame.size.height >= min_size.height

	if is_large_enough do return

	visible := read_visible_frame()
	size := NS.Size{max(frame.size.width, min_size.width), max(frame.size.height, min_size.height)}
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
read_visible_frame :: proc() -> NS.Rect {
	screen := objc_send(^NS.Screen, state.ns_window, "screen")
	if screen == nil do screen = NS.Screen.mainScreen()

	return screen->visibleFrame()
}

quit :: proc() {
	state.is_closed = true
	wake()
}
