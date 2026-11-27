package main

import "core:log"
import "game"
import sdl "vendor:sdl3"

main :: proc() {
	context.logger = log.create_console_logger()
	if !sdl.Init({.VIDEO}) do log.panicf("SDL_Init failed: %s", sdl.GetError())
	defer sdl.Quit()

	window := sdl.CreateWindow("sdf-odin", 1280, 720, {.RESIZABLE, .HIGH_PIXEL_DENSITY})
	if window == nil do log.panicf("SDL_CreateWindow failed: %s", sdl.GetError())
	defer sdl.DestroyWindow(window)

	world: game.World
	game.game_init(&world, window)
	defer game.game_destroy(&world)

	events := make([dynamic]sdl.Event)
	defer delete(events)

	main_loop: for {
		clear(&events)

		ev: sdl.Event
		for sdl.PollEvent(&ev) {
			#partial switch ev.type {
			case .QUIT:
				break main_loop
			case .KEY_DOWN:
				if ev.key.key == sdl.K_ESCAPE do break main_loop
			}

			append(&events, ev)
		}

		game.game_frame(&world, events[:])
		free_all(context.temp_allocator)
	}
}
