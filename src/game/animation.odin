package game

import "../../libs/ecs"
import "core:math"

Animation :: struct {
	origin: Vec3,
	motion: Motion,
}

Motion :: union {
	Bounce,
	Slide,
	Orbit,
}

Bounce :: struct {
	height: f32,
	speed:  f32,
}

Slide :: struct {
	offset: Vec3,
	speed:  f32,
}

Orbit :: struct {
	radius: f32,
	speed:  f32,
}

animation_add :: proc(stuff: Stuff, thing: Thing, motion: Motion) {
	transform, _ := ecs.get_part(stuff, thing, .Transform, Transform)
	ecs.set_now(stuff, thing, .Animation, Animation{origin = transform.pos, motion = motion})
}

// Stage:  Update.
// Reads:  Time, Animation.
// Writes: Transform.
animation_system :: proc(stuff: Stuff) {
	t := get_time(stuff).t

	query := ecs.query_make(stuff, {.Animation, .Transform}, {})
	for _ in ecs.query_iter(&query) {
		animation := ecs.get_part(&query, .Animation, Animation)
		transform := ecs.write_part(&query, .Transform, Transform)

		offset: Vec3
		switch m in animation.motion {
		case Bounce:
			offset.y = abs(math.sin(t * m.speed)) * m.height
		case Slide:
			offset = m.offset * math.sin(t * m.speed)
		case Orbit:
			offset.xz = {math.cos(t * m.speed), math.sin(t * m.speed)} * m.radius
		}

		transform.pos = animation.origin + offset
	}
}
