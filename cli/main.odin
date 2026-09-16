package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:c/libc"
import "core:time"
import "core:strconv"

RECORDS_DIR   :: "docs/pod/records"
REGISTRY_PATH :: "docs/pod/registry.typ"
BUNDLE_PATH   :: "docs/pod/bundle.typ"
TEMPLATE_PATH :: "docs/pod/template/rfc-template.typ"
BUILD_DIR     :: "docs/build"
BOOK_PATH     :: "docs/book.typ"
INDEX_PATH    :: "docs/pod/index.typ"
BENCH_BUILD   :: "odin build bench -out:bin/paxos-bench -o:speed -no-bounds-check -microarch:native"

run_system_cmd :: proc(cmd: string) -> int {
	c_cmd := strings.clone_to_cstring(cmd)
	defer delete(c_cmd)
	status := int(libc.system(c_cmd))
	if status != 0 {
		fmt.eprintln(
			"-- COMMAND FAILED --\n\nThe requested tool did not complete successfully.\n" +
			"Hint: Fix the diagnostic printed above, then rerun the command:",
			cmd,
		)
		os.exit(1)
	}
	return 0
}

print_usage :: proc() {
	fmt.println("Paxos-Odin Toolchain CLI")
	fmt.println("Usage: paxos-cli <command> [arguments]")
	fmt.println("")
	fmt.println("Commands:")
	fmt.println("  build [all|lib|test|sim|bench|cli]  Build library, binaries, or test runner")
	fmt.println("  test                                Run full test suite with odin test")
	fmt.println("  sim [--seed=N] [--steps=N] ...      Run deterministic Paxos chaos simulator")
	fmt.println("  bench [--iterations=N] [--durable]  Run the benchmark (--json for machine output)")
	fmt.println("  check [--seeds=N] [--steps=N]       Run the verification suite (tools/check.py)")
	fmt.println("  example                             Run the three-node replicated counter example")
	fmt.println("  docs [all|book|index|pod|releases|html]  Compile Typst documents (html: export)")
	fmt.println("  pod list                            List registered POD records and active drafts")
	fmt.println("  pod new <slug>                      Create docs/pod/records/XXXXX-<slug>.typ")
	fmt.println("  pod promote <slug>                  Assign the next number and register the POD")
	fmt.println("  help                                Display this help text")
}

// -------------------------------------------------------------
// Build Command
// -------------------------------------------------------------

cmd_build :: proc(args: []string) {
	target := "all"
	if len(args) > 0 {
		target = args[0]
	}

	_ = os.make_directory("bin")

	switch target {
	case "lib":
		fmt.println("Building Paxos library object (bin/paxos.o)...")
		res := run_system_cmd("odin build src -build-mode:obj -out:bin/paxos.o")
		if res == 0 do fmt.println("Built bin/paxos.o successfully.")

	case "test":
		fmt.println("Building test runner (bin/paxos-test)...")
		res := run_system_cmd("odin build tests -build-mode:test -out:bin/paxos-test")
		if res == 0 do fmt.println("Built bin/paxos-test successfully.")

	case "sim":
		fmt.println("Building simulator (bin/paxos-sim)...")
		res := run_system_cmd("odin build sim -out:bin/paxos-sim")
		if res == 0 do fmt.println("Built bin/paxos-sim successfully.")

	case "bench":
		fmt.println("Building benchmark (bin/paxos-bench)...")
		res := run_system_cmd(BENCH_BUILD)
		if res == 0 do fmt.println("Built bin/paxos-bench successfully.")

	case "cli":
		fmt.println("Building CLI (bin/paxos-cli)...")
		res := run_system_cmd("odin build cli -out:bin/paxos-cli")
		if res == 0 do fmt.println("Built bin/paxos-cli successfully.")

	case "all":
		fmt.println("Building all targets into bin/...")
		_ = run_system_cmd("odin build src -build-mode:obj -out:bin/paxos.o")
		_ = run_system_cmd("odin build sim -out:bin/paxos-sim")
		_ = run_system_cmd(BENCH_BUILD)
		_ = run_system_cmd("odin build cli -out:bin/paxos-cli")
		fmt.println("All targets built in bin/")

	case:
		fmt.printf("Unknown build target: %s\n", target)
		fmt.println("Valid targets: all, lib, test, sim, bench, cli")
	}
}

// -------------------------------------------------------------
// Test, Sim, Bench Commands
// -------------------------------------------------------------

cmd_test :: proc() {
	fmt.println("Running Paxos-Odin test suite...")
	_ = run_system_cmd("odin test tests")
}

