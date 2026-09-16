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
  node((0, 1), [Chosen / Decided], fill: green_light, stroke: 0.8pt + green,
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

// Benchmark tables are generated from the recorded results file written by
// `make bench-compare` (tools/bench_compare.py). Nothing here is typed by hand: the
// machine, tool versions, and every number come from bench/results/latest.json.
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
