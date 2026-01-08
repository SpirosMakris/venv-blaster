package venv_blaster

// @TODO(spiros):
// - [x] Better arg parsing
// - [x] Verbose flag
// - [x] Scan hidden flag
// - [x] Improve walking
// - [] Improve output
// - [] Simplify mem handling
// - [] Simplify size calculation
// - [] Make clipboard pasting more secure

import "core:flags"
import "core:fmt"
import "core:log"
import "core:mem"
import vmem "core:mem/virtual"
import os "core:os/os2"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// Arg handling
Options :: struct {
	path:        string `args:"pos=0" usage:"The root directory to start scanning from."`,
	verbose:     bool `args:"name=verbose,v" usage:"Show every directory being skipped."`,
	errors:      bool `args:"name=errors,e" usage:"Display errors while scanning."`,
	scan_hidden: bool `args:"name=scan-hidden" usage:"Search inside hidden directories (like .git or .cache) for venvs."`,
}

Venv_Info :: struct {
	path: string,
	size: i64,
}

// Skip/error tracking
Ignored_Info :: struct {
	path:   string,
	reason: string,
}

main :: proc() {
	//  Track memory (for file_allocator in walker?)
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

	// Setup arena allocator
	arena: vmem.Arena
	if err := vmem.arena_init_growing(&arena); err != nil {
		fmt.eprintfln("Failed to initialize arena: %v", err)
		os.exit(1)
	}
	defer vmem.arena_destroy(&arena)
	alloc := vmem.arena_allocator(&arena)


	// Flag parsing
	opt: Options
	opt.path = "." // Default path
	flags.parse_or_exit(&opt, os.args, .Odin)

	path_info, path_err := os.stat(opt.path, alloc)
	if path_err != nil {
		fmt.eprintfln("Error: Path '%s' does not exist or is not accessible.", opt.path)
		os.exit(1)
	}
	if path_info.type != .Directory {
		fmt.eprintfln("Error: '%s' is not a directory.", opt.path)
		os.exit(1)
	}

	// Setup logger (default shows errors only)
	context.logger = log.create_console_logger(opt.verbose ? .Debug : .Error)

	found_venvs: [dynamic]Venv_Info
	found_venvs.allocator = alloc

	ignored: [dynamic]Ignored_Info
	ignored.allocator = alloc

	// @TODO(spiros): Style output
	fmt.printfln("Scanning: `%s`", opt.path)

	// Main walk
	w := os.walker_create(opt.path)
	defer os.walker_destroy(&w)

	for info in os.walker_walk(&w) {
		// Only interested in directories
		if info.type != .Directory do continue

		// Error handling (access denied, etc)
		if _, err := os.walker_error(&w); err != nil {
			assert(err == os.Platform_Error.EACCES)

			if opt.verbose && opt.errors do fmt.printfln("Skipping (Error): %s %s", info.fullpath, err)
			append(&ignored, Ignored_Info{info.fullpath, fmt.aprintf("%s", err)})

			os.walker_skip_dir(&w)
			continue
		}

		// Identify by signature
		cfg_path := filepath.join({info.fullpath, "pyvenv.cfg"}, alloc)

		if os.exists(cfg_path) {
			size := calculate_dir_size(info.fullpath, &arena)
			append(
				&found_venvs,
				Venv_Info{path = strings.clone(info.fullpath, alloc), size = size},
			)

			fmt.printfln(
				"[FOUND] %s (size: %v) with size: %.2f Mb",
				info.fullpath,
				size,
				f64(size) / mem.Megabyte,
			)

			// Since this is a venv, don't look for other venvs inside it
			os.walker_skip_dir(&w)
			continue
		}

		// Skip well-known/hidden directories
		// Only runs if we haven't identified an actual venv signature in this folder
		base := filepath.base(info.fullpath)
		is_hidden := len(base) > 1 && base[0] == '.'

		if is_hidden && !opt.scan_hidden {
			// We skip if not explicitly asked to scan hidden folders
			if opt.verbose do fmt.printfln("Skipping hidden: %s", info.fullpath)

			os.walker_skip_dir(&w)
			continue
		}

	}

	if len(found_venvs) == 0 {
		log.info("No virtual environments found")
		return
	}

	// Reporting

	// Sort by size
	slice.sort_by(found_venvs[:], proc(a, b: Venv_Info) -> bool {
		return a.size > b.size
	})

	total_size: i64 = 0
	sb: strings.Builder
	strings.builder_init(&sb, alloc)
	defer strings.builder_destroy(&sb)

	strings.write_string(&sb, "rm -rf \\\n")

	fmt.println("\nFound virtual envs:", len(found_venvs))
	fmt.println("--------------------------------------------------")

	escape_path :: proc(path: string, allocator := context.allocator) -> string {
		result: strings.Builder
		strings.builder_init(&result, allocator)
		for c in path {
			if c == '\'' {
				strings.write_byte(&result, '\\')
			}
			strings.write_byte(&result, u8(c))
		}
		return strings.to_string(result)
	}

	for venv, i in found_venvs {
		mb := f64(venv.size) / mem.Megabyte
		fmt.printf("[%.2f MB] %s\n", mb, venv.path)
		total_size += venv.size

		escaped := escape_path(venv.path, alloc)
		strings.write_string(&sb, "\t\"")
		strings.write_string(&sb, escaped)
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
	fmt.printfln("Num ignored: %d", len(ignored))

	// Generate command
	command := strings.to_string(sb)
	fmt.println("Command to clean:")
	fmt.println(command)

	if opt.errors {
		for file, i in ignored {
			if i > 3 do break
			fmt.printf("Unchecked: %s because: %s\n", file.path, file.reason)
		}
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
	escaped_contents: strings.Builder
	strings.builder_init(&escaped_contents, allocator)
	for c in contents {
		if c == '$' || c == '`' || c == '"' || c == '\\' {
			strings.write_byte(&escaped_contents, '\\')
		}
		strings.write_byte(&escaped_contents, u8(c))
	}
	escaped_str := strings.to_string(escaped_contents)

	cmd := fmt.aprintf(
		"printf '%%s' \"%s\" | xclip -selection clipboard",
		escaped_str,
		allocator = allocator,
	)
	fmt.println(cmd)
	defer delete(cmd, allocator)

	sh_cmd := [3]string{"sh", "-c", cmd}
	p_desc := os.Process_Desc {
		command = sh_cmd[:],
	}

	process, err := os.process_start(p_desc)
	if err == nil {
		_, _ = os.process_wait(process)
		fmt.println("\n(Command copied to clipboard.)")
	} else {
		fmt.printfln("\n(Failed to copy to clipboard. Ensure 'xclip' is installed.)")
	}
}
