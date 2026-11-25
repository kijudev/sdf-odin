package game

import "../../libs/ecs"

Light_Kind :: enum u32 {
	Directional,
	Point,
}

Light :: struct {
	kind:      Light_Kind,
	dir:       Vec3,
	color:     Color,
	intensity: f32,
}

light_spawn :: proc(stuff: Stuff, pos: Vec3, light: Light) -> Thing {
	thing := ecs.spawn(stuff)
	ecs.set_now(stuff, thing, .Transform, Transform{pos = pos})
	ecs.set_now(stuff, thing, .Light, light)
	return thing
}