cmd_sim :: proc(args: []string) {
	cmd_buf := strings.builder_make()
	defer strings.builder_destroy(&cmd_buf)

	strings.write_string(&cmd_buf, "odin run sim --")
	for arg in args {
		strings.write_string(&cmd_buf, " ")
		strings.write_string(&cmd_buf, arg)
	}
	_ = run_system_cmd(strings.to_string(cmd_buf))
}

cmd_bench :: proc(args: []string) {
	cmd_buf := strings.builder_make()
	defer strings.builder_destroy(&cmd_buf)

	strings.write_string(&cmd_buf, "odin run bench -o:speed -no-bounds-check -microarch:native --")
	for arg in args {
		strings.write_string(&cmd_buf, " ")
		strings.write_string(&cmd_buf, arg)
	}
	_ = run_system_cmd(strings.to_string(cmd_buf))
}

cmd_check :: proc(args: []string) {
	cmd_buf := strings.builder_make()
	defer strings.builder_destroy(&cmd_buf)

	strings.write_string(&cmd_buf, "python3 tools/check.py")
	for arg in args {
		strings.write_string(&cmd_buf, " ")
		strings.write_string(&cmd_buf, arg)
	}
	_ = run_system_cmd(strings.to_string(cmd_buf))
}

// -------------------------------------------------------------
// Docs Generation Command (Typst Pipeline)
// -------------------------------------------------------------

cmd_docs :: proc(args: []string) {
	_ = os.make_directory(BUILD_DIR)

	target := "all"
	if len(args) > 0 {
		target = args[0]
	}

	root_dir := get_repo_root()

	if target == "book" || target == "all" {
		fmt.println("Compiling Paxos-Odin Book (docs/build/paxos-spec.pdf)...")
		cmd := fmt.tprintf("typst compile --root %s %s %s/paxos-spec.pdf", root_dir, BOOK_PATH, BUILD_DIR)
		if run_system_cmd(cmd) == 0 {
			fmt.println("  Generated docs/build/paxos-spec.pdf")
		}
	}

	if target == "index" || target == "all" {
		fmt.println("Compiling POD Index (docs/build/pod-index.pdf)...")
		cmd := fmt.tprintf("typst compile --root %s %s %s/pod-index.pdf", root_dir, INDEX_PATH, BUILD_DIR)
		if run_system_cmd(cmd) == 0 {
			fmt.println("  Generated docs/build/pod-index.pdf")
		}
	}

	if target == "pod" || target == "all" {
		fmt.println("Compiling registered POD records...")
		compile_all_pod_records(root_dir)
	} else if strings.has_prefix(target, "pod-") || strings.has_prefix(target, "0") {
		compile_matching_pod(root_dir, target)
	}

	if target == "releases" || target == "all" {
		compile_release_notes(root_dir)
	}

	if target == "html" || target == "all" {
		compile_html(root_dir)
	}
}

RELEASES_DIR :: "docs/releases"

compile_release_notes :: proc(root_dir: string) {
	fd, err := os.open(RELEASES_DIR)
	if err != nil do return
	defer os.close(fd)
	entries, read_err := os.read_dir(fd, -1, context.allocator)
	if read_err != nil do return
	defer os.file_info_slice_delete(entries, context.allocator)
	for entry in entries {
		if !strings.has_suffix(entry.name, ".typ") do continue
		stem := strings.trim_suffix(entry.name, ".typ")
		cmd := fmt.tprintf("typst compile --root %s %s/%s %s/release-%s.pdf",
			root_dir, RELEASES_DIR, entry.name, BUILD_DIR, stem)
		if run_system_cmd(cmd) == 0 do fmt.printf("  Generated docs/build/release-%s.pdf\n", stem)
	}
}

