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

#pagebreak()
#include "records/0005-idiomatic-odin-api-surface.typ"

#pagebreak()
#include "records/0006-reconfiguration-and-epoch-isolation.typ"

#pagebreak()
#include "records/0007-review-findings-and-verification-evidence.typ"

#pagebreak()
#include "records/0008-safety-argument.typ"

#pagebreak()
#include "records/0009-data-oriented-ledger.typ"

#pagebreak()
#include "records/0010-rotating-slot-ownership.typ"

#pagebreak()
#include "records/0011-paxodin-python-sdk.typ"
