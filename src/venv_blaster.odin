package venv_blaster

import "core:fmt"
import "core:log"
import "core:mem"
import vmem "core:mem/virtual"
import os "core:os/os2"
import "core:path/filepath"
import "core:slice"
import "core:strings"

Venv_Info :: struct {
	path: string,
	size: i64,
}

Unchecked :: struct {
	path:   string,
	reason: string,
}

main :: proc() {
	// Setup logger
	logger := log.create_console_logger(.Debug)
	context.logger = logger

	// Track memory
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)
		defer {
			log.errorf("%d leaked allocations", len(track.allocation_map))
			i: int
			for _, entry in track.allocation_map {
				log.errorf("%d %v leaked %v bytes\n", i, entry.location, entry.size)
				if i > 5 do break
				i += 1
			}

			mem.tracking_allocator_destroy(&track)
		}
	}

	arena: vmem.Arena
	if err := vmem.arena_init_growing(&arena); err != nil {
		log.errorf("Failed to initialize arena: %s", err)
		os.exit(-1)
	}
	defer vmem.arena_destroy(&arena)
	arena_alloc := vmem.arena_allocator(&arena)


	// Determine start directory
	start_dir := "."
	if len(os.args) > 1 {
		start_dir = os.args[1]
	}

	found_venvs, _ := make_dynamic_array([dynamic]Venv_Info, arena_alloc)
	defer delete(found_venvs)

	unchecked, _ := make_dynamic_array([dynamic]Unchecked, arena_alloc)
	defer delete(unchecked)

	fmt.printfln("Start scanning for ruffian venvs in: `%s`", start_dir)

	// Walk the path
	w := os.walker_create(start_dir)
	defer os.walker_destroy(&w)

	for info in os.walker_walk(&w) {

		if info.type == .Directory {
			if path, err := os.walker_error(&w); err != nil {
				reason := fmt.aprintfln("%s", err, allocator = arena_alloc)
				append(&unchecked, Unchecked{path, reason})
				os.walker_skip_dir(&w)
				continue
			}
			// Skip well-known directories
			if strings.has_suffix(info.fullpath, ".git") {
				fmt.printfln("Skipping .git dir at: %s", info.fullpath)
				os.walker_skip_dir(&w)
				continue
			}

			cfg_path := filepath.join({info.fullpath, "pyvenv.cfg"}, arena_alloc)

			if os.exists(cfg_path) {
				size := calculate_dir_size(info.fullpath, &arena)
				append(
					&found_venvs,
					Venv_Info {
						path = fmt.aprintf("%s", info.fullpath, allocator = arena_alloc),
						size = size,
					},
				)

				fmt.printfln(
					"Found .venv in `%s` with size: %.2f Mb",
					info.fullpath,
					f32(size) / f32(mem.Megabyte),
				)

				os.walker_skip_dir(&w)
				continue
			}
		}
	}

	if len(found_venvs) == 0 {
		log.info("No virtual environments found")
		return
	}

	// Output

	// Sort by size
	slice.sort_by(
		found_venvs[:],
		proc(a, b: Venv_Info) -> bool {
			return b.size < a.size // Descending, true if b size should come before a
		},
	)

	total_size: i64 = 0
	sb: strings.Builder
	strings.builder_init(&sb, arena_alloc)
	defer strings.builder_destroy(&sb)

	strings.write_string(&sb, "rm -rf \\\n")

	fmt.println("\nFound virtual envs:", len(found_venvs))
	fmt.println("--------------------------------------------------")

	for venv, i in found_venvs {
		mb := f64(venv.size) / mem.Megabyte
		fmt.printf("[%.2f MB] %s\n", mb, venv.path)
		total_size += venv.size

		// Add to command string
		strings.write_string(&sb, "\t\"")
		strings.write_string(&sb, venv.path)
    strings.write_string(&sb, "\" ")
    if (i < (len(found_venvs) - 1)) {
      strings.write_string(&sb, "\\\n")
    } else {
      strings.write_string(&sb, "\n")
    }
	}

	total_mb := f64(total_size) / mem.Megabyte


	fmt.println("--------------------------------------------------")
	fmt.printf("Total potential space savings: %.2f MB\n\n", total_mb)
	fmt.printfln("Num unchecked: %d", len(unchecked))

	// Generate command
	command := strings.to_string(sb)
	fmt.println("Command to clean:")
	fmt.println(command)


	fmt.printfln("Unchecked files: %d", len(unchecked))

	for file, i in unchecked {
		if i > 3 do break
		fmt.printf("Unckecked: %s because: %s\n", file.path, file.reason)
	}

	copy_to_clipboard_linux(command)

	vmem.arena_free_all(&arena)
}

calculate_dir_size :: proc(path: string, arena: ^vmem.Arena) -> i64 {
	temp := vmem.arena_temp_begin(arena)

	alloc := vmem.arena_allocator(arena)
	size: i64

	f, err := os.open(path)
	if err != nil {
		log.errorf("Failed to calculate size for dir: `%s` with error: %s", err)
		return 0
	}
	defer os.close(f)

	infos, _ := os.read_dir(f, -1, alloc)
	for info in infos {

		#partial switch info.type {
		case .Directory:
			{
				size += calculate_dir_size(info.fullpath, arena)

			}

		case .Regular:
			{
				size += info.size
			}

		case:
			{}

		}
	}

	vmem.arena_temp_end(temp)

	return size
}


copy_to_clipboard_linux :: proc(contents: string, allocator := context.allocator) {
	// Using xclip. Pipe the content into xclip -selection clipboard

	cmd := [3]string {
		"sh",
		"-c",
		fmt.aprintf("echo -n '%s' | xclip -selection clipboard", contents, allocator = allocator),
	}
	p_desc := os.Process_Desc {
		command = cmd[:],
	}

	process, err := os.process_start(p_desc)
	if err == nil {
		_, _ = os.process_wait(process)
		fmt.println("\n(Command copied to clipboard.)")
	} else {
		fmt.printfln("\n(Failed to copy to clipboard. Ensure 'xclip' is installed.)")
	}

}