// Typst's HTML export is experimental (no page layout, no CeTZ figures); it is offered
// for web publishing next to the authoritative PDFs.
compile_html :: proc(root_dir: string) {
	html_dir := fmt.tprintf("%s/html", BUILD_DIR)
	_ = os.make_directory(html_dir)
	fmt.println("Exporting HTML (experimental Typst feature) into docs/build/html/...")
	targets := [?][2]string{{BOOK_PATH, "paxos-spec.html"}, {INDEX_PATH, "pod-index.html"}}
	for target in targets {
		cmd := fmt.tprintf("typst compile --root %s --features html --format html %s %s/%s",
			root_dir, target[0], html_dir, target[1])
		if run_system_cmd(cmd) == 0 do fmt.printf("  Generated docs/build/html/%s\n", target[1])
	}
	fd, err := os.open(RECORDS_DIR)
	if err != nil do return
	defer os.close(fd)
	entries, read_err := os.read_dir(fd, -1, context.allocator)
	if read_err != nil do return
	defer os.file_info_slice_delete(entries, context.allocator)
	for entry in entries {
		if !strings.has_suffix(entry.name, ".typ") || strings.has_prefix(entry.name, "XXXXX-") do continue
		stem := strings.trim_suffix(entry.name, ".typ")
		cmd := fmt.tprintf("typst compile --root %s --features html --format html %s/%s %s/pod-%s.html",
			root_dir, RECORDS_DIR, entry.name, html_dir, stem)
		if run_system_cmd(cmd) == 0 do fmt.printf("  Generated docs/build/html/pod-%s.html\n", stem)
	}
}

compile_all_pod_records :: proc(root_dir: string) {
	fd, err := os.open(RECORDS_DIR)
	if err != nil do return
	defer os.close(fd)

	entries, read_err := os.read_dir(fd, -1, context.allocator)
	if read_err != nil do return
	defer os.file_info_slice_delete(entries, context.allocator)

	for entry in entries {
		if strings.has_suffix(entry.name, ".typ") && !strings.has_prefix(entry.name, "XXXXX-") {
			stem := strings.trim_suffix(entry.name, ".typ")
			src := fmt.tprintf("%s/%s", RECORDS_DIR, entry.name)
			dst := fmt.tprintf("%s/pod-%s.pdf", BUILD_DIR, stem)
			cmd := fmt.tprintf("typst compile --root %s %s %s", root_dir, src, dst)
			if run_system_cmd(cmd) == 0 {
				fmt.printf("  Generated docs/build/pod-%s.pdf\n", stem)
			}
		}
	}
}

compile_matching_pod :: proc(root_dir, pattern: string) {
	clean_pat := strings.trim_prefix(pattern, "pod-")

	fd, err := os.open(RECORDS_DIR)
	if err != nil do return
	defer os.close(fd)

	entries, read_err := os.read_dir(fd, -1, context.allocator)
	if read_err != nil do return
	defer os.file_info_slice_delete(entries, context.allocator)

	found := false
	for entry in entries {
		if strings.has_suffix(entry.name, ".typ") {
			stem := strings.trim_suffix(entry.name, ".typ")
			if strings.contains(stem, clean_pat) {
				found = true
				src := fmt.tprintf("%s/%s", RECORDS_DIR, entry.name)
				dst := fmt.tprintf("%s/pod-%s.pdf", BUILD_DIR, stem)
				fmt.printf("Compiling %s -> %s\n", src, dst)
				cmd := fmt.tprintf("typst compile --root %s %s %s", root_dir, src, dst)
				if run_system_cmd(cmd) == 0 {
					fmt.printf("  Generated %s\n", dst)
				}
			}
		}
	}
	if !found {
		fmt.printf("No POD record matching '%s' found in %s\n", pattern, RECORDS_DIR)
	}
}

// -------------------------------------------------------------
// POD Management: list, new, promote
// -------------------------------------------------------------

cmd_pod :: proc(args: []string) {
	if len(args) == 0 {
		fmt.println("Usage: paxos-cli pod [list|new <slug>|promote <slug>]")
		return
	}

	sub := args[0]
	switch sub {
	case "list":
		pod_list()
	case "new":
		if len(args) < 2 {
			fmt.println("Error: slug required (e.g. paxos-cli pod new leader-leases)")
			return
		}
		pod_new(args[1])
	case "promote":
		if len(args) < 2 {
			fmt.println("Error: slug required (e.g. paxos-cli pod promote leader-leases)")
			return
		}
		pod_promote(args[1])
	case:
		fmt.printf("Unknown pod subcommand: %s\n", sub)
		fmt.println("Usage: paxos-cli pod [list|new <slug>|promote <slug>]")
	}
}

