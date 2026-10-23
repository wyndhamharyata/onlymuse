package platform

import "base:intrinsics"
import NS "core:sys/darwin/Foundation"
import "om:mac"
import MTL "vendor:darwin/Metal"
import CA "vendor:darwin/QuartzCore"

TITLE_HIDDEN :: 1
MATERIAL_SELECTION :: 4
// NSVisualEffectStateActive, which keeps the blur when the window is not key.
BLUR_ALWAYS_ACTIVE :: 1
SIZE_WITH_SUPERVIEW :: 2 | 16
// NSWindowCollectionBehaviorTransient | IgnoresCycle. Spaces, Mission Control and Cmd ` skip it.
TRANSIENT_WINDOW :: (1 << 3) | (1 << 6)
QUESTION_DELAY_SECONDS :: 0.5

// An accessory app, so a tiling window manager such as AeroSpace ignores it.
open_window :: proc(
	title: string,
	size_points, min_size_points: [2]f32,
	on_frame: Frame_Proc,
	is_background := false,
) -> ^Window {
	state.odin_context = context
	state.on_frame = on_frame
	state.is_background = is_background

	state.app = NS.Application.sharedApplication()
	state.app->setActivationPolicy(.Accessory if is_background else .Regular)
	// run reads events in place of NSApplication's run, so this sends finishLaunching itself.
	objc_send(nil, state.app, "finishLaunching")

	content_rect := NS.Rect{{0, 0}, {NS.Float(size_points.x), NS.Float(size_points.y)}}
	state.ns_window = make_ns_window(title, content_rect, min_size_points)
	content := objc_send(
		^NS.View,
		objc_send(^NS.View, NS.View, "alloc"),
		"initWithFrame:",
		content_rect,
	)
	state.ns_window->setContentView(content)
	state.blur_view = make_blur_view(content_rect)
	content->addSubview(state.blur_view)

	add_backdrop()

	device := MTL.CreateSystemDefaultDevice()
	layer := make_metal_layer(device)
	state.view = make_metal_view(layer, content_rect)
	content->addSubview(state.view)

	state.input_view = make_input_view()
	content->addSubview(state.input_view)

	state.target = objc_send(^Target, objc_send(^Target, Target, "alloc"), "init")
	state.ns_window->setDelegate(cast(^NS.WindowDelegate)state.target)
	state.display_link = make_display_link(layer, state.target)

	state.window = Window {
		device = device,
		layer  = layer,
	}

	apply_window_size()
	show_window(is_background)

	return &state.window
}

@(private = "file")
make_ns_window :: proc(
	title: string,
	content_rect: NS.Rect,
	min_size_points: [2]f32,
) -> ^NS.Window {
	style := NS.WindowStyleMask {
		.Titled,
		.Closable,
		.Miniaturizable,
		.Resizable,
		.FullSizeContentView,
	}
	ns_window := NS.Window.alloc()->initWithContentRect(content_rect, style, .Buffered, false)

	ns_title := NS.String.alloc()->initWithOdinString(title)
	defer ns_title->release()
	ns_window->setTitle(ns_title)
	ns_window->setTitlebarAppearsTransparent(true)
	objc_send(nil, ns_window, "setTitleVisibility:", NS.Integer(TITLE_HIDDEN))

	objc_send(nil, ns_window, "setReleasedWhenClosed:", NS.BOOL(false))
	objc_send(nil, ns_window, "setAcceptsMouseMovedEvents:", NS.BOOL(true))
	objc_send(
		nil,
		ns_window,
		"setContentMinSize:",
		NS.Size{NS.Float(min_size_points.x), NS.Float(min_size_points.y)},
	)

	ns_window->setOpaque(false)
	ns_window->setBackgroundColor(objc_send(^NS.Color, NS.Color, "clearColor"))

	return ns_window
}

