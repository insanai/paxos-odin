package paxos_tests

import "core:testing"
import paxos "../src"

@(test)
test_bit_set_basic :: proc(t: ^testing.T) {
	bs: paxos.Bit_Set(64)
	testing.expect(t, paxos.bit_set_count(bs) == 0, "Initial count must be zero")

	testing.expect(t, paxos.bit_set_insert(&bs, 0), "Insert 0 should succeed")
	testing.expect(t, paxos.bit_set_insert(&bs, 6), "Insert 6 should succeed")
	testing.expect(t, !paxos.bit_set_insert(&bs, 0), "Duplicate insert 0 should return false")

	testing.expect(t, paxos.bit_set_contains(bs, 0), "Set should contain 0")
	testing.expect(t, paxos.bit_set_contains(bs, 6), "Set should contain 6")
	testing.expect(t, !paxos.bit_set_contains(bs, 1), "Set should not contain 1")

	testing.expect(t, paxos.bit_set_count(bs) == 2, "Count should be 2")

	paxos.bit_set_reset(&bs)
	testing.expect(t, paxos.bit_set_count(bs) == 0, "Count after reset should be 0")
	testing.expect(t, !paxos.bit_set_contains(bs, 0), "Set should not contain 0 after reset")
}

@(test)
test_bit_set_large :: proc(t: ^testing.T) {
	bs: paxos.Bit_Set(256)
	testing.expect(t, paxos.bit_set_insert(&bs, 64), "Insert 64 should succeed")
	testing.expect(t, paxos.bit_set_insert(&bs, 128), "Insert 128 should succeed")
	testing.expect(t, paxos.bit_set_insert(&bs, 255), "Insert 255 should succeed")
	testing.expect(t, paxos.bit_set_count(bs) == 3, "Count should be 3")

	testing.expect(t, paxos.bit_set_contains(bs, 64), "Contains 64")
	testing.expect(t, paxos.bit_set_contains(bs, 128), "Contains 128")
	testing.expect(t, paxos.bit_set_contains(bs, 255), "Contains 255")
	testing.expect(t, !paxos.bit_set_contains(bs, 65), "Does not contain 65")
}

@(test)
test_native_bit_set :: proc(t: ^testing.T) {
	members: bit_set[0..<7]
	testing.expect(t, card(members) == 0, "Initial card should be 0")
	members += {0, 3, 6}
	testing.expect(t, card(members) == 3, "Card should be 3")
	testing.expect(t, 3 in members, "3 should be in members")
	testing.expect(t, !(1 in members), "1 should not be in members")
	members -= {3}
	testing.expect(t, card(members) == 2, "Card should be 2 after removal")
	testing.expect(t, !(3 in members), "3 should no longer be in members")
}
