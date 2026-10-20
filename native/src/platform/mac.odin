package platform

import "base:intrinsics"
import "base:runtime"
import "core:strings"
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

Modifier :: enum {
	Shift,
	Control,
	Option,
	Command,
}
Modifiers :: bit_set[Modifier]

Mouse_Button :: enum {
	Left,
	Right,
	Middle,
}

// Positions are in points from the top left of the window.
Mouse_Move :: struct {
	position: [2]f32,
}
Mouse_Press :: struct {
	position:    [2]f32,
	button:      Mouse_Button,
	click_count: int,
}
Mouse_Release :: struct {
	position: [2]f32,
	button:   Mouse_Button,
}
Mouse_Exit :: struct {}
Scroll :: struct {
	position:    [2]f32,
	// Points for a trackpad, lines for a mouse wheel.
	delta:       [2]f32,
	is_precise:  bool,
	is_momentum: bool,
}
Key_Press :: struct {
	key_code:   u16,
	// Lives until the next frame.
	characters: string,
	modifiers:  Modifiers,
	is_repeat:  bool,
}
Event :: union {
	Mouse_Move,
	Mouse_Press,
	Mouse_Release,
	Mouse_Exit,
	Scroll,
	Key_Press,
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
	display_link:    ^Display_Link,
	target:          ^Target,
	timer:           ^NS.Timer,
	is_link_running: bool,
	is_closed:       bool,
	on_frame:        Frame_Proc,
	window:          Window,
	events:          [dynamic]Event,
	event_arena:     [2]runtime.Arena,
	event_arena_index: int,
	odin_context:    runtime.Context,
}

@(objc_class = "NSVisualEffectView")
Visual_Effect_View :: struct {
	using _: NS.View,
}

@(objc_class = "CAMetalDisplayLink")
Display_Link :: struct {
	using _: NS.Object,
}

