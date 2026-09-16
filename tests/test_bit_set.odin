package paxos_tests

import "core:testing"
import paxos "../src"

@(test)
test_bit_set_basic :: proc(t: ^testing.T) {
	bs: paxos.Bit_Set(64)
	testing.expect_value(t, paxos.bit_set_count(bs), 0)
	testing.expect(t, paxos.bit_set_insert(&bs, 0))
	testing.expect(t, paxos.bit_set_insert(&bs, 6))
	testing.expect(t, !paxos.bit_set_insert(&bs, 0), "a duplicate insert reports false")
	testing.expect(t, paxos.bit_set_contains(bs, 0) && paxos.bit_set_contains(bs, 6))
	testing.expect(t, !paxos.bit_set_contains(bs, 1))
	testing.expect_value(t, paxos.bit_set_count(bs), 2)
	paxos.bit_set_remove(&bs, 0)
	testing.expect(t, !paxos.bit_set_contains(bs, 0))
	paxos.bit_set_reset(&bs)
	testing.expect_value(t, paxos.bit_set_count(bs), 0)
}

@(test)
test_bit_set_scans_across_words :: proc(t: ^testing.T) {
	bs: paxos.Bit_Set(256)
	for index in ([?]int{3, 64, 128, 255}) do paxos.bit_set_insert(&bs, index)
	testing.expect_value(t, paxos.bit_set_count(bs), 4)
	expected := [?]int{3, 64, 128, 255}
	index, more := paxos.bit_set_next(bs, 0)
	for want in expected {
		testing.expect(t, more && index == want)
		index, more = paxos.bit_set_next(bs, index + 1)
	}
	testing.expect(t, !more, "the scan ends after the last member")
	last, any := paxos.bit_set_last(bs)
	testing.expect(t, any && last == 255)
	empty: paxos.Bit_Set(8)
	_, has := paxos.bit_set_next(empty, 0)
	testing.expect(t, !has)
	_, has_last := paxos.bit_set_last(empty)
	testing.expect(t, !has_last)
}

@(test)
test_native_bit_set :: proc(t: ^testing.T) {
	members: bit_set[0..<7]
	members += {0, 3, 6}
	testing.expect_value(t, card(members), 3)
	testing.expect(t, 3 in members && !(1 in members))
	members -= {3}
	testing.expect_value(t, card(members), 2)
}
