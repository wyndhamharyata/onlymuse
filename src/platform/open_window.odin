package platform

import "base:intrinsics"
import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"
import "om:mac"
import CA "vendor:darwin/QuartzCore"

// NSWindowTitleHidden
TITLE_HIDDEN :: 1
// NSVisualEffectMaterialSelection, which is colourless.
MATERIAL_SELECTION :: 4
// NSVisualEffectStateActive, which keeps the blur when the window is not key.
BLUR_ALWAYS_ACTIVE :: 1
// NSViewWidthSizable | NSViewHeightSizable
SIZE_WITH_SUPERVIEW :: 2 | 16
// NSWindowCollectionBehaviorTransient | IgnoresCycle: no Spaces, Mission Control or Cmd ` for it.
TRANSIENT_WINDOW :: 1 << 3 | 1 << 6

// A background window, for the tests and the bench, opens behind the others and never takes focus.
// Its app is an accessory, so a tiling window manager such as AeroSpace leaves it alone.
open_window :: proc(title: string, size_points, min_size_points: [2]f32, on_frame: Frame_Proc, is_background := false) -> ^Window {
	state.odin_context = context
	state.on_frame = on_frame
	state.is_background = is_background

	state.app = NS.Application.sharedApplication()
	state.app->setActivationPolicy(.Accessory if is_background else .Regular)
	msg_send(nil, state.app, "finishLaunching")

	content_rect := NS.Rect{{0, 0}, {NS.Float(size_points.x), NS.Float(size_points.y)}}
	state.ns_window = make_ns_window(title, content_rect, min_size_points)
	blur := make_blur_view(content_rect)
	state.ns_window->setContentView(blur)

	device := MTL.CreateSystemDefaultDevice()
	layer := make_metal_layer(device)
	state.view = make_metal_view(layer, content_rect)
	blur->addSubview(state.view)
	state.input_view = make_input_view()
	blur->addSubview(state.input_view)

	state.target = msg_send(^Target, msg_send(^Target, Target, "alloc"), "init")
	state.ns_window->setDelegate(cast(^NS.WindowDelegate)state.target)
	state.display_link = make_display_link(layer, state.target)

	state.window = Window {
		device = device,
		layer  = layer,
	}
	update_window_size()
	show_window(is_background)

	return &state.window
}

@(private = "file")
make_ns_window :: proc(title: string, content_rect: NS.Rect, min_size_points: [2]f32) -> ^NS.Window {
	style := NS.WindowStyleMask{.Titled, .Closable, .Miniaturizable, .Resizable, .FullSizeContentView}
	ns_window := NS.Window.alloc()->initWithContentRect(content_rect, style, .Buffered, false)
	ns_title := NS.String.alloc()->initWithOdinString(title)
	defer ns_title->release()
	ns_window->setTitle(ns_title)
	ns_window->setTitlebarAppearsTransparent(true)
	msg_send(nil, ns_window, "setTitleVisibility:", NS.Integer(TITLE_HIDDEN))
	msg_send(nil, ns_window, "setReleasedWhenClosed:", NS.BOOL(false))
	msg_send(nil, ns_window, "setAcceptsMouseMovedEvents:", NS.BOOL(true))
	msg_send(nil, ns_window, "setContentMinSize:", NS.Size{NS.Float(min_size_points.x), NS.Float(min_size_points.y)})
	ns_window->setOpaque(false)
	ns_window->setBackgroundColor(msg_send(^NS.Color, NS.Color, "clearColor"))

	return ns_window
}

// What is behind the window, blurred. The Metal view and the input view sit in it.
@(private = "file")
make_blur_view :: proc(content_rect: NS.Rect) -> ^Blur_View {
	blur := msg_send(^Blur_View, msg_send(^Blur_View, Blur_View, "alloc"), "initWithFrame:", content_rect)
	msg_send(nil, blur, "setMaterial:", NS.Integer(MATERIAL_SELECTION))
	msg_send(nil, blur, "setState:", NS.Integer(BLUR_ALWAYS_ACTIVE))

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
	msg_send(nil, layer, "setColorspace:", rawptr(srgb))

	return layer
}

@(private = "file")
make_metal_view :: proc(layer: ^CA.MetalLayer, content_rect: NS.Rect) -> ^NS.View {
	view := msg_send(^NS.View, msg_send(^NS.View, NS.View, "alloc"), "initWithFrame:", content_rect)
	view->setLayer(layer)
	view->setWantsLayer(true)
	msg_send(nil, view, "setAutoresizingMask:", NS.UInteger(SIZE_WITH_SUPERVIEW))

	return view
}

// AppKit gives a view an input context only when its class says it is an NSTextInputClient. Without
// one, keys go to NSResponder's insertText: and an input method never starts.
@(private = "file")
make_input_view :: proc() -> ^NS.View {
	input_class := intrinsics.objc_find_class("OMInputView")
	class_addProtocol(rawptr(input_class), objc_getProtocol("NSTextInputClient"))

	return msg_send(^NS.View, msg_send(^Text_View, Text_View, "alloc"), "initWithFrame:", NS.Rect{{0, 0}, {1, 1}})
}

// Paused until request_frame. It calls Target_metalDisplayLink before each refresh of the screen.
@(private = "file")
make_display_link :: proc(layer: ^CA.MetalLayer, target: ^Target) -> ^Display_Link {
	link := msg_send(^Display_Link, msg_send(^Display_Link, Display_Link, "alloc"), "initWithMetalLayer:", layer)
	msg_send(nil, link, "setDelegate:", target)
	// Frames queued ahead of the screen. 1 is the shortest wait from input to screen.
	msg_send(nil, link, "setPreferredFrameLatency:", f32(1))
	msg_send(nil, link, "addToRunLoop:forMode:", NS.RunLoop.mainRunLoop(), NS.RunLoopCommonModes)
	msg_send(nil, link, "setPaused:", NS.BOOL(true))

	return link
}

@(private = "file")
show_window :: proc(is_background: bool) {
	state.ns_window->center()

	if is_background {
		msg_send(nil, state.ns_window, "setCollectionBehavior:", NS.UInteger(TRANSIENT_WINDOW))
		msg_send(nil, state.ns_window, "orderBack:", rawptr(nil))
	} else {
		state.ns_window->makeKeyAndOrderFront(nil)
		state.app->activate()
	}
	request_frame()
}
