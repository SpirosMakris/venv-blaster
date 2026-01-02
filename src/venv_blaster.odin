package venv_blaster

// @TODO(spiros):
// - [x] Better arg parsing
// - [x] Verbose flag
// - [x] Scan hidden flag
// - [x] Improve walking
// - [x] Improve output
// - [x] Simplify mem handling
// - [x] Simplify size calculation
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

// Terminal escape codes
CLR_RESET :: "\x1b[0m"
CLR_RED :: "\x1b[31m"
CLR_GREEN :: "\x1b[32m"
CLR_CYAN :: "\x1b[36m"
CLR_GREY :: "\x1b[90m"


main :: proc() {
	// Setup arena allocator
	arena: vmem.Arena
	if err := vmem.arena_init_growing(&arena); err != nil {
		fmt.eprintfln("Failed to initialize arena: %v", err)
		os.exit(1)
	}

	defer {
		fmt.println("Freeing and destroying arena.")
		vmem.arena_free_all(&arena)
		vmem.arena_destroy(&arena)
	}
	alloc := vmem.arena_allocator(&arena)

	// Set our main allocator to our arena
	context.allocator = alloc

	//  Track memory (for file_allocator in walker?)
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)
		defer {
			fmt.println("Checking allocations.")
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

	// Flag parsing
	opt: Options
	opt.path = "." // Default path
	flags.parse_or_exit(&opt, os.args, .Odin)

	// Setup logger (default shows errors only)
	context.logger = log.create_console_logger(opt.verbose ? .Debug : .Error)

	// Will use context.allocator (set to arena)
	found_venvs: [dynamic]Venv_Info

	ignored: [dynamic]Ignored_Info

	// @TODO(spiros): Style output
	fmt.printfln("%sScanning: %s %s %s", CLR_GREEN, CLR_CYAN, opt.path, CLR_RESET)

	// Main walk
	w := os.walker_create(opt.path)
	defer os.walker_destroy(&w)

	for info in os.walker_walk(&w) {
		// Only interested in directories
		if info.type != .Directory do continue

		// Error handling (access denied, etc)
		if _, err := os.walker_error(&w); err != nil {
			assert(err == os.Platform_Error.EACCES)

			if opt.verbose && opt.errors do fmt.printfln("%sSkipping (Error): %s %s%s", CLR_RED, info.fullpath, err, CLR_RESET)
			error_str := fmt.aprintf("%v", err)
			append(&ignored, Ignored_Info{strings.clone(info.fullpath), strings.clone(error_str)})

			os.walker_skip_dir(&w)
			continue
		}

		// Identify by signature
		cfg_path := filepath.join({info.fullpath, "pyvenv.cfg"})

		if os.exists(cfg_path) {
			size := calculate_dir_size(info.fullpath)
			append(&found_venvs, Venv_Info{path = strings.clone(info.fullpath), size = size})

			if opt.verbose {

				fmt.printfln(
					"%s[FOUND]%s %s %s with size: %s Mb",
					CLR_GREEN,
					CLR_CYAN,
					info.fullpath,
					CLR_RESET,
					format_size(size),
				)
			}

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
			if opt.verbose do fmt.printfln("%sSkipping hidden: %s%s", CLR_GREY, info.fullpath, CLR_RESET)

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

	fmt.printfln("\n%-4s | %-12s | %s", "ID", "Size", "Path")
	fmt.println("-----|--------------|---------------------------------------------")

	total_size: i64
	for venv, i in found_venvs {
		total_size += venv.size
		fmt.printf(
			"%s% -4d | %-12s | %s%s\n",
			CLR_CYAN,
			i + 1,
			format_size(venv.size),
			venv.path,
			CLR_RESET,
		)
	}

	fmt.println("-----|--------------|---------------------------------------------")

	fmt.printf("Total potential savings: %s%s%s", CLR_GREEN, format_size(total_size), CLR_RESET)

	// Generate command
	cmd_builder: strings.Builder
	strings.builder_init(&cmd_builder)
	defer strings.builder_destroy(&cmd_builder)

	// Add to command string
	strings.write_string(&cmd_builder, "rm -rf \\\n")
	for v, i in found_venvs {
		strings.write_string(&cmd_builder, "\t\"")
		strings.write_string(&cmd_builder, v.path)
		strings.write_string(&cmd_builder, "\" ")
		if (i < (len(found_venvs) - 1)) {
			strings.write_string(&cmd_builder, "\\\n")
		} else {
			strings.write_string(&cmd_builder, "\n")
		}
	}

	final_cmd := strings.to_string(cmd_builder)

	fmt.println("\nCleanup command (copied to clipboard):")
	fmt.printfln("%s%s%s\n", CLR_RED, final_cmd, CLR_RESET)

	copy_to_clipboard_linux(final_cmd)

	// Ignored reporting
	if opt.errors {
		for file, i in ignored {
			if i > 3 do break
			fmt.printf("Unckecked: %s because: %s\n", file.path, file.reason)
		}
	}

	fmt.printfln("Num ignored: %d", len(ignored))
}

calculate_dir_size :: proc(path: string) -> i64 {
	size: i64

	w := os.walker_create(path)
	defer os.walker_destroy(&w)

	for info in os.walker_walk(&w) {
		// @TODO(spiros): Handle errors in walker
		if info.type == .Regular {
			size += info.size
		}
	}
	return size
}

copy_to_clipboard_linux :: proc(contents: string) {
	// Using xclip. Pipe the content into xclip -selection clipboard

	cmd := make_slice([]string, 3)
	defer delete_slice(cmd)

	cmd[0] = "sh"
	cmd[1] = "-c"
	cmd[2] = fmt.aprintf("echo -n '%s' | xclip -selection clipboard", contents)

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

format_size :: proc(size: i64) -> string {
	val := f64(size)
	units := []string{"B", "KB", "MB", "GB", "TB"}

	i := 0
	for val >= 1024 && i < len(units) - 1 {
		val /= 1024
		i += 1
	}
	return fmt.aprintf("%.2f %s", val, units[i])
}