pod_list :: proc() {
	fmt.println("================================================================================")
	fmt.println("  PAXOS ODIN DISCUSSIONS (POD) REGISTRY & DRAFTS")
	fmt.println("================================================================================")
	fmt.printf("%-8s %-12s %-32s %-20s\n", "POD", "State", "Title", "File")
	fmt.println("--------------------------------------------------------------------------------")

	fd, err := os.open(RECORDS_DIR)
	if err != nil {
		fmt.println("No records directory found.")
		return
	}
	defer os.close(fd)

	entries, read_err := os.read_dir(fd, -1, context.allocator)
	if read_err != nil do return
	defer os.file_info_slice_delete(entries, context.allocator)

	for entry in entries {
		if strings.has_suffix(entry.name, ".typ") {
			file_path := fmt.tprintf("%s/%s", RECORDS_DIR, entry.name)
			content, read_f_err := os.read_entire_file(file_path, context.allocator)
			if read_f_err == nil {
				defer delete(content, context.allocator)
				s := string(content)
				num := extract_meta(s, "number", entry.name[:4])
				state := extract_meta(s, "state", "draft")
				title := extract_meta(s, "title", "Untitled")

				fmt.printf("%-8s %-12s %-32s %-20s\n", num, state, truncate_str(title, 32), entry.name)
			}
		}
	}
	fmt.println("================================================================================")
}

pod_new :: proc(slug: string) {
	if !validate_slug(slug) {
		fmt.println("Error: Invalid slug. Use lowercase letters, digits, and hyphens (fast-path-commit).")
		return
	}

	target_path := fmt.tprintf("%s/XXXXX-%s.typ", RECORDS_DIR, slug)
	if os.exists(target_path) {
		fmt.printf("Error: Draft %s already exists!\n", target_path)
		return
	}

	tpl_bytes, err := os.read_entire_file(TEMPLATE_PATH, context.allocator)
	if err != nil {
		fmt.printf("Error: Could not read template file %s\n", TEMPLATE_PATH)
		return
	}
	defer delete(tpl_bytes, context.allocator)

	now := time.now()
	y, m, d := time.date(now)
	today_str := fmt.tprintf("%04d-%02d-%02d", y, m, d)

	tpl_str := string(tpl_bytes)
	updated, _ := strings.replace_all(tpl_str, "YYYY-MM-DD", today_str)
	defer delete(updated)

	write_err := os.write_entire_file(target_path, transmute([]u8)updated)
	if write_err != nil {
		fmt.printf("Error: Failed to write draft to %s\n", target_path)
		return
	}

	fmt.println("================================================================================")
	fmt.printf("Created new placeholder draft: %s\n", target_path)
	fmt.println("Edit the draft's title, summary, and design details.")
	fmt.printf("When ready for discussion, promote it with: paxos-cli pod promote %s\n", slug)
	fmt.println("================================================================================")
}

pod_promote :: proc(slug: string) {
	draft_name := fmt.tprintf("XXXXX-%s.typ", slug)
	draft_path := fmt.tprintf("%s/%s", RECORDS_DIR, draft_name)

	if !os.exists(draft_path) {
		fmt.printf("Error: Placeholder draft %s does not exist.\n", draft_path)
		return
	}

	// Determine next sequence number
	next_num := get_next_pod_number()
	num_str := fmt.tprintf("%04d", next_num)
	new_filename := fmt.tprintf("%s-%s.typ", num_str, slug)
	new_path := fmt.tprintf("%s/%s", RECORDS_DIR, new_filename)

	draft_bytes, err := os.read_entire_file(draft_path, context.allocator)
	if err != nil {
		fmt.println("Error reading draft file.")
		return
	}
	defer delete(draft_bytes, context.allocator)

	now := time.now()
	y, m, d := time.date(now)
	today_str := fmt.tprintf("%04d-%02d-%02d", y, m, d)

	content := string(draft_bytes)
	content = replace_meta_val(content, "number", num_str)
	content = replace_meta_val(content, "state", "discussion")
	content = replace_meta_val(content, "status", "Open for Discussion")
	content = replace_meta_val(content, "last-updated", today_str)

	title := extract_meta(content, "title", "Untitled")
	category := extract_meta(content, "category", "Engineering Discussion")
	summary := extract_meta(content, "discussion", "")

	// Write new record file
	if write_err := os.write_entire_file(new_path, transmute([]u8)content); write_err != nil {
		fmt.printf("Error writing promoted record %s\n", new_path)
		return
	}
	_ = os.remove(draft_path)

	// Append to registry.typ
	append_to_registry(num_str, slug, title, category, summary, today_str)

	// Append to bundle.typ
	append_to_bundle(num_str, slug)

	fmt.println("================================================================================")
	fmt.printf("Promoted %s -> %s\n", draft_name, new_filename)
	fmt.printf("Registered POD %s in %s and %s\n", num_str, REGISTRY_PATH, BUNDLE_PATH)
	fmt.printf("Compile PDF with: paxos-cli docs pod-%s\n", num_str)
	fmt.println("================================================================================")
}

// -------------------------------------------------------------
// Internal Helpers
// -------------------------------------------------------------

