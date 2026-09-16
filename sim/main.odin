package paxos_sim

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

main :: proc() {
	cfg := Config{
		seed       = 12345,
		steps      = 512,
		node_count = 3,
		faults     = default_faults(),
		verbose    = false,
	}

	for arg in os.args[1:] {
		if strings.has_prefix(arg, "--seed=") {
			val_str := strings.trim_prefix(arg, "--seed=")
			if val, ok := strconv.parse_u64(val_str); ok {
				cfg.seed = val
			}
		} else if strings.has_prefix(arg, "--steps=") {
			val_str := strings.trim_prefix(arg, "--steps=")
			if val, ok := strconv.parse_int(val_str); ok {
				cfg.steps = val
			}
		} else if strings.has_prefix(arg, "--nodes=") {
			val_str := strings.trim_prefix(arg, "--nodes=")
			if val, ok := strconv.parse_int(val_str); ok {
				if val >= 1 && val <= MAX_SIM_NODES {
					cfg.node_count = val
				}
			}
		} else if arg == "--ownership" {
			cfg.ownership = true
		} else if arg == "--verbose" || arg == "-v" {
			cfg.verbose = true
		} else if arg == "--help" || arg == "-h" {
			fmt.println("Usage: paxos-sim [--seed=N] [--steps=N] [--nodes=N] [--ownership] [--verbose]")
			return
		}
	}

	sim := new(Simulator)
	defer free(sim)
	sim_init(sim, cfg)
	sim_run(sim)
}
