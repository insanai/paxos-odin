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

#let benchmark_comparison_table() = {
  block(
    width: 100%,
    inset: 9pt,
    radius: 5pt,
    fill: blue_light,
    stroke: 0.5pt + rule,
  )[
    #text(size: 11pt, weight: "bold")[Empirical 3-Way Benchmark Comparison]
    #linebreak()
    #text(size: 8pt, fill: gray)[Workload: u64-3n · 131,072 values · 3 voters · in-memory zero-I/O · AMD host · lower latency is better]
    #v(6pt)

    #table(
      columns: (1.2fr, 1.2fr, 1.2fr, 1.2fr, 1.4fr),
      table.header(
        [*Workload Mode*], [*Paxos-Odin*], [*Paxos-Zig*], [*OmniPaxos (Rust)*], [*Performance Ratio*],
      ),
      [Synchronous (`sync`)], [114.7 ns · 8.72M/s], [119.1 ns · 8.40M/s], [1,031.1 ns · 0.97M/s], [Odin 1.04x Zig / 9.0x Omni],
      [Pipelined (`pipeline8`)], [115.6 ns · 8.65M/s], [120.2 ns · 8.32M/s], [197.8 ns · 5.05M/s], [Odin 1.04x Zig / 1.7x Omni],
      [Pipelined (`pipeline64`)], [113.2 ns · 8.83M/s], [118.2 ns · 8.46M/s], [78.6 ns · 12.7M/s†], [Odin 1.04x Zig],
      [Batched (`batch16`)], [111.2 ns · 8.99M/s], [117.9 ns · 8.48M/s], [N/A (no batch API)], [Odin 1.06x Zig],
      [Batched (`batch256`)], [108.8 ns · 9.19M/s], [119.8 ns · 8.35M/s], [N/A (no batch API)], [Odin 1.10x Zig],
    )
    #v(3pt)
    #text(size: 7.5pt, fill: gray)[
      Measured on Linux x86_64 host with Odin nightly and LLVM -O3. †OmniPaxos coalesces batches into large dynamic log chunks in pipeline64, sending 12,288 messages vs 786,432 envelopes in Odin/Zig, but incurs 1,031 ns in single-command sync mode.
    ]
  ]
}