@(objc_class = "CALayer")
Layer :: struct {
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

@(objc_class = "OMBlurView", objc_superclass = Visual_Effect_View, objc_implement)
Blur_View :: struct {
	using _: Visual_Effect_View,
}

// AppKit puts back its tint and saturation layers each time it updates the blur.
@(objc_type = Blur_View, objc_implement, objc_name = "updateLayer")
Blur_View_updateLayer :: proc "c" (self: ^Blur_View) {
	super := Objc_Super{self, NS.Class(intrinsics.objc_find_class("NSVisualEffectView"))}
	objc_msgSendSuper(&super, NS.SEL(intrinsics.objc_find_selector("updateLayer")))
	remove_layer_background(msg_send(^Layer, self, "layer"))
}

@(private)
remove_layer_background :: proc "c" (layer: ^Layer) {
	if layer == nil do return

	msg_send(nil, layer, "setBackgroundColor:", rawptr(nil))

	class_name := msg_send(^NS.String, layer, "className")

	// CAChameleonLayer tints the blur with the desktop colour.
	if msg_send(NS.BOOL, class_name, "isEqualToString:", NS.AT("CAChameleonLayer")) {
		msg_send(nil, layer, "setHidden:", NS.BOOL(true))
		return
	}

	filters := msg_send(^NS.Array, layer, "filters")

	if filters != nil {
		kept := NS.MutableArray.alloc()->init()

		for index in 0 ..< filters->count() {
			filter := filters->object(index)
			description := msg_send(^NS.String, filter, "description")

			// The blur raises saturation with a filter named "colorSaturate".
			if msg_send(NS.BOOL, description, "containsString:", NS.AT("Saturat")) do continue

			msg_send(nil, kept, "addObject:", filter)
		}
		msg_send(nil, layer, "setFilters:", kept)
	}

	sublayers := msg_send(^NS.Array, layer, "sublayers")

	if sublayers == nil do return

	for index in 0 ..< sublayers->count() {
		remove_layer_background(cast(^Layer)sublayers->object(index))
	}
}

open_window :: proc(title: string, size_points: [2]f32, on_frame: Frame_Proc) -> ^Window {
	state.odin_context = context
	state.on_frame = on_frame

	app := NS.Application.sharedApplication()
	app->setActivationPolicy(.Regular)
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
	ns_window->makeKeyAndOrderFront(nil)
	app->activate()
	request_frame()

	return &state.window
}

foreign import objc_runtime "system:objc"

@(private)
Objc_Super :: struct {
	receiver:    ^Blur_View,
	super_class: NS.Class,
}

@(default_calling_convention = "c", private)
foreign objc_runtime {
	objc_msgSendSuper :: proc(super: ^Objc_Super, selector: NS.SEL) ---
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
	if state.is_link_running do return

	state.is_link_running = true
	msg_send(nil, state.display_link, "setPaused:", NS.BOOL(false))
}

@(private)
draw_frame :: proc() {
	pool := NS.AutoreleasePool.alloc()->init()
	defer pool->drain()

	update_window_size()

	wants_more := state.on_frame()

	clear(&state.events)
	state.event_arena_index = 1 - state.event_arena_index
	runtime.arena_free_all(&state.event_arena[state.event_arena_index])

	if !wants_more && state.is_link_running {
		state.is_link_running = false
		msg_send(nil, state.display_link, "setPaused:", NS.BOOL(true))
	}
}

// The events since the last frame.
list_events :: proc() -> []Event {
	return state.events[:]
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

@(private)
to_modifiers :: proc(event: ^NS.Event) -> Modifiers {
	flags := transmute(NS.UInteger)event->modifierFlags()
	modifiers: Modifiers

	if flags & (1 << 17) != 0 do modifiers += {.Shift}
	if flags & (1 << 18) != 0 do modifiers += {.Control}
	if flags & (1 << 19) != 0 do modifiers += {.Option}
	if flags & (1 << 20) != 0 do modifiers += {.Command}

	return modifiers
}

@(private)
to_position :: proc(event: ^NS.Event) -> [2]f32 {
	location := event->locationInWindow()

	// An event with no window, such as one sent to the process, gives its place on the screen.
	if event->window() == nil do location = msg_send(NS.Point, state.ns_window, "convertPointFromScreen:", location)

	return {f32(location.x), state.window.size_points.y - f32(location.y)}
}

// Returns true when the event is ours alone, so AppKit never sees it.
@(private)
take_event :: proc(event: ^NS.Event) -> bool {
	event_window := event->window()
	if event_window != nil && event_window != state.ns_window do return false

	arena_allocator := runtime.arena_allocator(&state.event_arena[state.event_arena_index])
	is_taken := false

	#partial switch event->type() {
	case .MouseMoved, .LeftMouseDragged, .RightMouseDragged, .OtherMouseDragged:
		append(&state.events, Mouse_Move{to_position(event)})
	case .LeftMouseDown, .RightMouseDown, .OtherMouseDown:
		button := to_button(event)
		append(&state.events, Mouse_Press{to_position(event), button, int(event->clickCount())})
	case .LeftMouseUp, .RightMouseUp, .OtherMouseUp:
		append(&state.events, Mouse_Release{to_position(event), to_button(event)})
	case .ApplicationDefined:
		request_frame()
		return true
	case .MouseExited:
		append(&state.events, Mouse_Exit{})
	case .ScrollWheel:
		momentum_phase := msg_send(NS.UInteger, event, "momentumPhase")
		append(&state.events, Scroll {
			position    = to_position(event),
			delta       = {f32(event->scrollingDeltaX()), f32(event->scrollingDeltaY())},
			is_precise  = bool(event->hasPreciseScrollingDeltas()),
			is_momentum = momentum_phase != 0,
		})
	case .KeyDown:
		characters := event->charactersIgnoringModifiers()->odinString()
		append(&state.events, Key_Press {
			key_code   = u16(event->keyCode()),
			characters = strings.clone(characters, arena_allocator),
			modifiers  = to_modifiers(event),
			is_repeat  = bool(event->isARepeat()),
		})
		is_taken = true
	case:
		return false
	}

	request_frame()

	return is_taken
}

@(private)
to_button :: proc(event: ^NS.Event) -> Mouse_Button {
	switch event->buttonNumber() {
	case 0:
		return .Left
	case 1:
		return .Right
	}

	return .Middle
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
	event := NS.Event.otherEventWithType(.ApplicationDefined, {0, 0}, {}, 0, 0, nil, 0, 0, 0)
	state.app->postEvent(event, true)
}

quit :: proc() {
	state.is_closed = true
	wake()
}
