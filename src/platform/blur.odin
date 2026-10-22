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
		kept->release()
	}

	sublayers := msg_send(^NS.Array, layer, "sublayers")

	if sublayers == nil do return

	for index in 0 ..< sublayers->count() {
		remove_layer_background(cast(^Layer)sublayers->object(index))
	}
}
