// Diagram and layout helpers for the Paxos-Odin specification book

#let consensus-box(title, body) = block(
  width: 100%,
  fill: rgb("f8fafc"),
  stroke: 0.5pt + rgb("cbd5e1"),
  inset: 12pt,
  radius: 6pt,
  [
    #text(weight: "bold", fill: rgb("1e293b"))[#title] \
    #v(4pt)
    #body
  ]
)
