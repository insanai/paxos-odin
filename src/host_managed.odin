package paxos

// The host_managed namespace provides node instances where the runtime durability gate
// is bypassed (Durability_Gate.Host_Managed).
//
// WARNING: Bypassing the runtime gate requires the host to guarantee by construction
// that all writes in an Effect batch are made durable before any messages are sent to peers.
// Failure to adhere to this contract can lead to consensus agreement violations under crashes.

Host_Managed_Node :: struct(
	$Value: typeid,
	$MAX_MEMBERS: int = 7,
	$WINDOW_SLOTS: int = 256,
	$CHUNK_SLOTS: int = 64,
) {
	using node: Node(Value, MAX_MEMBERS, WINDOW_SLOTS, CHUNK_SLOTS, .Host_Managed),
}

host_managed_node_init :: proc(
	node: ^Host_Managed_Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS),
	id: NodeId,
	membership: Membership(MAX_MEMBERS),
	priority: u32 = 0,
) -> Error {
	return node_init_with_priority(&node.node, id, membership, priority)
}
