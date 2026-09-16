package paxos

// In idiomatic Odin, small sets (up to 128 items) use the built-in bit_set type:
// e.g. bit_set[0..<MAX_MEMBERS].
// For large compile-time bounded bitsets (such as tracking slots across sliding windows),
// Bit_Set is backed by an array of Odin's native bit_set[0..<64] rather than raw integers.

WORD_BITS :: 64
Word :: bit_set[0..<WORD_BITS]

Bit_Set :: struct($N: int) {
	words: [(N + WORD_BITS - 1) / WORD_BITS]Word,
}

// Inserts an index into the set using native set union. Returns true if the element
// was freshly inserted, or false if it was already present.
bit_set_insert :: proc(bs: ^Bit_Set($N), index: int) -> bool {
	assert(index >= 0 && index < N, "Bit_Set index out of bounds")
	w := index / WORD_BITS
	b := index % WORD_BITS
	if b in bs.words[w] do return false
	bs.words[w] += {b}
	return true
}

// Returns whether the given index is present in the set using native membership testing.
bit_set_contains :: proc(bs: Bit_Set($N), index: int) -> bool {
	assert(index >= 0 && index < N, "Bit_Set index out of bounds")
	return (index % WORD_BITS) in bs.words[index / WORD_BITS]
}

// Returns the number of elements currently in the set using native card().
bit_set_count :: proc(bs: Bit_Set($N)) -> int {
	total := 0
	for w in bs.words {
		total += card(w)
	}
	return total
}

// Clears all elements from the set.
bit_set_reset :: proc(bs: ^Bit_Set($N)) {
	for &w in bs.words {
		w = {}
	}
}
