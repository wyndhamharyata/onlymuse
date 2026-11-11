package macos

import "base:intrinsics"
import "base:runtime"
import NS "core:sys/darwin/Foundation"
import "thor:platform"

objc_send :: intrinsics.objc_send

QUESTION_DELAY_SECONDS :: 0.5

@(private)
state: struct {
	window:           ^platform.Native_Window,
	target:           ^Macos_Target,
	backdrop:         ^platform.Layer,
	backdrop_view:    ^NS.View,
	drag_timer:       ^NS.Timer,
	fade_steps:       int,
	player_menu:      Player_Menu,
	player_menu_item: ^NS.MenuItem,
	odin_context:     runtime.Context,
}

@(objc_class = "OMTarget", objc_superclass = NS.Object, objc_implement)
Macos_Target :: struct {
	using _: NS.Object,
}

@(objc_type = Macos_Target, objc_implement, objc_name = "windowDidResize", objc_selector = "windowDidResize:")
Macos_Target_windowDidResize :: proc "c" (self: ^Macos_Target, notification: NS.id) {
	context = state.odin_context
	set_backdrop_part()
}

@(objc_type = Macos_Target, objc_implement, objc_name = "windowDidMove", objc_selector = "windowDidMove:")
Macos_Target_windowDidMove :: proc "c" (self: ^Macos_Target, notification: NS.id) {
	context = state.odin_context
	set_backdrop_part()
}

@(objc_type = Macos_Target, objc_implement, objc_name = "windowWillMove", objc_selector = "windowWillMove:")
Macos_Target_windowWillMove :: proc "c" (self: ^Macos_Target, notification: NS.id) {
	context = state.odin_context
	start_window_drag()
}

@(objc_type = Macos_Target, objc_implement, objc_name = "dragTimerFired", objc_selector = "dragTimerFired:")
Macos_Target_dragTimerFired :: proc "c" (self: ^Macos_Target, timer: NS.id) {
	context = state.odin_context
	step_window_drag()
}

@(objc_type = Macos_Target, objc_implement, objc_name = "windowDidChangeScreen", objc_selector = "windowDidChangeScreen:")
Macos_Target_windowDidChangeScreen :: proc "c" (self: ^Macos_Target, notification: NS.id) {
	context = state.odin_context
	apply_screen_change()
}

@(objc_type = Macos_Target, objc_implement, objc_name = "windowDidBecomeKey", objc_selector = "windowDidBecomeKey:")
Macos_Target_windowDidBecomeKey :: proc "c" (self: ^Macos_Target, notification: NS.id) {
	context = state.odin_context
	apply_screen_change()
}

@(objc_type = Macos_Target, objc_implement, objc_name = "togglePlayerMode", objc_selector = "togglePlayerMode:")
Macos_Target_togglePlayerMode :: proc "c" (self: ^Macos_Target, item: NS.id) {
	context = state.odin_context
	state.player_menu.toggle()
}

// The app menu asks for the state of its checkmark each time it opens.
@(objc_type = Macos_Target, objc_implement, objc_name = "validateMenuItem", objc_selector = "validateMenuItem:")
Macos_Target_validateMenuItem :: proc "c" (self: ^Macos_Target, item: ^NS.MenuItem) -> NS.BOOL {
	context = state.odin_context

	if item == state.player_menu_item {
		objc_send(nil, item, "setState:", NS.Integer(1 if state.player_menu.is_driving() else 0))
	}

	return true
}

@(objc_type = Macos_Target, objc_implement, objc_name = "askForSavedWallpaper", objc_selector = "askForSavedWallpaper:")
Macos_Target_askForSavedWallpaper :: proc "c" (self: ^Macos_Target, sender: NS.id) {
	context = state.odin_context
	ask_for_saved_wallpaper()
}

start :: proc(window: ^platform.Native_Window, is_background: bool) {
	state.window = window
	state.odin_context = context
	state.target = objc_send(
		^Macos_Target,
		objc_send(^Macos_Target, Macos_Target, "alloc"),
		"init",
	)

	add_backdrop()

	// thor's window is the delegate, so these come as notifications.
	center := NS.NotificationCenter.defaultCenter()
	observe(
		center,
		intrinsics.objc_find_selector("windowDidResize:"),
		NS.AT("NSWindowDidResizeNotification"),
	)
	observe(
		center,
		intrinsics.objc_find_selector("windowDidMove:"),
		NS.AT("NSWindowDidMoveNotification"),
	)
	observe(
		center,
		intrinsics.objc_find_selector("windowWillMove:"),
		NS.AT("NSWindowWillMoveNotification"),
	)
	observe(
		center,
		intrinsics.objc_find_selector("windowDidChangeScreen:"),
		NS.AT("NSWindowDidChangeScreenNotification"),
	)
	observe(
		center,
		intrinsics.objc_find_selector("windowDidBecomeKey:"),
		NS.AT("NSWindowDidBecomeKeyNotification"),
	)

	if is_background do return

	objc_send(
		nil,
		state.target,
		"performSelector:withObject:afterDelay:",
		intrinsics.objc_find_selector("askForSavedWallpaper:"),
		rawptr(nil),
		NS.TimeInterval(QUESTION_DELAY_SECONDS),
	)
}

@(private = "file")
observe :: proc(center: ^NS.NotificationCenter, selector: NS.SEL, name: ^NS.String) {
	objc_send(
		nil,
		center,
		"addObserver:selector:name:object:",
		state.target,
		selector,
		name,
		state.window.ns_window,
	)
}

@(private)
start_timer :: proc(seconds: f64, selector: NS.SEL, is_repeating: bool) -> ^NS.Timer {
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
