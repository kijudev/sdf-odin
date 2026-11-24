package main

import "core:log"
import sdl "vendor:sdl3"

main :: proc() {
	context.logger = log.create_console_logger()

	if !sdl.Init({.VIDEO}) {
		log.panicf("SDL_Init failed: %s", sdl.GetError())
	}
	defer sdl.Quit()

	window := sdl.CreateWindow("sdf-odin", 1280, 720, {.RESIZABLE, .HIGH_PIXEL_DENSITY})
	if window == nil {
		log.panicf("SDL_CreateWindow failed: %s", sdl.GetError())
	}
	defer sdl.DestroyWindow(window)

	renderer: Renderer
	renderer_init(&renderer, window)
	defer renderer_destroy(&renderer)

	camera := Camera {
		pos          = {0, 1.5, 5},
		pitch        = -0.2,
		focal_length = 1.5,
	}

	primitives := [?]Sdf_Primitive {
		sdf_sphere({-2.0, 0.6, 0.0}, 0.5, {0.9, 0.3, 0.3}),
		sdf_box({-1.0, 0.4, 0.0}, {0.35, 0.35, 0.35}, {0.3, 0.8, 0.4}),
		sdf_torus({0.0, 0.6, 0.0}, 0.4, 0.12, {0.3, 0.5, 0.9}),
		sdf_capsule({1.0, 0.7, 0.0}, 0.3, 0.25, {0.9, 0.8, 0.3}),
		sdf_cylinder({2.0, 0.5, 0.0}, 0.5, 0.3, {0.7, 0.4, 0.9}),
	}

	lights := [?]Light {
		light_directional({0.6, 0.8, 0.4}, {1.0, 0.95, 0.85}, 0.8),
		light_point({-1.5, 1.5, 1.0}, {1.0, 0.5, 0.2}, 2.0),
		light_point({1.5, 1.2, -1.0}, {0.2, 0.5, 1.0}, 2.0),
	}

	last_ticks := sdl.GetTicksNS()

	main_loop: for {
		ev: sdl.Event
		for sdl.PollEvent(&ev) {
			#partial switch ev.type {
			case .QUIT:
				break main_loop
			case .KEY_DOWN:
				if ev.key.key == sdl.K_ESCAPE do break main_loop
			}

			camera_handle_event(&camera, window, ev)
		}

		if shader_watch_changed(&renderer.watch) {
			renderer_reload_pipeline(&renderer)
		}

		now := sdl.GetTicksNS()
		dt := f32(now - last_ticks) / 1e9
		last_ticks = now
		t := f32(now) / 1e9

		camera_update(&camera, dt)

		renderer_draw(&renderer, t, camera, primitives[:], lights[:])
		free_all(context.temp_allocator)
	}
}
