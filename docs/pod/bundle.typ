// Paxos Odin Discussions (POD) Combined Bundle
// Compiles all registered POD records into a single consolidated reference.

#import "../shared/pod.typ": pod-index-page
#import "registry.typ": pod-documents

#pod-index-page(pod-documents)

#pagebreak()
#include "records/0001-pod-process.typ"

#pagebreak()
#include "records/0002-paxos-odin-architecture.typ"

#pagebreak()
#include "records/0003-durability-and-trimming.typ"

#pagebreak()
#include "records/0004-fast-path-leases.typ"
