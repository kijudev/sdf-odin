package main

import "core:log"
import "core:math/linalg"
import sdl "vendor:sdl3"

SHADER_SRC :: "shaders/sdf.slang"
MAX_PRIMITIVES :: 32

// How far blended surfaces can bulge past the shapes. Must be >= SMOOTH_K in sdf.slang
SCENE_BOUNDS_MARGIN :: 0.1

// Must match the KIND_* constants in sdf.slang
Sdf_Kind :: enum u32 {
	Sphere,
	Box,
	Torus,
	Capsule,
	Cylinder,
}

// Layout matches Sdf_Primitive in sdf.slang (48 bytes, std140 friendly)
Sdf_Primitive :: struct {
	pos:          [3]f32,
	kind:         Sdf_Kind,
	params:       [4]f32,
	color:        [3]f32,
	// radius of a sphere around pos that fully contains the shape, lets the shader skip far shapes
	bound_radius: f32,
}

#assert(size_of(Sdf_Primitive) == 48)

Frag_Uniforms :: struct {
	resolution:      [2]f32,
	time:            f32,
	primitive_count: u32,
	camera:          Gpu_Camera,
	// box around every primitive, rays are clipped to it
	bounds_min:      [3]f32,
	_pad0:           f32,
	bounds_max:      [3]f32,
	_pad1:           f32,
	primitives:      [MAX_PRIMITIVES]Sdf_Primitive,
}

Color :: [3]f32

sdf_sphere :: proc(pos: [3]f32, radius: f32, color: Color) -> Sdf_Primitive {
	return {
		pos = pos,
		kind = .Sphere,
		params = {radius, 0, 0, 0},
		color = color,
		bound_radius = radius,
	}
}

sdf_box :: proc(pos: [3]f32, half_extents: [3]f32, color: Color) -> Sdf_Primitive {
	return {
		pos = pos,
		kind = .Box,
		params = {half_extents.x, half_extents.y, half_extents.z, 0},
		color = color,
		bound_radius = linalg.length(half_extents),
	}
}

sdf_torus :: proc(pos: [3]f32, major_radius, minor_radius: f32, color: Color) -> Sdf_Primitive {
	return {
		pos = pos,
		kind = .Torus,
		params = {major_radius, minor_radius, 0, 0},
		color = color,
		bound_radius = major_radius + minor_radius,
	}
}

sdf_capsule :: proc(pos: [3]f32, half_height, radius: f32, color: Color) -> Sdf_Primitive {
	return {
		pos = pos,
		kind = .Capsule,
		params = {half_height, radius, 0, 0},
		color = color,
		bound_radius = half_height + radius,
	}
}

sdf_cylinder :: proc(pos: [3]f32, half_height, radius: f32, color: Color) -> Sdf_Primitive {
	return {
		pos = pos,
		kind = .Cylinder,
		params = {half_height, radius, 0, 0},
		color = color,
		bound_radius = linalg.length([2]f32{half_height, radius}),
	}
}

Renderer :: struct {
	window:   ^sdl.Window,
	device:   ^sdl.GPUDevice,
	pipeline: ^sdl.GPUGraphicsPipeline,
	watch:    Shader_Watch,
}

renderer_init :: proc(r: ^Renderer, window: ^sdl.Window) {
	r.window = window
	r.device = sdl.CreateGPUDevice({.SPIRV}, ODIN_DEBUG, nil)

	if r.device == nil do log.panicf("SDL_CreateGPUDevice failed: %s", sdl.GetError())
	if !sdl.ClaimWindowForGPUDevice(r.device, window) do log.panicf("SDL_ClaimWindowForGPUDevice failed: %s", sdl.GetError())

	r.watch = {
		path = SHADER_SRC,
	}

	shader_watch_changed(&r.watch)
	renderer_reload_pipeline(r)
}

renderer_destroy :: proc(r: ^Renderer) {
	if r.pipeline != nil do sdl.ReleaseGPUGraphicsPipeline(r.device, r.pipeline)
	sdl.ReleaseWindowFromGPUDevice(r.device, r.window)
	sdl.DestroyGPUDevice(r.device)
}

renderer_reload_pipeline :: proc(r: ^Renderer) {
	vs := shader_compile_and_load(r.device, SHADER_SRC, "vertex_main", .VERTEX, 0)
	if vs == nil do return
	defer sdl.ReleaseGPUShader(r.device, vs)

	fs := shader_compile_and_load(r.device, SHADER_SRC, "fragment_main", .FRAGMENT, 1)
	if fs == nil do return
	defer sdl.ReleaseGPUShader(r.device, fs)

	color_desc := sdl.GPUColorTargetDescription {
		format = sdl.GetGPUSwapchainTextureFormat(r.device, r.window),
	}
	pipeline := sdl.CreateGPUGraphicsPipeline(
		r.device,
		{
			vertex_shader = vs,
			fragment_shader = fs,
			primitive_type = .TRIANGLELIST,
			target_info = {color_target_descriptions = &color_desc, num_color_targets = 1},
		},
	)

	if pipeline == nil {
		log.errorf("SDL_CreateGPUGraphicsPipeline failed: %s", sdl.GetError())
		return
	}

	if r.pipeline != nil do sdl.ReleaseGPUGraphicsPipeline(r.device, r.pipeline)
	r.pipeline = pipeline
	log.info("pipeline reloaded")
}

renderer_draw :: proc(r: ^Renderer, time: f32, camera: Camera, primitives: []Sdf_Primitive) {
	cmd := sdl.AcquireGPUCommandBuffer(r.device)
	if cmd == nil {
		log.errorf("SDL_AcquireGPUCommandBuffer failed: %s", sdl.GetError())
		return
	}

	swapchain: ^sdl.GPUTexture
	w, h: u32

	if !sdl.WaitAndAcquireGPUSwapchainTexture(cmd, r.window, &swapchain, &w, &h) {
		log.errorf("SDL_WaitAndAcquireGPUSwapchainTexture failed: %s", sdl.GetError())
	}

	if swapchain != nil {
		uniforms := Frag_Uniforms {
			resolution = {f32(w), f32(h)},
			time       = time,
			camera     = camera_to_gpu(camera),
		}

		count := min(len(primitives), MAX_PRIMITIVES)
		copy(uniforms.primitives[:], primitives[:count])
		uniforms.primitive_count = u32(count)

		uniforms.bounds_min = max(f32)
		uniforms.bounds_max = min(f32)
		for prim in primitives[:count] {
			extent := prim.bound_radius + SCENE_BOUNDS_MARGIN
			uniforms.bounds_min = linalg.min(uniforms.bounds_min, prim.pos - extent)
			uniforms.bounds_max = linalg.max(uniforms.bounds_max, prim.pos + extent)
		}

		sdl.PushGPUFragmentUniformData(cmd, 0, &uniforms, size_of(uniforms))

		target := sdl.GPUColorTargetInfo {
			texture     = swapchain,
			clear_color = {0.1, 0.0, 0.1, 1.0},
			load_op     = .CLEAR,
			store_op    = .STORE,
		}

		pass := sdl.BeginGPURenderPass(cmd, &target, 1, nil)
		if r.pipeline != nil {
			sdl.BindGPUGraphicsPipeline(pass, r.pipeline)
			sdl.DrawGPUPrimitives(pass, 3, 1, 0, 0) // fullscreen triangle
		}

		sdl.EndGPURenderPass(pass)
	}

	_ = sdl.SubmitGPUCommandBuffer(cmd)
}
