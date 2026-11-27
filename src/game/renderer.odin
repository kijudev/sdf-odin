package game

import "../../libs/ecs"
import "core:log"
import "core:math/linalg"
import sdl "vendor:sdl3"

SHADER_SRC :: "shaders/sdf.slang"
MAX_PRIMITIVES :: 32
MAX_LIGHTS :: 8

// How far blended surfaces can bulge past the shapes. Must be >= SMOOTH_K in sdf.slang.
SCENE_BOUNDS_MARGIN :: 0.1

Sdf_Primitive :: struct {
	pos:          Vec3,
	kind:         Shape_Kind,
	params:       Vec4,
	color:        Color,
	bound_radius: f32,
}

#assert(size_of(Sdf_Primitive) == 48)

Gpu_Light :: struct {
	pos_or_dir: Vec3,
	kind:       Light_Kind,
	color:      Color,
	_pad:       f32,
}

#assert(size_of(Gpu_Light) == 32)

Frag_Uniforms :: struct {
	resolution:      Vec2,
	time:            f32,
	primitive_count: u32,
	camera:          Gpu_Camera,
	bounds_min:      Vec3,
	light_count:     u32,
	bounds_max:      Vec3,
	_pad1:           f32,
	primitives:      [MAX_PRIMITIVES]Sdf_Primitive,
	lights:          [MAX_LIGHTS]Gpu_Light,
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
	if r.device == nil do return
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

renderer_draw :: proc(
	r: ^Renderer,
	time: f32,
	camera: Gpu_Camera,
	primitives: []Sdf_Primitive,
	lights: []Gpu_Light,
) {
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
			camera     = camera,
		}

		count := min(len(primitives), MAX_PRIMITIVES)
		copy(uniforms.primitives[:], primitives[:count])
		uniforms.primitive_count = u32(count)

		light_count := min(len(lights), MAX_LIGHTS)
		copy(uniforms.lights[:], lights[:light_count])
		uniforms.light_count = u32(light_count)

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

write_renderer :: proc(stuff: Stuff) -> ^Renderer {
	return ecs.write_stash(stuff, .Renderer, Renderer)
}

// >-------------------------------------------------------------------- Systems

// Stage:  Render.
// Reads:  -.
// Writes: Renderer.
shader_reload_system :: proc(stuff: Stuff) {
	renderer := write_renderer(stuff)
	if shader_watch_changed(&renderer.watch) do renderer_reload_pipeline(renderer)
}

// Draws from the first camera, nothing if there is none.
// Stage:  Render.
// Reads:  Time, Camera, Transform, Shape, Light.
// Writes: Renderer.
render_system :: proc(stuff: Stuff) {
	camera_query := ecs.query_make(stuff, {.Camera, .Transform}, {})
	if _, ok := ecs.query_iter(&camera_query); !ok do return

	camera := ecs.get_part(&camera_query, .Camera, Camera)
	gpu_camera := Gpu_Camera {
		pos          = ecs.get_part(&camera_query, .Transform, Transform).pos,
		focal_length = camera.focal_length,
		forward      = camera_forward(camera),
		right        = camera_right(camera),
		up           = camera_up(camera),
	}

	primitives: [MAX_PRIMITIVES]Sdf_Primitive
	primitive_count := 0

	shape_query := ecs.query_make(stuff, {.Shape, .Transform}, {})
	for _ in ecs.query_iter(&shape_query) {
		if primitive_count == MAX_PRIMITIVES do break

		shape := ecs.get_part(&shape_query, .Shape, Shape)
		primitives[primitive_count] = {
			pos          = ecs.get_part(&shape_query, .Transform, Transform).pos,
			kind         = shape.kind,
			params       = shape.params,
			color        = shape.color,
			bound_radius = shape_bound_radius(shape),
		}

		primitive_count += 1
	}

	lights: [MAX_LIGHTS]Gpu_Light
	light_count := 0

	light_query := ecs.query_make(stuff, {.Light}, {})
	for thing in ecs.query_iter(&light_query) {
		if light_count == MAX_LIGHTS do break

		light := ecs.get_part(&light_query, .Light, Light)
		pos_or_dir: Vec3

		switch light.kind {
		case .Directional:
			pos_or_dir = linalg.normalize(light.dir)
		case .Point:
			transform, _ := ecs.get_part(stuff, thing, .Transform, Transform)
			pos_or_dir = transform.pos
		}

		lights[light_count] = {
			pos_or_dir = pos_or_dir,
			kind       = light.kind,
			color      = light.color * light.intensity,
		}

		light_count += 1
	}

	renderer_draw(
		write_renderer(stuff),
		get_time(stuff).t,
		gpu_camera,
		primitives[:primitive_count],
		lights[:light_count],
	)
}
