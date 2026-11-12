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

	r: Renderer
	renderer_init(&r, window)
	defer renderer_destroy(&r)

	main_loop: for {
		ev: sdl.Event
		for sdl.PollEvent(&ev) {
			#partial switch ev.type {
			case .QUIT:
				break main_loop
			case .KEY_DOWN:
				if ev.key.key == sdl.K_ESCAPE do break main_loop
			}
		}

		if shader_watch_changed(&r.watch) {
			renderer_reload_pipeline(&r)
		}

		renderer_draw(&r, f32(sdl.GetTicks()) / 1000.0)
		free_all(context.temp_allocator)
	}
}
