package render

import "base:intrinsics"
import "core:fmt"
import "core:mem"
import "core:os"
import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"
import CA "vendor:darwin/QuartzCore"

Kind :: enum u32 {
	Solid = 0,
	Glyph = 1,
	Image = 2,
}

// This struct matches Instance in shaders.metal.
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
	end_color:     [4]f32,
	gradient:      [2]f32,
	// Metal pads the struct to a multiple of 16 bytes.
	_:             [2]f32,
}

#assert(size_of(Instance) == 128)

@(private)
Batch :: struct {
	texture:     ^MTL.Texture,
	first_index: int,
	count:       int,
}

@(private)
FRAMES_IN_FLIGHT :: 3
@(private)
MAX_INSTANCE_COUNT :: 64 * 1024
INITIAL_INSTANCE_COUNT :: 8 * 1024
@(private)
QUAD_VERTEX_COUNT :: 4
@(private)
BYTES_PER_PIXEL :: 4

@(private)
state: struct {
	device:             ^MTL.Device,
	layer:              ^CA.MetalLayer,
	queue:              ^MTL.CommandQueue,
	pipeline:           ^MTL.RenderPipelineState,
	sampler:            ^MTL.SamplerState,
	white_texture:      ^MTL.Texture,
	buffers:            [FRAMES_IN_FLIGHT]^MTL.Buffer,
	command_buffers:    [FRAMES_IN_FLIGHT]^MTL.CommandBuffer,
	frame_index:        int,
	instances:          [dynamic]Instance,
	batches:            [dynamic]Batch,
	size_pixels:        [2]f32,
	capture_path:       string,
	shown_instances:    [dynamic]Instance,
	shown_batches:      [dynamic]Batch,
	shown_size_pixels:  [2]f32,
	shown_upload_count: int,
	upload_count:       int,
}

@(private)
shader_source := #load("shaders.metal", string)

start :: proc(device: ^MTL.Device, layer: ^CA.MetalLayer) {
	state.device = device
	state.layer = layer
	state.queue = device->newCommandQueue()

	library, library_error := device->newLibraryWithSource(
		NS.String.alloc()->initWithOdinString(shader_source),
		nil,
	)

	if library == nil {
		fmt.panicf(
			"render: shaders do not compile: %s",
			library_error->localizedDescription()->odinString(),
		)
	}

	descriptor := MTL.RenderPipelineDescriptor.alloc()->init()
	descriptor->setVertexFunction(library->newFunctionWithName(NS.AT("vertex_main")))
	descriptor->setFragmentFunction(library->newFunctionWithName(NS.AT("fragment_main")))

	// The shaders return premultiplied colour.
	attachment := descriptor->colorAttachments()->object(0)
	attachment->setPixelFormat(.BGRA8Unorm)
	attachment->setBlendingEnabled(true)
	attachment->setSourceRGBBlendFactor(.One)
	attachment->setDestinationRGBBlendFactor(.OneMinusSourceAlpha)
	attachment->setSourceAlphaBlendFactor(.One)
	attachment->setDestinationAlphaBlendFactor(.OneMinusSourceAlpha)

	pipeline, pipeline_error := device->newRenderPipelineStateWithDescriptor(descriptor)

	if pipeline == nil {
		fmt.panicf("render: no pipeline: %s", pipeline_error->localizedDescription()->odinString())
	}

	state.pipeline = pipeline

	sampler_descriptor := MTL.SamplerDescriptor.alloc()->init()
	sampler_descriptor->setMinFilter(.Linear)
	sampler_descriptor->setMagFilter(.Linear)
	state.sampler = device->newSamplerState(sampler_descriptor)

	for &buffer in state.buffers {
		buffer = device->newBufferWithLength(INITIAL_INSTANCE_COUNT * size_of(Instance), {})
	}

	white := [4]u8{255, 255, 255, 255}
	state.white_texture = make_texture({1, 1}, .RGBA8Unorm)
	upload_texture(state.white_texture, {0, 0, 1, 1}, raw_data(white[:]), BYTES_PER_PIXEL)
}

make_texture :: proc(size_pixels: [2]int, format: MTL.PixelFormat) -> ^MTL.Texture {
	// The image threads have no autorelease pool of their own. Metal autoreleases the descriptor.
	pool := NS.AutoreleasePool.alloc()->init()
	defer pool->drain()

	descriptor := MTL.TextureDescriptor.texture2DDescriptorWithPixelFormat(
		format,
		NS.UInteger(size_pixels.x),
		NS.UInteger(size_pixels.y),
		false,
	)

	descriptor->setUsage({.ShaderRead})

	return state.device->newTextureWithDescriptor(descriptor)
}

