package game

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:time"
import sdl "vendor:sdl3"

SHADER_OUT_DIR :: "build/shaders"

Shader_Watch :: struct {
	path:  string,
	mtime: time.Time,
}

shader_watch_changed :: proc(w: ^Shader_Watch) -> bool {
	mtime, err := os.modification_time_by_path(w.path)

	if err != nil || mtime == w.mtime do return false
	w.mtime = mtime

	return true
}

shader_compile :: proc(src, entry, stage, out_path: string) -> bool {
	state, stdout, stderr, err := os.process_exec(
		{
			command = {
				"slangc",
				src,
				"-target",
				"spirv",
				"-profile",
				"spirv_1_0",
				"-warnings-disable",
				"50011",
				"-entry",
				entry,
				"-stage",
				stage,
				"-o",
				out_path,
			},
		},
		context.temp_allocator,
	)

	if err != nil {
		log.errorf("failed to run slangc: %v", err)
		return false
	}

	if !state.success {
		log.errorf("slangc %s (%s) failed:\n%s%s", src, entry, stdout, stderr)
		return false
	}

	if len(stderr) > 0 do log.warnf("slangc %s (%s):\n%s", src, entry, stderr)
	return true
}

shader_compile_and_load :: proc(
	device: ^sdl.GPUDevice,
	src, entry: string,
	stage: sdl.GPUShaderStage,
	num_uniform_buffers: u32,
) -> ^sdl.GPUShader {
	if err := os.make_directory_all(SHADER_OUT_DIR); err != nil && err != .Exist {
		log.errorf("failed to create %s: %v", SHADER_OUT_DIR, err)
		return nil
	}

	slang_stage := stage == .VERTEX ? "vertex" : "fragment"
	stem := filepath.stem(src)
	out_path := fmt.tprintf("%s/%s.%s.spv", SHADER_OUT_DIR, stem, entry)

	if !shader_compile(src, entry, slang_stage, out_path) do return nil

	code, err := os.read_entire_file(out_path, context.temp_allocator)
	if err != nil {
		log.errorf("failed to read %s: %v", out_path, err)
		return nil
	}

	shader := sdl.CreateGPUShader(
		device,
		{
			code_size = len(code),
			code = raw_data(code),
			entrypoint = "main",
			format = {.SPIRV},
			stage = stage,
			num_uniform_buffers = num_uniform_buffers,
		},
	)

	if shader == nil {
		log.errorf("SDL_CreateGPUShader failed for %s: %s", out_path, sdl.GetError())
	}

	return shader
}
