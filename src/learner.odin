package paxos

// Result of recording a certified chosen value in the learner window.
Learn_Result :: enum {
	// Value was buffered in the window; a gap below it prevents immediate release.
	Buffered,
	// Contiguous released prefix advanced past this value.
	Advanced,
	// Duplicate of an already released or buffered value.
	Duplicate,
}

// One released chosen value paired with its one-based slot.
Chosen_Value :: struct($Value: typeid) {
	slot:  Slot,
	value: Value,
}

// One slot-tagged window cell; slot zero represents an empty cell.
Learner_Cell :: struct($Value: typeid) {
	slot:  Slot,
	value: Value,
}

// Bounded non-voting learner that releases only a contiguous prefix of chosen values.
// Out-of-order decisions are buffered in a sliding ring-buffer window.
Learner :: struct($Value: typeid, $MAX_ENTRIES: int = 256) {
	configuration_id: u64,
	learned:          [MAX_ENTRIES]Learner_Cell(Value),
	released_through: Slot,
}

learner_init :: proc(
	l: ^Learner($Value, $MAX_ENTRIES),
	configuration_id: u64,
) -> Error {
	if configuration_id == 0 do return .InvalidConfigurationId
	l.configuration_id = configuration_id
	l.released_through = 0
	for i in 0..<MAX_ENTRIES {
		l.learned[i] = Learner_Cell(Value){slot = 0}
	}
	return .None
}

learner_cell_index :: proc(slot: Slot, $MAX_ENTRIES: int) -> int {
	return int((slot - 1) % Slot(MAX_ENTRIES))
}

// Records one host-certified chosen value for this configuration.
learner_learn_chosen :: proc(
	l: ^Learner($Value, $MAX_ENTRIES),
	configuration_id: u64,
	slot: Slot,
	value: Value,
) -> (Learn_Result, Error) {
	if configuration_id != l.configuration_id {
		return .Buffered, .ConfigurationMismatch
	}
	if slot == 0 do return .Buffered, .InvalidSlot

	if slot <= l.released_through {
		cell := &l.learned[learner_cell_index(slot, MAX_ENTRIES)]
		if cell.slot == slot && !values_equal(cell.value, value) {
			return .Duplicate, .ConflictingChosenValue
		}
		return .Duplicate, .None
	}

	if slot > l.released_through + Slot(MAX_ENTRIES) {
		return .Buffered, .WindowFull
	}

	idx := learner_cell_index(slot, MAX_ENTRIES)
	cell := &l.learned[idx]
	if cell.slot == slot {
		if !values_equal(cell.value, value) {
			return .Duplicate, .ConflictingChosenValue
		}
		return .Duplicate, .None
	}

	cell^ = Learner_Cell(Value){slot = slot, value = value}
	before := l.released_through

	// Advance contiguous prefix
	for {
		next := l.released_through + 1
		next_idx := learner_cell_index(next, MAX_ENTRIES)
		if l.learned[next_idx].slot != next do break
		l.released_through = next
	}

	if l.released_through > before {
		return .Advanced, .None
	}
	return .Buffered, .None
}

// Copies the contiguous chosen suffix starting at from_slot into caller output buffer.
learner_read_chosen :: proc(
	l: ^Learner($Value, $MAX_ENTRIES),
	from_slot: Slot,
	output: []Chosen_Value(Value),
) -> (int, Error) {
	if from_slot == 0 do return 0, .InvalidSlot
	if from_slot > l.released_through do return 0, .None

	if from_slot + Slot(MAX_ENTRIES) <= l.released_through {
		return 0, .Trimmed
	}

	count := int(l.released_through - from_slot + 1)
	if len(output) < count do return 0, .ReadBufferTooSmall

	for i in 0..<count {
		slot := from_slot + Slot(i)
		cell := &l.learned[learner_cell_index(slot, MAX_ENTRIES)]
		if cell.slot != slot do return 0, .Trimmed
		output[i] = Chosen_Value(Value){slot = slot, value = cell.value}
	}
	return count, .None
}

// Returns a released chosen value still resident in the window.
learner_chosen_at :: proc(
	l: ^Learner($Value, $MAX_ENTRIES),
	slot: Slot,
) -> (Value, bool) {
	if slot == 0 || slot > l.released_through do return Value{}, false
	cell := &l.learned[learner_cell_index(slot, MAX_ENTRIES)]
	if cell.slot != slot do return Value{}, false
	return cell.value, true
}
