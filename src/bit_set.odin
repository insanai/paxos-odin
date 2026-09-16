package paxos

import "core:math/bits"

// A fixed-capacity set whose storage is optimized for size and performance.
// Uses an array of 64-bit words to represent up to N bits without heap allocation.
Bit_Set :: struct($N: int) {
	words: [(N + 63) / 64]u64,
}

// Inserts an index into the set. Returns true if the element was freshly inserted,
// or false if it was already present.
bit_set_insert :: proc(bs: ^Bit_Set($N), index: int) -> bool {
	assert(index >= 0 && index < N, "Bit_Set index out of bounds")
	word_idx := index / 64
	bit_idx := uint(index % 64)
	mask := u64(1) << bit_idx
	if (bs.words[word_idx] & mask) != 0 {
		return false
	}
	bs.words[word_idx] |= mask
	return true
}

// Returns whether the given index is present in the set.
bit_set_contains :: proc(bs: Bit_Set($N), index: int) -> bool {
	assert(index >= 0 && index < N, "Bit_Set index out of bounds")
	word_idx := index / 64
	bit_idx := uint(index % 64)
	mask := u64(1) << bit_idx
	return (bs.words[word_idx] & mask) != 0
}

// Returns the number of elements currently in the set.
bit_set_count :: proc(bs: Bit_Set($N)) -> int {
	total := 0
	for w in bs.words {
		total += int(bits.count_ones(w))
	}
	return total
}

// Clears all elements from the set.
bit_set_reset :: proc(bs: ^Bit_Set($N)) {
	for i in 0..<len(bs.words) {
		bs.words[i] = 0
	}
}