get_repo_root :: proc() -> string {
	cwd, _ := os.get_working_directory(context.allocator)
	return cwd
}

validate_slug :: proc(slug: string) -> bool {
	if len(slug) == 0 do return false
	if slug[0] == '-' || slug[len(slug) - 1] == '-' do return false
	for ch in slug {
		is_lower := ch >= 'a' && ch <= 'z'
		is_digit := ch >= '0' && ch <= '9'
		is_hyphen := ch == '-'
		if !is_lower && !is_digit && !is_hyphen do return false
	}
	return true
}

extract_meta :: proc(src: string, key: string, fallback: string) -> string {
	pattern := fmt.tprintf("#let pod-%s = \"", key)
	idx := strings.index(src, pattern)
	if idx < 0 do return fallback
	start := idx + len(pattern)
	rest := src[start:]
	end := strings.index(rest, "\"")
	if end < 0 do return fallback
	return rest[:end]
}

replace_meta_val :: proc(src: string, key: string, val: string) -> string {
	pattern := fmt.tprintf("#let pod-%s = \"", key)
	idx := strings.index(src, pattern)
	if idx < 0 do return src
	start := idx + len(pattern)
	rest := src[start:]
	end := strings.index(rest, "\"")
	if end < 0 do return src

	buf := strings.builder_make()
	strings.write_string(&buf, src[:start])
	strings.write_string(&buf, val)
	strings.write_string(&buf, rest[end:])
	return strings.to_string(buf)
}

get_next_pod_number :: proc() -> int {
	fd, err := os.open(RECORDS_DIR)
	if err != nil do return 1
	defer os.close(fd)

	entries, read_err := os.read_dir(fd, -1, context.allocator)
	if read_err != nil do return 1
	defer os.file_info_slice_delete(entries, context.allocator)

	max_num := 0
	for entry in entries {
		if strings.has_suffix(entry.name, ".typ") && len(entry.name) >= 4 {
			num_part := entry.name[:4]
			if val, ok := strconv.parse_int(num_part); ok {
				if val > max_num do max_num = val
			}
		}
	}
	return max_num + 1
}

append_to_registry :: proc(num_str, slug, title, category, summary, date: string) {
	reg_bytes, err := os.read_entire_file(REGISTRY_PATH, context.allocator)
	if err != nil do return
	defer delete(reg_bytes, context.allocator)

	reg_str := string(reg_bytes)
	close_idx := strings.last_index(reg_str, "\n)")
	if close_idx < 0 do return

	entry := fmt.tprintf(`  (
    number: "%s",
    slug: "%s",
    title: "%s",
    state: "discussion",
    area: "engineering",
    category: "%s",
    status: "Open for Discussion",
    created: "%s",
    updated: "%s",
    summary: "%s",
    source: "docs/pod/records/%s-%s.typ",
    pdf: "pod-%s-%s.pdf",
  ),
`, num_str, slug, title, category, date, date, summary, num_str, slug, num_str, slug)

	buf := strings.builder_make()
	strings.write_string(&buf, reg_str[:close_idx + 1])
	strings.write_string(&buf, entry)
	strings.write_string(&buf, reg_str[close_idx + 1:])
	_ = os.write_entire_file(REGISTRY_PATH, transmute([]u8)strings.to_string(buf))
}

append_to_bundle :: proc(num_str, slug: string) {
	entry := fmt.tprintf(`
#pagebreak()
#include "records/%s-%s.typ"
`, num_str, slug)

	f, err := os.open(BUNDLE_PATH, os.File_Flags{.Write, .Append})
	if err != nil do return
	defer os.close(f)
	_, _ = os.write_string(f, entry)
}

truncate_str :: proc(s: string, max_len: int) -> string {
	if len(s) <= max_len do return s
	return s[:max_len]
}

main :: proc() {
	if len(os.args) < 2 {
		print_usage()
		return
	}

	cmd := os.args[1]
	args := os.args[2:]

	switch cmd {
	case "build":
		cmd_build(args)
	case "test":
		cmd_test()
	case "sim":
		cmd_sim(args)
	case "bench":
		cmd_bench(args)
	case "check":
		cmd_check(args)
	case "example":
		_ = run_system_cmd("odin run examples/counter.odin -file")
	case "docs":
		cmd_docs(args)
	case "pod":
		cmd_pod(args)
	case "help", "--help", "-h":
		print_usage()
	case:
		fmt.printf("Unknown command: %s\n\n", cmd)
		print_usage()
	}
}
