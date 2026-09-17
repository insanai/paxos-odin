// Run: odin run tools/memory_report.odin -file
// Static bytes only: Node includes its Ledger. Effects is additional caller storage;
// transport queues, codecs, journals, allocator overhead and application state are excluded.
package memory_report

import "core:fmt"
import paxos "../src"

report :: proc($V: typeid, $M, $W, $C: int) {
	fmt.printf("%d,%d,%d,%d,%d,%d,%d,%d\n",
		size_of(V), M, W, C,
		size_of(paxos.Node(V, M, W, C)),
		size_of(paxos.Ledger(V, W)),
		size_of(paxos.Effects(V, M, W, C)),
		size_of(paxos.Node(V, M, W, C)) + size_of(paxos.Effects(V, M, W, C)))
}

main :: proc() {
	fmt.println("payload_bytes,members,window,chunk,node_bytes,ledger_bytes,effects_bytes,total_bytes")
	report(u64, 3, 256, 64)
	report([128]u64, 3, 256, 64)
	report(u64, 5, 256, 64)
	report([128]u64, 5, 256, 64)
	// Equal chunk/window is the no-reduction compatibility boundary.
	report(u64, 3, 256, 256)
	report([128]u64, 3, 256, 256)
	report(u64, 3, 4096, 256)
	report([128]u64, 3, 4096, 256)
}
