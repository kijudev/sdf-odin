package game

import "../../libs/ecs"
import "core:math"
import "core:math/linalg"
import sdl "vendor:sdl3"

// >---------------------------------------------------------------- Camera Part

CAMERA_DEFAULT_MOVE_SPEED :: 3.0
CAMERA_DEFAULT_FAST_MULT :: 4.0
CAMERA_DEFAULT_SENSITIVITY :: 0.003
CAMERA_DEFAULT_FOCAL_LENGTH :: 1.0
CAMERA_MAX_PITCH :: 1.55

Camera :: struct {
	yaw:          f32,
	pitch:        f32,
	focal_length: f32,
	move_speed:   f32,
	fast_mult:    f32,
	sensitivity:  f32,
	looking:      bool,
}

Gpu_Camera :: struct {
	pos:          Vec3,
	focal_length: f32,
	forward:      Vec3,
	_pad0:        f32,
	right:        Vec3,
	_pad1:        f32,
	up:           Vec3,
	_pad2:        f32,
}

#assert(size_of(Gpu_Camera) == 64)

camera_spawn :: proc(stuff: Stuff, pos, target: Vec3) -> Thing {
	camera := Camera {
		focal_length = CAMERA_DEFAULT_FOCAL_LENGTH,
		move_speed   = CAMERA_DEFAULT_MOVE_SPEED,
		fast_mult    = CAMERA_DEFAULT_FAST_MULT,
		sensitivity  = CAMERA_DEFAULT_SENSITIVITY,
	}
	camera_look_at(&camera, pos, target)

	thing := ecs.spawn(stuff)
	ecs.set_now(stuff, thing, .Transform, Transform{pos = pos})
	ecs.set_now(stuff, thing, .Camera, camera)
	return thing
}

camera_forward :: proc(camera: Camera) -> Vec3 {
	cp := math.cos(camera.pitch)
	return {math.sin(camera.yaw) * cp, math.sin(camera.pitch), -math.cos(camera.yaw) * cp}
}

camera_right :: proc(camera: Camera) -> Vec3 {
	return {math.cos(camera.yaw), 0, math.sin(camera.yaw)}
}

camera_up :: proc(camera: Camera) -> Vec3 {
	return linalg.cross(camera_right(camera), camera_forward(camera))
}

camera_look_at :: proc(camera: ^Camera, pos, target: Vec3) {
	if pos == target do return

	dir := linalg.normalize(target - pos)
	camera.yaw = math.atan2(dir.x, -dir.z)
	camera.pitch = clamp(math.asin(dir.y), -CAMERA_MAX_PITCH, CAMERA_MAX_PITCH)
}

camera_screen_ray :: proc(
	camera: Camera,
	pos: Vec3,
	pixel, resolution: Vec2,
) -> (
	origin, dir: Vec3,
) {
	uv := (2 * pixel - resolution) / resolution.y
	uv.y = -uv.y

	dir = linalg.normalize(
		uv.x * camera_right(camera) +
		uv.y * camera_up(camera) +
		camera.focal_length * camera_forward(camera),
	)

	return pos, dir
}

// Returns false when `point` is behind the camera.
camera_world_to_screen :: proc(
	camera: Camera,
	pos, point: Vec3,
	resolution: Vec2,
) -> (
	Vec2,
	bool,
) {
	rel := point - pos
	z := linalg.dot(rel, camera_forward(camera))
	if z <= 0 do return {}, false

	uv :=
		Vec2{linalg.dot(rel, camera_right(camera)), linalg.dot(rel, camera_up(camera))} *
		camera.focal_length /
		z
	uv.y = -uv.y
	return (uv * resolution.y + resolution) * 0.5, true
}

// >-------------------------------------------------------------------- Systems

// Stage:  Input.
// Reads:  Window, Events.
// Writes: Camera.
camera_look_system :: proc(stuff: Stuff) {
	window := get_window(stuff)
	events := get_events(stuff)

	query := ecs.query_make(stuff, {.Camera}, {})
	for _ in ecs.query_iter(&query) {
		camera := ecs.write_part(&query, .Camera, Camera)

		for ev in events {
			#partial switch ev.type {
			case .MOUSE_BUTTON_DOWN:
				if ev.button.button == sdl.BUTTON_RIGHT {
					camera.looking = true
					_ = sdl.SetWindowRelativeMouseMode(window, true)
				}
			case .MOUSE_BUTTON_UP:
				if ev.button.button == sdl.BUTTON_RIGHT {
					camera.looking = false
					_ = sdl.SetWindowRelativeMouseMode(window, false)
				}
			case .MOUSE_MOTION:
				if camera.looking {
					camera.yaw += ev.motion.xrel * camera.sensitivity
					camera.pitch -= ev.motion.yrel * camera.sensitivity
					camera.pitch = clamp(camera.pitch, -CAMERA_MAX_PITCH, CAMERA_MAX_PITCH)
				}
			}
		}
	}
}

// Stage:  Update.
// Reads:  Time, Camera.
// Writes: Transform.
camera_move_system :: proc(stuff: Stuff) {
	dt := get_time(stuff).dt
	keys := sdl.GetKeyboardState(nil)

	query := ecs.query_make(stuff, {.Camera, .Transform}, {})
	for _ in ecs.query_iter(&query) {
		camera := ecs.get_part(&query, .Camera, Camera)
		transform := ecs.write_part(&query, .Transform, Transform)

		forward := camera_forward(camera)
		right := camera_right(camera)

		move: Vec3
		if keys[sdl.Scancode.W] do move += forward
		if keys[sdl.Scancode.S] do move -= forward
		if keys[sdl.Scancode.D] do move += right
		if keys[sdl.Scancode.A] do move -= right
		if keys[sdl.Scancode.SPACE] do move += VEC3_UP
		if keys[sdl.Scancode.LCTRL] do move -= VEC3_UP

		if linalg.length(move) > 0 {
			speed := camera.move_speed
			if keys[sdl.Scancode.LSHIFT] do speed *= camera.fast_mult
			transform.pos += linalg.normalize(move) * speed * dt
		}
	}
}
