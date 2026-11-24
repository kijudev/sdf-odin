package main

import "core:math"
import "core:math/linalg"
import sdl "vendor:sdl3"

CAMERA_MOVE_SPEED :: 3.0
CAMERA_FAST_MULT :: 4.0
CAMERA_MOUSE_SENSITIVITY :: 0.003

// Free-fly camera: hold right mouse to look, WASD to move, Space/Ctrl for up/down, Shift for fast
Camera :: struct {
	pos:          [3]f32,
	yaw:          f32, // radians, 0 = looking down -Z
	pitch:        f32, // radians, positive = looking up
	focal_length: f32, // larger = narrower field of view
	looking:      bool,
}

// Layout matches Gpu_Camera in sdf.slang (each float3 padded to 16 bytes for std140)
Gpu_Camera :: struct {
	pos:          [3]f32,
	focal_length: f32,
	forward:      [3]f32,
	_pad0:        f32,
	right:        [3]f32,
	_pad1:        f32,
	up:           [3]f32,
	_pad2:        f32,
}

#assert(size_of(Gpu_Camera) == 64)

camera_forward :: proc(c: Camera) -> [3]f32 {
	cp := math.cos(c.pitch)
	return {math.sin(c.yaw) * cp, math.sin(c.pitch), -math.cos(c.yaw) * cp}
}

camera_handle_event :: proc(c: ^Camera, window: ^sdl.Window, ev: sdl.Event) {
	#partial switch ev.type {
	case .MOUSE_BUTTON_DOWN:
		if ev.button.button == sdl.BUTTON_RIGHT {
			c.looking = true
			_ = sdl.SetWindowRelativeMouseMode(window, true)
		}
	case .MOUSE_BUTTON_UP:
		if ev.button.button == sdl.BUTTON_RIGHT {
			c.looking = false
			_ = sdl.SetWindowRelativeMouseMode(window, false)
		}
	case .MOUSE_MOTION:
		if c.looking {
			c.yaw += ev.motion.xrel * CAMERA_MOUSE_SENSITIVITY
			c.pitch -= ev.motion.yrel * CAMERA_MOUSE_SENSITIVITY
			c.pitch = clamp(c.pitch, -1.55, 1.55) // stay just short of straight up/down
		}
	}
}

camera_update :: proc(c: ^Camera, dt: f32) {
	keys := sdl.GetKeyboardState(nil)

	forward := camera_forward(c^)
	right := linalg.normalize([3]f32{-forward.z, 0, forward.x})
	world_up := [3]f32{0, 1, 0}

	move: [3]f32
	if keys[sdl.Scancode.W] do move += forward
	if keys[sdl.Scancode.S] do move -= forward
	if keys[sdl.Scancode.D] do move += right
	if keys[sdl.Scancode.A] do move -= right
	if keys[sdl.Scancode.SPACE] do move += world_up
	if keys[sdl.Scancode.LCTRL] do move -= world_up

	if linalg.length(move) > 0 {
		speed: f32 = CAMERA_MOVE_SPEED
		if keys[sdl.Scancode.LSHIFT] do speed *= CAMERA_FAST_MULT
		c.pos += linalg.normalize(move) * speed * dt
	}
}

camera_to_gpu :: proc(c: Camera) -> Gpu_Camera {
	forward := camera_forward(c)
	right := linalg.normalize(linalg.cross(forward, [3]f32{0, 1, 0}))
	up := linalg.cross(right, forward)

	return {pos = c.pos, focal_length = c.focal_length, forward = forward, right = right, up = up}
}