@(private = "file")
make_blur_view :: proc(content_rect: NS.Rect) -> ^Blur_View {
	blur := objc_send(
		^Blur_View,
		objc_send(^Blur_View, Blur_View, "alloc"),
		"initWithFrame:",
		content_rect,
	)

	objc_send(nil, blur, "setMaterial:", NS.Integer(MATERIAL_SELECTION))
	objc_send(nil, blur, "setState:", NS.Integer(BLUR_ALWAYS_ACTIVE))
	objc_send(nil, blur, "setAutoresizingMask:", NS.UInteger(SIZE_WITH_SUPERVIEW))

	return blur
}

@(private = "file")
make_metal_layer :: proc(device: ^MTL.Device) -> ^CA.MetalLayer {
	layer := CA.MetalLayer.layer()
	layer->setDevice(device)
	layer->setPixelFormat(.BGRA8Unorm)
	layer->setOpaque(false)
	layer->setFramebufferOnly(true)

	srgb := mac.CGColorSpaceCreateWithName(mac.kCGColorSpaceSRGB)
	defer mac.CGColorSpaceRelease(srgb)
	objc_send(nil, layer, "setColorspace:", rawptr(srgb))

	return layer
}

@(private = "file")
make_metal_view :: proc(layer: ^CA.MetalLayer, content_rect: NS.Rect) -> ^NS.View {
	view := objc_send(
		^NS.View,
		objc_send(^NS.View, NS.View, "alloc"),
		"initWithFrame:",
		content_rect,
	)

	view->setLayer(layer)
	view->setWantsLayer(true)
	objc_send(nil, view, "setAutoresizingMask:", NS.UInteger(SIZE_WITH_SUPERVIEW))

	return view
}

// AppKit gives a view an input method only when its class declares NSTextInputClient.
@(private = "file")
make_input_view :: proc() -> ^NS.View {
	input_class := intrinsics.objc_find_class("OMInputView")
	class_addProtocol(rawptr(input_class), objc_getProtocol("NSTextInputClient"))

	return objc_send(
		^NS.View,
		objc_send(^Input_View, Input_View, "alloc"),
		"initWithFrame:",
		NS.Rect{{0, 0}, {1, 1}},
	)
}

@(private = "file")
make_display_link :: proc(layer: ^CA.MetalLayer, target: ^Target) -> ^Display_Link {
	link := objc_send(
		^Display_Link,
		objc_send(^Display_Link, Display_Link, "alloc"),
		"initWithMetalLayer:",
		layer,
	)

	objc_send(nil, link, "setDelegate:", target)
	objc_send(nil, link, "setPreferredFrameLatency:", f32(1))
	objc_send(nil, link, "addToRunLoop:forMode:", NS.RunLoop.mainRunLoop(), NS.RunLoopCommonModes)
	objc_send(nil, link, "setPaused:", NS.BOOL(true))

	return link
}

@(private = "file")
show_window :: proc(is_background: bool) {
	state.ns_window->center()

	if is_background {
		objc_send(nil, state.ns_window, "setCollectionBehavior:", NS.UInteger(TRANSIENT_WINDOW))
		objc_send(nil, state.ns_window, "orderBack:", rawptr(nil))
	} else {
		state.ns_window->makeKeyAndOrderFront(nil)
		state.app->activate()
		objc_send(
			nil,
			state.target,
			"performSelector:withObject:afterDelay:",
			intrinsics.objc_find_selector("askForSavedWallpaper:"),
			rawptr(nil),
			NS.TimeInterval(QUESTION_DELAY_SECONDS),
		)
	}

	request_frame()
}

@(private)
apply_window_size :: proc() -> bool {
	bounds := state.view->bounds()
	pixels_per_point := f32(state.ns_window->backingScaleFactor())
	window := &state.window

	window.size_points = {f32(bounds.size.width), f32(bounds.size.height)}
	window.pixels_per_point = pixels_per_point
	size_pixels := NS.Size {
		bounds.size.width * NS.Float(pixels_per_point),
		bounds.size.height * NS.Float(pixels_per_point),
	}
	is_resized := window.layer->drawableSize() != size_pixels

	window.layer->setDrawableSize(size_pixels)
	objc_send(nil, window.layer, "setContentsScale:", NS.Float(pixels_per_point))

	return is_resized
}
