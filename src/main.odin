package main

import "core:log"
import "core:math"
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

	boxes: [3]Sdf_Box

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

		if shader_watch_changed(&renderer.watch) {
			renderer_reload_pipeline(&renderer)
		}

		t := f32(sdl.GetTicks()) / 1000.0

		for &b, i in boxes {
			fi := f32(i)
			b.pos = {(fi - 1) * 0.6, math.sin(t + fi) * 0.4}
			b.size = {0.15, 0.15}
		}

		renderer_draw(&renderer, t, boxes[:])
		free_all(context.temp_allocator)
	}
}
