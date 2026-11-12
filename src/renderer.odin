package main

import "core:log"
import sdl "vendor:sdl3"

SHADER_SRC :: "shaders/sdf.slang"

Frag_Uniforms :: struct {
	resolution: [2]f32,
	time:       f32,
	_:          f32,
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

renderer_draw :: proc(r: ^Renderer, time: f32) {
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
