package platform

import "base:intrinsics"
import NS "core:sys/darwin/Foundation"

@(objc_class = "NSVisualEffectView")
Visual_Effect_View :: struct {
	using _: NS.View,
}

@(objc_class = "CALayer")
Layer :: struct {
	using _: NS.Object,
}

@(objc_class = "OMBlurView", objc_superclass = Visual_Effect_View, objc_implement)
Blur_View :: struct {
	using _: Visual_Effect_View,
}

// Tints the blur with color, in sRGB. The window server paints it under each frame, so a scrolled
// frame does not shade every pixel of the window for it.
set_background :: proc(color: [4]f32) {
	ns_color := objc_send(
		^NS.Color,
		NS.Color,
		"colorWithSRGBRed:green:blue:alpha:",
		NS.Float(color.r),
		NS.Float(color.g),
		NS.Float(color.b),
		NS.Float(color.a),
	)

	objc_send(
		nil,
		state.window.layer,
		"setBackgroundColor:",
		objc_send(rawptr, ns_color, "CGColor"),
	)
}

// Lets the blur view run AppKit's own updateLayer before it removes the tint.
@(private)
Objc_Super :: struct {
	receiver:    ^Blur_View,
	super_class: NS.Class,
}

// AppKit puts back its tint and saturation layers each time it updates the blur.
@(objc_type = Blur_View, objc_implement, objc_name = "updateLayer")
Blur_View_updateLayer :: proc "c" (self: ^Blur_View) {
	super := Objc_Super{self, NS.Class(intrinsics.objc_find_class("NSVisualEffectView"))}
	objc_msgSendSuper(&super, NS.SEL(intrinsics.objc_find_selector("updateLayer")))
	remove_layer_background(objc_send(^Layer, self, "layer"))
}

@(private)
remove_layer_background :: proc "c" (layer: ^Layer) {
	// The Metal layer's colour is the window's own tint, from set_background.
	if layer == nil || rawptr(layer) == rawptr(state.window.layer) do return

	objc_send(nil, layer, "setBackgroundColor:", rawptr(nil))

	class_name := objc_send(^NS.String, layer, "className")

	// CAChameleonLayer tints the blur with the desktop colour.
	if objc_send(NS.BOOL, class_name, "isEqualToString:", NS.AT("CAChameleonLayer")) {
		objc_send(nil, layer, "setHidden:", NS.BOOL(true))
		return
	}

	filters := objc_send(^NS.Array, layer, "filters")

	if filters != nil {
		kept := NS.MutableArray.alloc()->init()

		for index in 0 ..< filters->count() {
			filter := filters->object(index)
			description := objc_send(^NS.String, filter, "description")

			// The blur raises saturation with a filter named "colorSaturate".
			if objc_send(NS.BOOL, description, "containsString:", NS.AT("Saturat")) do continue

			objc_send(nil, kept, "addObject:", filter)
		}

		objc_send(nil, layer, "setFilters:", kept)
		kept->release()
	}

	sublayers := objc_send(^NS.Array, layer, "sublayers")

	if sublayers == nil do return

	for index in 0 ..< sublayers->count() {
		// Every sublayer of a CALayer is a CALayer.
		remove_layer_background(cast(^Layer)sublayers->object(index))
	}
}