upload_texture :: proc(texture: ^MTL.Texture, region: [4]int, pixels: rawptr, bytes_per_row: int) {
	mtl_region := MTL.Region {
		{NS.Integer(region.x), NS.Integer(region.y), 0},
		{NS.Integer(region.z), NS.Integer(region.w), 1},
	}

	texture->replaceRegion(mtl_region, 0, pixels, NS.UInteger(bytes_per_row))
	intrinsics.atomic_add(&state.upload_count, 1)
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
	can_join := is_same_texture || (batch_count > 0 && instance.kind == .Solid)

	if can_join {
		state.batches[batch_count - 1].count += 1
	} else {
		append(&state.batches, Batch{texture, len(state.instances), 1})
	}

	append(&state.instances, instance)
}

request_capture :: proc(path: string) {
	state.capture_path = path
}

@(private)
encode_pass :: proc(
	command_buffer: ^MTL.CommandBuffer,
	target: ^MTL.Texture,
	buffer: ^MTL.Buffer,
) {
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
		encoder->drawPrimitivesWithInstances(
			.TriangleStrip,
			0,
			QUAD_VERTEX_COUNT,
			NS.UInteger(batch.count),
			NS.UInteger(batch.first_index),
		)
	}

	encoder->endEncoding()
}

@(private)
capture :: proc(buffer: ^MTL.Buffer) {
	size := [2]int{int(state.size_pixels.x), int(state.size_pixels.y)}
	descriptor := MTL.TextureDescriptor.texture2DDescriptorWithPixelFormat(
		.BGRA8Unorm,
		NS.UInteger(size.x),
		NS.UInteger(size.y),
		false,
	)

	descriptor->setUsage({.RenderTarget, .ShaderRead})
	descriptor->setStorageMode(.Shared)

	target := state.device->newTextureWithDescriptor(descriptor)
	defer target->release()

	command_buffer := state.queue->commandBuffer()
	encode_pass(command_buffer, target, buffer)
	command_buffer->commit()
	command_buffer->waitUntilCompleted()

	pixels := make([]u8, size.x * size.y * BYTES_PER_PIXEL)
	defer delete(pixels)
	region := MTL.Region{{0, 0, 0}, {NS.Integer(size.x), NS.Integer(size.y), 1}}

	target->getBytes(raw_data(pixels), NS.UInteger(size.x * BYTES_PER_PIXEL), region, 0)
	path := state.capture_path
	state.capture_path = ""

	if error := os.write_entire_file(path, pixels); error != nil {
		fmt.eprintfln("render: the capture to %s failed: %v", path, error)
		return
	}

	fmt.printfln("captured %dx%d to %s", size.x, size.y, path)
}

@(private)
is_same_as_shown :: proc(upload_count: int) -> bool {
	batch_bytes := mem.slice_to_bytes(state.batches[:])
	instance_bytes := mem.slice_to_bytes(state.instances[:])
	is_same_size := state.size_pixels == state.shown_size_pixels
	is_unchanged := upload_count == state.shown_upload_count
	is_same_batches := mem.compare(batch_bytes, mem.slice_to_bytes(state.shown_batches[:])) == 0
	is_same_instances :=
		mem.compare(instance_bytes, mem.slice_to_bytes(state.shown_instances[:])) == 0

	return is_same_size && is_unchanged && is_same_batches && is_same_instances
}

end_frame :: proc(drawable: ^CA.MetalDrawable) {
	upload_count := intrinsics.atomic_load(&state.upload_count)

	if drawable != nil && state.capture_path == "" && is_same_as_shown(upload_count) do return

	slot := state.frame_index % FRAMES_IN_FLIGHT
	state.frame_index += 1

	if previous := state.command_buffers[slot]; previous != nil {
		previous->waitUntilCompleted()
		previous->release()
		state.command_buffers[slot] = nil
	}

	buffer := state.buffers[slot]
	needed_bytes := len(state.instances) * size_of(Instance)

	if int(buffer->length()) < needed_bytes {
		capacity := int(buffer->length())
		for capacity < needed_bytes do capacity *= 2
		buffer->release()
		buffer = state.device->newBufferWithLength(NS.UInteger(capacity), {})
		state.buffers[slot] = buffer
	}

	intrinsics.mem_copy_non_overlapping(
		buffer->contentsPointer(),
		raw_data(state.instances),
		needed_bytes,
	)

	if state.capture_path != "" do capture(buffer)

	if drawable == nil do return

	command_buffer := state.queue->commandBuffer()
	encode_pass(command_buffer, drawable->texture(), buffer)
	command_buffer->presentDrawable(drawable)
	command_buffer->commit()
	command_buffer->retain()
	state.command_buffers[slot] = command_buffer

	state.instances, state.shown_instances = state.shown_instances, state.instances
	state.batches, state.shown_batches = state.shown_batches, state.batches
	// A frame drawn during a resize has the old size of the drawable. The layer stretches it.
	texture := drawable->texture()
	state.shown_size_pixels = {f32(texture->width()), f32(texture->height())}
	state.shown_upload_count = upload_count
}
