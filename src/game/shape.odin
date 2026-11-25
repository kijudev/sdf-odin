package game

import "../../libs/ecs"
import "core:math/linalg"

Shape_Kind :: enum u32 {
	Sphere,
	Box,
	Torus,
	Capsule,
	Cylinder,
}

Shape :: struct {
	kind:   Shape_Kind,
	params: Vec4,
	color:  Color,
}

shape_sphere :: proc(radius: f32, color: Color) -> Shape {
	return {kind = .Sphere, params = {radius, 0, 0, 0}, color = color}
}

shape_box :: proc(half_extents: Vec3, color: Color) -> Shape {
	return {
		kind = .Box,
		params = {half_extents.x, half_extents.y, half_extents.z, 0},
		color = color,
	}
}

shape_torus :: proc(major_radius, minor_radius: f32, color: Color) -> Shape {
	return {kind = .Torus, params = {major_radius, minor_radius, 0, 0}, color = color}
}

shape_capsule :: proc(half_height, radius: f32, color: Color) -> Shape {
	return {kind = .Capsule, params = {half_height, radius, 0, 0}, color = color}
}

shape_cylinder :: proc(half_height, radius: f32, color: Color) -> Shape {
	return {kind = .Cylinder, params = {half_height, radius, 0, 0}, color = color}
}

shape_bound_radius :: proc(shape: Shape) -> f32 {
	p := shape.params

	switch shape.kind {
	case .Sphere:
		return p[0]
	case .Box:
		return linalg.length(p.xyz)
	case .Torus, .Capsule:
		return p[0] + p[1]
	case .Cylinder:
		return linalg.length(p.xy)
	}

	return 0
}

shape_spawn :: proc(stuff: Stuff, pos: Vec3, shape: Shape) -> Thing {
	thing := ecs.spawn(stuff)
	ecs.set_now(stuff, thing, .Transform, Transform{pos = pos})
	ecs.set_now(stuff, thing, .Shape, shape)
	return thing
}
