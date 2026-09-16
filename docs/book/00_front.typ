#align(center)[
  #v(2cm)
  #text(28pt, weight: "bold", fill: rgb("0f172a"))[The Part-Time Parliament]
  #v(0.5cm)
  #text(16pt, fill: rgb("2563eb"))[From Paper to Idiomatic Odin State Machine]
  #v(1cm)
  #text(11pt, fill: rgb("64748b"))[
    Vikrant Varma & Paxos-Odin Contributors \
    #datetime.today().display("[year]-[month]-[day]") \
    Version 0.7.0
  ]
  #v(2cm)
]

#block(
  width: 100%,
  fill: rgb("f8fafc"),
  stroke: 0.5pt + rgb("cbd5e1"),
  inset: 16pt,
  radius: 6pt,
)[
  #text(12pt, weight: "bold")[Abstract] \ \
  Consensus algorithms are famously difficult to understand, implement, and operate. Most implementations exacerbate this complexity by coupling the protocol state machine to specific network runtimes, thread pools, timers, and storage engines.

  *Paxos-Odin* is a complete, bounded, deterministic implementation of Classic and Multi-Paxos written in idiomatic Odin that performs *no I/O*. It owns no sockets, threads, clocks, or heap memory. All transitions consume events and emit explicit, caller-owned *Effects*. This document provides the complete derivation, algorithmic specification, durability safety proofs, and verification evidence.
]

#pagebreak()
#outline(indent: auto)
#pagebreak()
