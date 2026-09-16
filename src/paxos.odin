package paxos

// Paxos Odin: A deterministic, bounded implementation of classic and Multi-Paxos.
//
// The library performs no I/O and owns no threads or clocks. A Node consumes
// messages and emits Effects. Persist Effects.writes before transmitting
// Effects.messages; this ordering is part of the core safety contract. After
// syncing a batch, call effects_confirm_writes_durable().

VERSION :: "0.7.0"

// Re-export core types for ergonomic package usage
Node_Id    :: NodeId
Log_Slot   :: Slot
Vote_Ballot:: Ballot

// Default consensus capacity constants
DEFAULT_MAX_MEMBERS        :: 7
DEFAULT_WINDOW_SLOTS       :: 256
import "core:mem"

// Determines bitwise value equality for arbitrary payload types without requiring == operator.
values_equal :: proc(a, b: $T) -> bool {
	var_a := a
	var_b := b
	return mem.compare_ptrs(&var_a, &var_b, size_of(T)) == 0
}

