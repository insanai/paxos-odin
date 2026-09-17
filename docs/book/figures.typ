#import "@preview/fletcher:0.5.8" as fletcher: diagram, node, edge
#import "@preview/cetz:0.5.2" as cetz
#import "theme.typ": blue, blue_light, green, green_light, amber, amber_light, red, gray, rule

#let node_style = (
  fill: blue_light,
  stroke: 0.8pt + blue,
  corner-radius: 3pt,
  inset: 7pt,
)

#let quorum_picture() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  circle((0, 0), radius: 1.55, fill: blue_light, stroke: blue)
  circle((2.0, 0), radius: 1.55, fill: green_light, stroke: green)
  content((-0.7, 0), text(weight: "bold")[Quorum A])
  content((2.7, 0), text(weight: "bold")[Quorum B])
  content((1.0, 0), text(size: 8pt, weight: "bold")[A ∩ B ≠ ∅])
})

#let phase_flow() = diagram(
  spacing: (34mm, 18mm),
  node-stroke: 0.8pt + blue,
  edge-stroke: 0.8pt + gray,
  node((0, 0), [Candidate], ..node_style),
  node((1, 0), [Phase 1a #linebreak() `Prepare`], ..node_style),
  node((2, 0), [Quorum #linebreak() `Promise`], ..node_style),
  node((2, 1), [Phase 2a #linebreak() `Accept`], ..node_style),
  node((1, 1), [Quorum #linebreak() `Accepted`], ..node_style),
  node((0, 1), [Leader learns #linebreak() value is chosen], fill: green_light, stroke: 0.8pt + green,
    corner-radius: 3pt, inset: 7pt),
  edge((0, 0), (1, 0), "-|>"),
  edge((1, 0), (2, 0), "-|>"),
  edge((2, 0), (2, 1), "-|>"),
  edge((2, 1), (1, 1), "-|>"),
  edge((1, 1), (0, 1), "-|>"),
)

#let effects_flow() = diagram(
  spacing: (24mm, 15mm),
  node-stroke: 0.8pt + blue,
  edge-stroke: 0.9pt + gray,
  node((0, 0), [`node_step(event)`], ..node_style),
  node((1, -1), [`writes`], fill: green_light, stroke: 0.8pt + green,
    corner-radius: 3pt, inset: 7pt),
  node((1, 0), [`messages`], fill: blue_light, stroke: 0.8pt + blue,
    corner-radius: 3pt, inset: 7pt),
  node((1, 1), [`committed`], fill: rgb("fff5dc"), stroke: 0.8pt + amber,
    corner-radius: 3pt, inset: 7pt),
  node((2, -1), [Host Persists (WAL)], ..node_style),
  node((2, 0), [Host Transmits (NIC)], ..node_style),
  node((2, 1), [Host Applies (State)], ..node_style),
  edge((0, 0), (1, -1), "-|>"),
  edge((0, 0), (1, 0), "-|>"),
  edge((0, 0), (1, 1), "-|>"),
  edge((1, -1), (2, -1), "-|>", [1. fsync]),
  edge((2, -1), (2, 0), "-|>", [2. barrier], bend: 25deg),
  edge((2, -1), (2, 1), "-|>", [3. apply], bend: 38deg),
  edge((1, 0), (2, 0), "-|>"),
  edge((1, 1), (2, 1), "-|>"),
)

#let role_map() = diagram(
  spacing: (28mm, 14mm),
  node-stroke: 0.8pt + blue,
  edge-stroke: 0.9pt + gray,
  node((0, 0), [Client], ..node_style),
  node((1, 0), [Proposer / Leader], ..node_style),
  node((2, -1), [Acceptor (Voter)], ..node_style),
  node((2, 1), [Learner (Window)], fill: green_light, stroke: 0.8pt + green,
    corner-radius: 3pt, inset: 7pt),
  node((3, 0), [Application State Machine], ..node_style),
  edge((0, 0), (1, 0), "-|>", [propose]),
  edge((1, 0), (2, -1), "-|>", [ballot phase]),
  edge((2, -1), (2, 1), "-|>", [commit / learn]),
  edge((2, 1), (3, 0), "-|>", [contiguous entries]),
)

#let log_picture() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  for index in range(0, 8) {
    let x = index * 1.15
    let fill_color = if index < 5 { green_light } else if index == 6 { blue_light } else { white }
    rect((x, 0), (x + 1, 0.8), fill: fill_color, stroke: 0.7pt + gray)
    content((x + 0.5, 0.4), [#(index + 1)])
  }
  content((2.85, -0.45), text(fill: green, size: 8pt)[contiguous committed prefix (1..5)])
  content((6.25, 1.2), text(fill: blue, size: 8pt)[known but blocked by hole at 6])
  line((6.5, 1.0), (6.5, 0.82), mark: (end: ">"), stroke: blue)
})

#let tick_flow() = diagram(
  spacing: (27mm, 15mm),
  node-stroke: 0.8pt + blue,
  edge-stroke: 0.8pt + gray,
  node((0, 0), [`node_tick()`], ..node_style),
  node((1, -1), [Follower Role], ..node_style),
  node((1, 1), [Leader Role], ..node_style),
  node((2, -1), [Campaign on Timeout], fill: amber_light, stroke: 0.8pt + amber,
    corner-radius: 3pt, inset: 7pt),
  node((2, 0.5), [Periodic Heartbeat], ..node_style),
  node((2, 1.5), [Slot Resend Sweep], fill: green_light, stroke: 0.8pt + green,
    corner-radius: 3pt, inset: 7pt),
  edge((0, 0), (1, -1), "-|>"),
  edge((0, 0), (1, 1), "-|>"),
  edge((1, -1), (2, -1), "-|>"),
  edge((1, 1), (2, 0.5), "-|>"),
  edge((1, 1), (2, 1.5), "-|>"),
)

#let reconfiguration_flow() = diagram(
  spacing: (29mm, 16mm),
  node-stroke: 0.8pt + blue,
  edge-stroke: 0.8pt + gray,
  node((0, 0), [Configuration $C_1$], ..node_style),
  node((1, 0), [App Commands], ..node_style),
  node((2, 0), [Stop Sign in Slot $s$], fill: amber_light, stroke: 0.8pt + amber,
    corner-radius: 3pt, inset: 7pt),
  node((3, 0), [Configuration $C_2$ ($s+1$)], fill: green_light, stroke: 0.8pt + green,
    corner-radius: 3pt, inset: 7pt),
  edge((0, 0), (1, 0), "-|>"),
  edge((1, 0), (2, 0), "-|>"),
  edge((2, 0), (3, 0), "-|>", [sealed]),
)

// Historical harness tables retain their recorded machine and revision.
// The current matched tables below read a separate, explicitly named archive.
#let bench = json("/bench/results/latest.json")

#let bench_rows(impl, workload, mode) = bench.runs.filter(r =>
  r.impl == impl and r.workload == workload and r.mode == mode)

#let bench_ns(impl, workload, mode) = {
  let rows = bench_rows(impl, workload, mode)
  if rows.len() == 0 { none } else { rows.at(0).ns_per_value }
}

#let fmt_ns(v) = {
  if v == none { [--] }
  else if v >= 1e6 { [#calc.round(v / 1e6, digits: 2) ms] }
  else if v >= 1e4 { [#calc.round(v / 1e3, digits: 1) µs] }
  else { [#calc.round(v, digits: 0) ns] }
}

#let bench_host = [
  #bench.meta.cpu, #bench.meta.os · odin #bench.meta.odin, zig #bench.meta.zig,
  #bench.meta.rustc · Odin build `#bench.meta.odin_build` · recorded #bench.meta.date
]

#let bench_impls = (
  ("paxos-odin", [paxos-odin]),
  ("paxos-zig", [paxos-zig]),
  ("omnipaxos", [OmniPaxos]),
  ("libpaxos3", [LibPaxos3]),
)

// (workload, mode, LibPaxos3 mode name when it differs, label)
#let bench_cases = (
  ("u64-3n", "sync", "sync-preexec", [3 voters, 8 B, one value at a time]),
  ("u64-3n", "pipeline8", none, [3 voters, 8 B, 8 in flight]),
  ("u64-3n", "pipeline64", none, [3 voters, 8 B, 64 in flight]),
  ("u64-5n", "sync", none, [5 voters, 8 B, one value at a time]),
  ("u64-5n", "pipeline8", none, [5 voters, 8 B, 8 in flight]),
  ("blob1k-3n", "sync", none, [3 voters, 1 KiB, one value at a time]),
  ("blob1k-3n", "pipeline8", none, [3 voters, 1 KiB, 8 in flight]),
  ("owned-3n", "sync", none, [3 owners, 8 B, one value at a time, rotating ownership]),
  ("owned-3n", "pipeline8", none, [3 owners, 8 B, 8 in flight, rotating ownership]),
)

#let benchmark_comparison_table() = {
  block(width: 100%, inset: 9pt, radius: 5pt, fill: blue_light, stroke: 0.5pt + rule)[
    #text(size: 11pt, weight: "bold")[Nanoseconds per committed value, in-process transport]
    #linebreak()
    #text(size: 8pt, fill: gray)[#bench_host]
    #v(6pt)
    #table(
      columns: (1.6fr, 0.7fr, 0.7fr, 0.7fr, 0.7fr),
      align: (left, right, right, right, right),
      table.header([*Workload*], ..bench_impls.map(i => [*#i.at(1)*])),
      ..bench_cases.map(c => (
        c.at(3),
        ..bench_impls.map(i => {
          let mode = if i.at(0) == "libpaxos3" and c.at(2) != none { c.at(2) } else { c.at(1) }
          fmt_ns(bench_ns(i.at(0), c.at(0), mode))
        }),
      )).flatten(),
    )
    #v(3pt)
    #text(size: 7.5pt, fill: gray)[
      Median of repeated samples per harness. Every implementation ran on this machine in the
      same session; "--" means the harness has no such mode. LibPaxos3 runs a heavier
      phase-one pre-execution path and reports it as `sync-preexec`.
    ]
  ]
}

#let benchmark_durable_table() = {
  let rows = bench.runs.filter(r => r.mode.starts-with("durable"))
  block(width: 100%, inset: 9pt, radius: 5pt, fill: blue_light, stroke: 0.5pt + rule)[
    #text(size: 11pt, weight: "bold")[With a journal and a storage barrier]
    #linebreak()
    #text(size: 8pt, fill: gray)[#bench_host]
    #v(6pt)
    #table(
      columns: (0.8fr, 1.2fr, 1fr, 0.8fr, 0.8fr),
      align: (left, left, left, right, right),
      table.header([*Library*], [*Workload*], [*Mode*], [*Per value*], [*fsync per value*]),
      ..rows.map(r => (
        [#r.impl], [#r.workload], [#r.mode], fmt_ns(r.ns_per_value),
        if "syncs_per_value" in r { [#calc.round(r.syncs_per_value, digits: 2)] } else { [--] },
      )).flatten(),
    )
  ]
}

// Kept for chapters that only need this library's own numbers.
#let benchmark_results_table() = benchmark_comparison_table()

// Current matched data is separate from the historical durability harness.
#let matched = json("/bench/results/recovery-matched-20260917.json")
#let matched_row(impl, voters, payload, depth) = matched.runs.find(r =>
  r.impl == impl and r.nodes == voters and r.payload_bytes == payload and r.depth == depth)
#let matched_ns(impl, voters, payload, depth) = matched_row(impl, voters, payload, depth).summary.median
#let matched_impls = (("odin", [Odin]), ("zig", [Zig]),
  ("omnipaxos", [OmniPaxos]), ("libpaxos", [LibPaxos3]))

#let matched_comparison_table() = {
  text(size: 8pt, fill: gray)[Recorded #matched.meta.date on #matched.meta.cpu_model.
    Nine samples per row; median ns per completed value; lower is better.]
  table(
    columns: (0.5fr, 0.6fr, 0.5fr, 0.8fr, 0.8fr, 0.8fr, 0.9fr, 0.9fr),
    align: (left, right, right, right, right, right, right, right),
    table.header([*$N$*], [*Bytes*], [*Depth*], [*Odin before*],
      ..matched_impls.map(i => [*#i.at(1)*])),
    ..matched.runs.filter(r => r.impl == "odin").map(r => (
      [#r.nodes], [#r.payload_bytes], [#r.depth],
      [#calc.round(matched_ns("odin-baseline", r.nodes, r.payload_bytes, r.depth), digits: 1)],
      ..matched_impls.map(i => [#calc.round(matched_ns(i.at(0), r.nodes, r.payload_bytes, r.depth), digits: 1)]),
    )).flatten(),
  )
}

#let matched_cost_picture() = {
  // Common linear scale within each panel; no truncated baseline.
  for spec in ((3, 8, 64), (5, 8, 1), (3, 1024, 64)) {
    let (voters, payload, depth) = spec
    let maximum = calc.max(..matched_impls.map(i => matched_ns(i.at(0), voters, payload, depth)))
    block(above: 7pt, below: 7pt, breakable: false)[
      #text(weight: "bold", size: 9pt)[#voters voters · #payload bytes · depth #depth]
      #v(3pt)
      #grid(columns: (23mm, 85mm, 22mm), row-gutter: 4pt, column-gutter: 3mm, align: left + horizon,
        ..matched_impls.map(i => {
          let value = matched_ns(i.at(0), voters, payload, depth)
          ([#i.at(1)], rect(width: 85mm * value / maximum, height: 7pt,
            fill: if i.at(0) == "odin" { blue } else { gray }, stroke: none),
            text(size: 8pt)[#calc.round(value, digits: 1) ns])
        }).flatten(),
      )
    ]
  }
}

#let recovery_storage_picture() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  content((4, 2.1), text(size: 9pt)[One slot, two indexes: window 8, chunk 3, base 7])
  content((-0.3, 1.2), text(size: 8pt)[slot], anchor: "east")
  content((-0.3, 0.4), text(size: 8pt)[ledger cell], anchor: "east")
  for i in range(8) {
    let active = i == 0 or i >= 6
    rect((i, 0), (i + 0.9, 0.8), fill: if active { blue_light } else { white }, stroke: gray)
    content((i + 0.45, 0.4), text(size: 9pt)[#i])
    content((i + 0.45, 1.2), text(size: 9pt)[#(i + 1)])
  }
  content((0.45, 1.65), text(size: 8pt, fill: blue)[also 9])
  for (j, slot, cell) in ((0, 7, 6), (1, 8, 7), (2, 9, 0)) {
    let x = 2.2 + j * 1.2
    rect((x, -2), (x + 1, -1.2), fill: green_light, stroke: green)
    content((x + 0.5, -1.6), text(size: 9pt)[#j])
    line((cell + 0.45, 0), (x + 0.5, -1.2), stroke: 0.6pt + blue, mark: (end: ">"))
    content((x + 0.5, -2.35), text(size: 8pt)[slot #slot])
  }
  content((1.85, -1.6), text(size: 8pt)[scratch index], anchor: "east")
  content((4, -3), text(size: 8pt)[ledger: (slot − 1) & 7 #h(8mm) scratch: slot − 7])
})

#let recovery_selection_flow() = diagram(
  spacing: (32mm, 17mm), edge-stroke: gray,
  node((0, 0), [Collect reports #linebreak() for one chunk], ..node_style),
  node((1, 0), [Complete read quorum #linebreak() Freeze selected values], ..node_style),
  node((2, 0), [Drive phase two #linebreak() Copy into ledger], ..node_style),
  node((2, 1), [Window full #linebreak() Keep selection], fill: amber_light, stroke: amber, inset: 7pt),
  node((1, 1), [Chunk finished #linebreak() Reset scratch metadata], fill: green_light, stroke: green, inset: 7pt),
  edge((0, 0), (1, 0), "-|>"),
  edge((1, 0), (2, 0), "-|>"),
  edge((2, 0), (2, 1), "-|>"),
  edge((2, 1), (2, 0), "-|>", [floor advances], bend: 35deg),
  edge((2, 0), (1, 1), "-|>"),
  edge((1, 1), (0, 0), "-|>", [next chunk]),
)

#let chosen_timeline() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  for (x, label) in ((0, "Leader A"), (4, "Voter B"), (8, "Voter C")) {
    content((x, 0.5), text(weight: "bold", size: 9pt, label))
    line((x, 0), (x, -4), stroke: 0.6pt + gray)
  }
  content((0, -0.3), text(size: 8pt)[A's vote durable], anchor: "west")
  line((0, -0.8), (4, -1.3), mark: (end: ">"), stroke: blue)
  content((2, -0.8), text(size: 8pt)[Accept X])
  circle((4, -1.7), radius: 0.09, fill: green)
  content((4.2, -1.7), text(size: 8pt, fill: green)[B's vote durable: X chosen], anchor: "west")
  line((4, -2.2), (0, -2.7), mark: (end: ">"), stroke: blue)
  content((2, -2.2), text(size: 8pt)[Accepted])
  content((0.2, -3), text(size: 8pt)[A learns X is chosen], anchor: "west")
  line((0, -3.5), (8, -3.9), mark: (end: ">"), stroke: gray)
  content((5, -3.4), text(size: 8pt)[Commit X: tell C])
})

#let borrowed_value_flow() = diagram(
  spacing: (32mm, 17mm), edge-stroke: gray,
  node((0, 0), [Transition #linebreak() Ledger owns value], ..node_style),
  node((1, 0), [Effects borrow pointers #linebreak() Valid until next transition], ..node_style),
  node((2, 0), [Host copies / serialises #linebreak() Queue owns bytes], fill: green_light, stroke: green, inset: 7pt),
  node((2, 1), [Later delivery #linebreak() Rebind to packet's copy], ..node_style),
  node((0, 1), [Next transition #linebreak() May reuse ledger storage], fill: amber_light, stroke: amber, inset: 7pt),
  edge((0, 0), (1, 0), "-|>"),
  edge((1, 0), (2, 0), "-|>"),
  edge((2, 0), (2, 1), "-|>"),
  edge((2, 0), (0, 1), "-|>", [batch consumed]),
)

#let ownership_picture() = {
  table(columns: (21mm, ..range(6).map(_ => 16mm)), align: center,
    table.header([*Slot*], [1], [2], [3], [4], [5], [6]),
    [*Owner*], [A], [B], [C], [A], [B], [C],
    [*Value*], table.cell(fill: green_light)[X], table.cell(fill: amber_light)[hole],
      table.cell(fill: green_light)[Z], [·], [·], [·],
    [*Release*], [X →], [blocked], [waits], [·], [·], [·],
  )
  align(center, text(size: 8pt, fill: gray)[
    B skips slot 2, or a read quorum recovers it at a higher ballot.\
    Only then can the application receive slots 2 and 3.
  ])
}

#let flexible_quorum_picture() = {
  table(columns: (35mm, ..range(5).map(_ => 18mm)), align: center,
    table.header([*Five voters*], [A], [B], [C], [D], [E]),
    [Write quorum: 2], table.cell(fill: green_light)[vote X],
      table.cell(fill: green_light)[vote X], [·], [·], [·],
    [Read quorum: 4], [·], table.cell(fill: blue_light)[report X],
      table.cell(fill: blue_light)[report], table.cell(fill: blue_light)[report],
      table.cell(fill: blue_light)[report],
  )
  align(center, text(size: 8pt)[
    B witnesses both quorums. Any four voters must include A or B.
  ])
}

#let proof_dependency_picture() = diagram(
  spacing: (34mm, 17mm), edge-stroke: gray,
  node((0, 0), [Quorums intersect #linebreak() A witness exists], ..node_style),
  node((1, 0), [Durable votes + promises #linebreak() The witness remembers], ..node_style),
  node((2, 0), [Complete reports #linebreak() Selection preserves X], ..node_style),
  node((1, 1), [One value per ballot + induction #linebreak() Every chosen value equals X],
    fill: green_light, stroke: green, inset: 7pt),
  edge((0, 0), (1, 0), "-|>"),
  edge((1, 0), (2, 0), "-|>"),
  edge((2, 0), (1, 1), "-|>"),
)

#let recovery_memory_picture() = {
  let before = csv("/bench/results/recovery-memory-before.csv")
  let after = csv("/bench/results/recovery-memory-after.csv")
  for spec in (("256", "64"), ("4096", "256")) {
    let select(rows) = rows.find(r => r.at(0) == "1024" and r.at(1) == "3"
      and r.at(2) == spec.at(0) and r.at(3) == spec.at(1))
    let old = int(select(before).last())
    let new = int(select(after).last())
    block(above: 6pt, below: 6pt, breakable: false)[
      #text(size: 9pt, weight: "bold")[Window #spec.at(0), chunk #spec.at(1)]
      #v(3pt)
      #grid(columns: (18mm, 80mm, 30mm), align: left + horizon, row-gutter: 5pt, column-gutter: 3mm,
        [Before], rect(width: 80mm, height: 9pt, fill: gray, stroke: none), [#old B],
        [After], rect(width: 80mm * new / old, height: 9pt, fill: blue, stroke: none), [#new B],
      )
    ]
  }
}

// Proposed SDK boundaries; arrows denote calls, not a second consensus protocol.
#let python_sdk_layers() = diagram(
  spacing: (42mm, 18mm),
  node((0, 0), [Python application], ..node_style),
  node((1, 0), [`Session` / `Node` #linebreak() Owned Python bytes], ..node_style),
  node((1, 1), [Versioned C ABI #linebreak() Opaque handle + batch token], ..node_style),
  node((0, 1), [Existing Odin core #linebreak() Bounded node + effects], ..node_style),
  edge((0, 0), (1, 0), "-|>"),
  edge((1, 0), (1, 1), "-|>"),
  edge((1, 1), (0, 1), "-|>"),
)

#let python_sdk_batch() = diagram(
  spacing: (42mm, 17mm),
  node((0, 0), [1. Begin transition #linebreak() Retain native batch], ..node_style),
  node((1, 0), [2. Copy journal records #linebreak() Persist + sync], ..node_style),
  node((1, 1), [3. Confirm exact token #linebreak() Copy outputs], ..node_style),
  node((0, 1), [4. Send / release #linebreak() Finish batch], ..node_style),
  edge((0, 0), (1, 0), "-|>"),
  edge((1, 0), (1, 1), "-|>"),
  edge((1, 1), (0, 1), "-|>"),
)
