package render

import "base:intrinsics"
import "core:fmt"
import "core:os"
import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"
import CA "vendor:darwin/QuartzCore"

msg_send :: intrinsics.objc_send

Kind :: enum u32 {
	Solid = 0,
	Glyph = 1,
	Image = 2,
}

// Pixels from the top left of the drawable. Matches Instance in shaders.metal.
Instance :: struct {
	rect:          [4]f32,
	uv:            [4]f32,
	color:         [4]f32,
	border_color:  [4]f32,
	clip:          [4]f32,
	corner_radius: f32,
	border_width:  f32,
	softness:      f32,
	kind:          Kind,
	// A solid fill fades from color to end_color between these shares of its height, when the second is larger.
	end_color:     [4]f32,
	gradient:      [2]f32,
	// Metal pads the struct to a multiple of 16 bytes.
	_:             [2]f32,
}

#assert(size_of(Instance) == 128)

// The instances drawn with one texture, in order.
@(private)
Batch :: struct {
	texture:     ^MTL.Texture,
	first_index: int,
	count:       int,
}

// Frames the GPU may still be drawing while the next one is built.
@(private)
FRAMES_IN_FLIGHT :: 3
@(private)
MAX_INSTANCE_COUNT :: 64 * 1024
// Instances a buffer starts with. A frame that draws more grows its buffer, so a short page costs 1 MB a buffer, not 8.
FIRST_INSTANCE_COUNT :: 8 * 1024

@(private)
state: struct {
	device:          ^MTL.Device,
	layer:           ^CA.MetalLayer,
	queue:           ^MTL.CommandQueue,
	pipeline:        ^MTL.RenderPipelineState,
	sampler:         ^MTL.SamplerState,
	white_texture:   ^MTL.Texture,
	buffers:         [FRAMES_IN_FLIGHT]^MTL.Buffer,
	command_buffers: [FRAMES_IN_FLIGHT]^MTL.CommandBuffer,
	frame_index:     int,
	instances:       [dynamic]Instance,
	batches:         [dynamic]Batch,
	size_pixels:     [2]f32,
	capture_path:    string,
}

@(private)
shader_source := #load("shaders.metal", string)

start :: proc(device: ^MTL.Device, layer: ^CA.MetalLayer) {
	state.device = device
	state.layer = layer
	state.queue = device->newCommandQueue()

	library, library_error := device->newLibraryWithSource(NS.String.alloc()->initWithOdinString(shader_source), nil)
	if library == nil do fmt.panicf("render: shaders do not compile: %s", library_error->localizedDescription()->odinString())

	descriptor := MTL.RenderPipelineDescriptor.alloc()->init()
	descriptor->setVertexFunction(library->newFunctionWithName(NS.AT("vertex_main")))
	descriptor->setFragmentFunction(library->newFunctionWithName(NS.AT("fragment_main")))

	// Shaders return premultiplied colour.
	attachment := descriptor->colorAttachments()->object(0)
	attachment->setPixelFormat(.BGRA8Unorm)
	attachment->setBlendingEnabled(true)
	attachment->setSourceRGBBlendFactor(.One)
	attachment->setDestinationRGBBlendFactor(.OneMinusSourceAlpha)
	attachment->setSourceAlphaBlendFactor(.One)
	attachment->setDestinationAlphaBlendFactor(.OneMinusSourceAlpha)

	pipeline, pipeline_error := device->newRenderPipelineStateWithDescriptor(descriptor)
	if pipeline == nil do fmt.panicf("render: no pipeline: %s", pipeline_error->localizedDescription()->odinString())
	state.pipeline = pipeline

	sampler_descriptor := MTL.SamplerDescriptor.alloc()->init()
	sampler_descriptor->setMinFilter(.Linear)
	sampler_descriptor->setMagFilter(.Linear)
	state.sampler = device->newSamplerState(sampler_descriptor)

	for &buffer in state.buffers {
		buffer = device->newBufferWithLength(FIRST_INSTANCE_COUNT * size_of(Instance), {})
	}

	white := [4]u8{255, 255, 255, 255}
	state.white_texture = make_texture({1, 1}, .RGBA8Unorm)
	upload_texture(state.white_texture, {0, 0, 1, 1}, raw_data(white[:]), 4)
}

make_texture :: proc(size_pixels: [2]int, format: MTL.PixelFormat) -> ^MTL.Texture {
	// The image threads have no autorelease pool of their own, and the descriptor is autoreleased.
	pool := NS.AutoreleasePool.alloc()->init()
	defer pool->drain()

	descriptor := MTL.TextureDescriptor.texture2DDescriptorWithPixelFormat(format, NS.UInteger(size_pixels.x), NS.UInteger(size_pixels.y), false)
	descriptor->setUsage({.ShaderRead})

	return state.device->newTextureWithDescriptor(descriptor)
}

