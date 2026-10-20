package platform

import "base:intrinsics"
import "base:runtime"
import "core:strings"
import "core:unicode/utf8"
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
	modifiers:   Modifiers,
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
	// A finger touched the trackpad, starting a new swipe.
	is_start:    bool,
}
Key_Press :: struct {
	key_code:   u16,
	// Lives until the next frame.
	characters: string,
	modifiers:  Modifiers,
	is_repeat:  bool,
}
// Finished text from the keyboard or an input method.
Text_Insert :: struct {
	// Lives until the next frame.
	text: string,
}
// An input method's unfinished text, such as kana before it becomes kanji. Empty when it ends.
Text_Marked :: struct {
	text: string,
}
// An editing key, by AppKit's selector, such as "deleteBackward:", "insertNewline:" or "moveLeft:".
Text_Command :: struct {
	name: string,
}
Event :: union {
	Text_Insert,
	Text_Marked,
	Text_Command,
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
	// A background window is covered, and macOS stops its display link, so a timer runs its frames.
	is_background:   bool,
	frame_timer:     ^NS.Timer,
	is_link_running: bool,
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

@(objc_class = "NSVisualEffectView")
Visual_Effect_View :: struct {
	using _: NS.View,
}

@(objc_class = "CAMetalDisplayLink")
Display_Link :: struct {
	using _: NS.Object,
}

@(objc_class = "NSDateFormatter")
Date_Formatter :: struct {
	using _: NS.Object,
}

@(objc_class = "NSTimeZone")
Time_Zone :: struct {
	using _: NS.Object,
}

@(objc_class = "NSPasteboard")
Pasteboard :: struct {
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

// The view that draws the app. It takes the keyboard while a text field is focused, so an input method
// such as Japanese can compose text in it (NSTextInputClient).
@(objc_class = "OMView", objc_superclass = NS.View, objc_implement)
Text_View :: struct {
	using _: NS.View,
}

@(objc_type = Text_View, objc_implement, objc_name = "acceptsFirstResponder")
Text_View_acceptsFirstResponder :: proc "c" (self: ^Text_View) -> NS.BOOL {
	return true
}

@(objc_type = Text_View, objc_implement, objc_name = "keyDown", objc_selector = "keyDown:")
Text_View_keyDown :: proc "c" (self: ^Text_View, event: ^NS.Event) {
	object := cast(^NS.Object)event
	events := NS.Array.alloc()->initWithObjects(&object, 1)
	msg_send(nil, self, "interpretKeyEvents:", events)
	events->release()
}

@(private)
to_odin_text :: proc "c" (text: ^NS.Object) -> string {
	context = state.odin_context
	plain := text
	// An input method may send an NSAttributedString.
	if msg_send(NS.BOOL, text, "respondsToSelector:", intrinsics.objc_find_selector("string")) do plain = msg_send(^NS.Object, text, "string")

	return strings.clone((cast(^NS.String)plain)->odinString(), runtime.arena_allocator(&state.event_arena[state.event_arena_index]))
}

// NSResponder's form, which AppKit uses when it finds no input context.
@(objc_type = Text_View, objc_implement, objc_name = "insertTextPlain", objc_selector = "insertText:")
Text_View_insertTextPlain :: proc "c" (self: ^Text_View, text: ^NS.Object) {
	context = state.odin_context
	state.marked_length = 0
	append(&state.events, Text_Insert{to_odin_text(text)})
	request_frame()
}

@(objc_type = Text_View, objc_implement, objc_name = "insertText", objc_selector = "insertText:replacementRange:")
Text_View_insertText :: proc "c" (self: ^Text_View, text: ^NS.Object, replacement: NS.Range) {
	context = state.odin_context
	state.marked_length = 0
	append(&state.events, Text_Insert{to_odin_text(text)})
	request_frame()
}

@(objc_type = Text_View, objc_implement, objc_name = "setMarkedText", objc_selector = "setMarkedText:selectedRange:replacementRange:")
Text_View_setMarkedText :: proc "c" (self: ^Text_View, text: ^NS.Object, selected, replacement: NS.Range) {
	context = state.odin_context
	marked := to_odin_text(text)
	state.marked_length = len(marked)
	append(&state.events, Text_Marked{marked})
	request_frame()
}

@(objc_type = Text_View, objc_implement, objc_name = "unmarkText")
Text_View_unmarkText :: proc "c" (self: ^Text_View) {
	context = state.odin_context
	state.marked_length = 0
	append(&state.events, Text_Marked{})
	request_frame()
}

@(objc_type = Text_View, objc_implement, objc_name = "hasMarkedText")
Text_View_hasMarkedText :: proc "c" (self: ^Text_View) -> NS.BOOL {
	return state.marked_length > 0
}

// NSNotFound marks no range.
@(private)
NOT_FOUND :: NS.UInteger(max(int))

@(objc_type = Text_View, objc_implement, objc_name = "markedRange")
Text_View_markedRange :: proc "c" (self: ^Text_View) -> NS.Range {
	if state.marked_length == 0 do return {NOT_FOUND, 0}

	return {0, NS.UInteger(state.marked_length)}
}

@(objc_type = Text_View, objc_implement, objc_name = "selectedRange")
Text_View_selectedRange :: proc "c" (self: ^Text_View) -> NS.Range {
	return {NOT_FOUND, 0}
}

@(objc_type = Text_View, objc_implement, objc_name = "validAttributesForMarkedText")
Text_View_validAttributesForMarkedText :: proc "c" (self: ^Text_View) -> ^NS.Array {
	return msg_send(^NS.Array, NS.Array, "array")
}

@(objc_type = Text_View, objc_implement, objc_name = "attributedSubstringForProposedRange", objc_selector = "attributedSubstringForProposedRange:actualRange:")
Text_View_attributedSubstringForProposedRange :: proc "c" (self: ^Text_View, range: NS.Range, actual: ^NS.Range) -> ^NS.Object {
	return nil
}

@(objc_type = Text_View, objc_implement, objc_name = "characterIndexForPoint", objc_selector = "characterIndexForPoint:")
Text_View_characterIndexForPoint :: proc "c" (self: ^Text_View, point: NS.Point) -> NS.UInteger {
	return NOT_FOUND
}

// Where the input method opens its list of candidates: under the caret, on the screen.
@(objc_type = Text_View, objc_implement, objc_name = "firstRectForCharacterRange", objc_selector = "firstRectForCharacterRange:actualRange:")
Text_View_firstRectForCharacterRange :: proc "c" (self: ^Text_View, range: NS.Range, actual: ^NS.Range) -> NS.Rect {
	caret := state.caret_rect
	height := f64(state.window.size_points.y)
	in_window := NS.Rect{{NS.Float(caret.x), NS.Float(height - f64(caret.w))}, {NS.Float(caret.z - caret.x), NS.Float(caret.w - caret.y)}}

	return msg_send(NS.Rect, state.ns_window, "convertRectToScreen:", in_window)
}

@(objc_type = Text_View, objc_implement, objc_name = "doCommandBySelector", objc_selector = "doCommandBySelector:")
Text_View_doCommandBySelector :: proc "c" (self: ^Text_View, selector: NS.SEL) {
	context = state.odin_context
	name := string(sel_getName(selector))
	append(&state.events, Text_Command{strings.clone(name, runtime.arena_allocator(&state.event_arena[state.event_arena_index]))})
	request_frame()
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

	// AppKit gives a view an input context only when its class says it is an NSTextInputClient. Without
	// one, keys go to NSResponder's insertText: and an input method never starts.
	class_addProtocol(rawptr(intrinsics.objc_find_class("OMView")), objc_getProtocol("NSTextInputClient"))
	view := msg_send(^NS.View, msg_send(^Text_View, Text_View, "alloc"), "initWithFrame:", content_rect)
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

	wants_more := state.on_frame()

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
		append(&state.events, Mouse_Press{to_position(event), button, int(event->clickCount()), to_modifiers(event)})
	case .LeftMouseUp, .RightMouseUp, .OtherMouseUp:
		append(&state.events, Mouse_Release{to_position(event), to_button(event)})
	case .ApplicationDefined:
		request_frame()
		return true
	case .MouseExited:
		append(&state.events, Mouse_Exit{})
	case .ScrollWheel:
		momentum_phase := msg_send(NS.UInteger, event, "momentumPhase")
		// NSEventPhaseBegan and NSEventPhaseMayBegin.
		phase := msg_send(NS.UInteger, event, "phase")
		append(&state.events, Scroll {
			is_start    = phase == 1 || phase == 32,
			position    = to_position(event),
			delta       = {f32(event->scrollingDeltaX()), f32(event->scrollingDeltaY())},
			is_precise  = bool(event->hasPreciseScrollingDeltas()),
			is_momentum = momentum_phase != 0,
		})
	case .KeyDown:
		modifiers := to_modifiers(event)

		// A text field takes the key through the view's input method, except a shortcut.
		if state.is_text_input && .Command not_in modifiers && .Control not_in modifiers {
			request_frame()
			return false
		}

		characters := event->charactersIgnoringModifiers()->odinString()
		append(&state.events, Key_Press {
			key_code   = u16(event->keyCode()),
			characters = strings.clone(characters, arena_allocator),
			modifiers  = modifiers,
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

// Turns the keyboard over to a text field, or back to the app's shortcuts.
set_text_input :: proc(is_on: bool, caret_rect: [4]f32 = {}) {
	state.caret_rect = caret_rect
	if is_on == state.is_text_input do return

	state.is_text_input = is_on
	if is_on {
		msg_send(NS.BOOL, state.ns_window, "makeFirstResponder:", state.view)
	} else {
		state.marked_length = 0
		msg_send(nil, msg_send(^NS.Object, state.view, "inputContext"), "discardMarkedText")
	}
}

// For the tests, which cannot type into a window behind the others: sends each character to the view as
// a key press, as the keyboard would, through its input context. Reports whether it has one.
type_for_test :: proc(text: string) -> bool {
	input_context := msg_send(^NS.Object, state.view, "inputContext")
	has_context := input_context != nil
	// AppKit activates the context of the key window's first responder. A test window is never key.
	if has_context do msg_send(nil, input_context, "activate")
	window_number := msg_send(NS.Integer, state.ns_window, "windowNumber")

	for character in text {
		buffer, size := utf8.encode_rune(character)
		ns_character := NS.String.alloc()->initWithOdinString(string(buffer[:size]))
		defer ns_character->release()

		// NSEventTypeKeyDown is 10.
		event := msg_send(^NS.Event, NS.Event, "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", NS.UInteger(10), NS.Point{}, NS.UInteger(0), NS.TimeInterval(0), window_number, rawptr(nil), ns_character, ns_character, NS.BOOL(false), u16(0))
		msg_send(nil, state.view, "keyDown:", event)
	}

	return has_context
}

// The text on the clipboard, for Cmd V. It lives until the next frame.
read_clipboard :: proc() -> string {
	board := msg_send(^Pasteboard, Pasteboard, "generalPasteboard")
	text := msg_send(^NS.String, board, "stringForType:", NS.AT("public.utf8-plain-text"))
	if text == nil do return ""

	return strings.clone(text->odinString(), context.temp_allocator)
}

// A Unix time in ms as local text, by a template such as "d MMM" or "HH:mm", in the order the
// person's locale writes it. It lives until the next frame.
format_date :: proc(unix_ms: f64, template: string) -> string {
	formatter := msg_send(^Date_Formatter, msg_send(^Date_Formatter, Date_Formatter, "alloc"), "init")
	defer msg_send(nil, formatter, "release")

	ns_template := NS.String.alloc()->initWithOdinString(template)
	defer ns_template->release()
	msg_send(nil, formatter, "setLocalizedDateFormatFromTemplate:", ns_template)

	date := msg_send(^NS.Object, NS.Date, "dateWithTimeIntervalSince1970:", NS.TimeInterval(unix_ms / 1000))
	text := msg_send(^NS.String, formatter, "stringFromDate:", date)

	return strings.clone(text->odinString(), context.temp_allocator)
}

// How far local time is ahead of UTC, so a date can be compared by local day.
local_offset_seconds :: proc() -> int {
	zone := msg_send(^Time_Zone, Time_Zone, "localTimeZone")

	return int(msg_send(NS.Integer, zone, "secondsFromGMT"))
}

write_clipboard :: proc(text: string) {
	board := msg_send(^Pasteboard, Pasteboard, "generalPasteboard")
	msg_send(NS.Integer, board, "clearContents")

	ns_text := NS.String.alloc()->initWithOdinString(text)
	defer ns_text->release()
	msg_send(NS.BOOL, board, "setString:forType:", ns_text, NS.AT("public.utf8-plain-text"))
}

quit :: proc() {
	state.is_closed = true
	wake()
}
