package game

import "../../libs/ecs"
import sdl "vendor:sdl3"

game_init :: proc(world: ^World, window: ^sdl.Window) {
	ecs.world_init(world)

	ecs.register_part(world, .Camera, Camera)
	ecs.register_part(world, .Transform, Transform)
	ecs.register_part(world, .Shape, Shape)
	ecs.register_part(world, .Light, Light)
	ecs.register_part(world, .Animation, Animation)

	ecs.register_stash(world, .Window, Window)
	ecs.register_stash(world, .Time, Time)
	ecs.register_stash(world, .Events, Events, proc(stash: rawptr) {
		delete((^Events)(stash).list)
	})
	ecs.register_stash(world, .Renderer, Renderer, proc(stash: rawptr) {
		renderer_destroy((^Renderer)(stash))
	})

	ecs.write_stash(world, .Window, Window).handle = window
	renderer_init(ecs.write_stash(world, .Renderer, Renderer), window)

	ecs.world_schedule(world, time_system, "time", .Input, {}, {.Time})
	ecs.world_schedule(
		world,
		camera_look_system,
		"camera_look",
		.Input,
		{.Window, .Events},
		{.Camera},
	)

	ecs.world_schedule(
		world,
		camera_move_system,
		"camera_move",
		.Update,
		{.Time, .Camera},
		{.Transform},
	)
	ecs.world_schedule(
		world,
		animation_system,
		"animation",
		.Update,
		{.Time, .Animation},
		{.Transform},
	)

	ecs.world_schedule(world, shader_reload_system, "shader_reload", .Render, {}, {.Renderer})
	ecs.world_schedule(
		world,
		render_system,
		"render",
		.Render,
		{.Time, .Camera, .Transform, .Shape, .Light},
		{.Renderer},
	)

	game_spawn_scene(ecs.stuff_make(world))
}

game_frame :: proc(world: ^World, events: []sdl.Event) {
	list := &ecs.write_stash(world, .Events, Events).list
	clear(list)
	append(list, ..events)

	ecs.world_run_sync(world)
}

game_destroy :: proc(world: ^World) {
	ecs.world_destroy(world)
}

game_spawn_scene :: proc(stuff: Stuff) {
	camera_spawn(stuff, {0, 1.5, 5}, {0, 0.5, 0})

	sphere := shape_spawn(stuff, {-2.0, 0.6, 0.0}, shape_sphere(0.5, {0.9, 0.3, 0.3}))
	shape_spawn(stuff, {-1.0, 0.4, 0.0}, shape_box({0.35, 0.35, 0.35}, {0.3, 0.8, 0.4}))
	torus := shape_spawn(stuff, {0.0, 0.6, 0.0}, shape_torus(0.4, 0.12, {0.3, 0.5, 0.9}))
	capsule := shape_spawn(stuff, {1.0, 0.7, 0.0}, shape_capsule(0.3, 0.25, {0.9, 0.8, 0.3}))
	shape_spawn(stuff, {2.0, 0.5, 0.0}, shape_cylinder(0.5, 0.3, {0.7, 0.4, 0.9}))

	animation_add(stuff, sphere, Bounce{height = 0.8, speed = 2.0})
	animation_add(stuff, torus, Slide{offset = {0.8, 0, 0}, speed = 0.7})
	animation_add(stuff, capsule, Orbit{radius = 0.5, speed = 1.0})

	light_spawn(
		stuff,
		{},
		Light {
			kind = .Directional,
			dir = {0.6, 0.8, 0.4},
			color = {1.0, 0.95, 0.85},
			intensity = 0.8,
		},
	)

	light_spawn(
		stuff,
		{-1.5, 1.5, 1.0},
		Light{kind = .Point, color = {1.0, 0.5, 0.2}, intensity = 4.0},
	)

	light_spawn(
		stuff,
		{1.5, 1.2, -1.0},
		Light{kind = .Point, color = {0.2, 0.5, 1.0}, intensity = 2.0},
	)
}