// rect is x, y, width, height in pixels.
upload_texture :: proc(texture: ^MTL.Texture, rect: [4]int, pixels: rawptr, bytes_per_row: int) {
	region := MTL.Region{{NS.Integer(rect.x), NS.Integer(rect.y), 0}, {NS.Integer(rect.z), NS.Integer(rect.w), 1}}
	texture->replaceRegion(region, 0, pixels, NS.UInteger(bytes_per_row))
}

begin_frame :: proc(size_pixels: [2]f32) {
	state.size_pixels = size_pixels
	clear(&state.instances)
	clear(&state.batches)
}

push :: proc(instance: Instance, texture: ^MTL.Texture = nil) {
	if len(state.instances) >= MAX_INSTANCE_COUNT do return

	texture := texture if texture != nil else state.white_texture
	batch_count := len(state.batches)
	is_same_texture := batch_count > 0 && state.batches[batch_count - 1].texture == texture

	// A solid instance never samples, so it joins any batch.
	if is_same_texture || (batch_count > 0 && instance.kind == .Solid) {
		state.batches[batch_count - 1].count += 1
	} else {
		append(&state.batches, Batch{texture, len(state.instances), 1})
	}
	append(&state.instances, instance)
}

// The next frame is also saved to path as raw premultiplied BGRA pixels, for the development tests.
request_capture :: proc(path: string) {
	state.capture_path = path
}

@(private)
encode_pass :: proc(command_buffer: ^MTL.CommandBuffer, target: ^MTL.Texture, buffer: ^MTL.Buffer) {
	pass := MTL.RenderPassDescriptor.renderPassDescriptor()
	color := pass->colorAttachments()->object(0)
	color->setTexture(target)
	color->setLoadAction(.Clear)
	color->setClearColor({0, 0, 0, 0})
	color->setStoreAction(.Store)

	encoder := command_buffer->renderCommandEncoderWithDescriptor(pass)
	encoder->setRenderPipelineState(state.pipeline)
	encoder->setVertexBuffer(buffer, 0, 0)
	encoder->setFragmentBuffer(buffer, 0, 0)
	viewport := state.size_pixels
	encoder->setVertexBytes(([^]byte)(&viewport)[:size_of(viewport)], 1)
	encoder->setFragmentSamplerState(state.sampler, 0)

	for batch in state.batches {
		encoder->setFragmentTexture(batch.texture, 0)
		encoder->drawPrimitivesWithInstances(.TriangleStrip, 0, 4, NS.UInteger(batch.count), NS.UInteger(batch.first_index))
	}
	encoder->endEncoding()
}

@(private)
capture :: proc(buffer: ^MTL.Buffer) {
	size := [2]int{int(state.size_pixels.x), int(state.size_pixels.y)}
	descriptor := MTL.TextureDescriptor.texture2DDescriptorWithPixelFormat(.BGRA8Unorm, NS.UInteger(size.x), NS.UInteger(size.y), false)
	descriptor->setUsage({.RenderTarget, .ShaderRead})
	descriptor->setStorageMode(.Shared)
	target := state.device->newTextureWithDescriptor(descriptor)
	defer target->release()

	command_buffer := state.queue->commandBuffer()
	encode_pass(command_buffer, target, buffer)
	command_buffer->commit()
	command_buffer->waitUntilCompleted()

	pixels := make([]u8, size.x * size.y * 4)
	defer delete(pixels)
	region := MTL.Region{{0, 0, 0}, {NS.Integer(size.x), NS.Integer(size.y), 1}}
	target->getBytes(raw_data(pixels), NS.UInteger(size.x * 4), region, 0)
	_ = os.write_entire_file(state.capture_path, pixels)
	fmt.printfln("captured %dx%d to %s", size.x, size.y, state.capture_path)
	state.capture_path = ""
}

// drawable comes from the display link.
end_frame :: proc(drawable: ^CA.MetalDrawable) {
	slot := state.frame_index % FRAMES_IN_FLIGHT
	state.frame_index += 1

	// The buffer is written again only once the GPU has drawn the frame that used it.
	if previous := state.command_buffers[slot]; previous != nil {
		previous->waitUntilCompleted()
		previous->release()
		state.command_buffers[slot] = nil
	}

	buffer := state.buffers[slot]
	needed_bytes := len(state.instances) * size_of(Instance)

	// The GPU is done with this slot's buffer, so a larger one can take its place.
	if int(buffer->length()) < needed_bytes {
		capacity := int(buffer->length())
		for capacity < needed_bytes do capacity *= 2
		buffer->release()
		buffer = state.device->newBufferWithLength(NS.UInteger(capacity), {})
		state.buffers[slot] = buffer
	}

	intrinsics.mem_copy_non_overlapping(buffer->contentsPointer(), raw_data(state.instances), len(state.instances) * size_of(Instance))

	if state.capture_path != "" do capture(buffer)

	// A frame of a background window, timed by a timer, has no drawable and is only captured.
	if drawable == nil do return

	command_buffer := state.queue->commandBuffer()
	encode_pass(command_buffer, drawable->texture(), buffer)
	command_buffer->presentDrawable(drawable)
	command_buffer->commit()
	command_buffer->retain()
	state.command_buffers[slot] = command_buffer
}
