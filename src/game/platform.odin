package game

import "../../libs/ecs"
import sdl "vendor:sdl3"

// >--------------------------------------------------------------- Window Stash

Window :: struct {
	handle: ^sdl.Window,
}

get_window :: proc(stuff: Stuff) -> ^sdl.Window {
	return ecs.get_stash(stuff, .Window, Window).handle
}

// >----------------------------------------------------------------- Time Stash

Time :: struct {
	dt:         f32,
	t:          f32,
	last_ticks: u64,
}

get_time :: proc(stuff: Stuff) -> Time {
	return ecs.get_stash(stuff, .Time, Time)
}

// Stage:  Input.
// Reads:  -.
// Writes: Time.
time_system :: proc(stuff: Stuff) {
	time := ecs.write_stash(stuff, .Time, Time)

	now := sdl.GetTicksNS()
	time.dt = time.last_ticks == 0 ? 0 : f32(now - time.last_ticks) / 1e9
	time.t = f32(now) / 1e9
	time.last_ticks = now
}

// >--------------------------------------------------------------- Events Stash

Events :: struct {
	list: [dynamic]sdl.Event,
}

get_events :: proc(stuff: Stuff) -> []sdl.Event {
	return ecs.get_stash(stuff, .Events, Events).list[:]
}
