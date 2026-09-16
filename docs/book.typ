// The Paxos Odin Book & Formal Specification
// Assembles all chapters into a comprehensive, published specification PDF.

#import "shared/theme.typ": configure-document

#show: doc => configure-document(
  title: "The Part-Time Parliament: Paxos-Odin Specification",
  author: "Vikrant Varma & Paxos-Odin Contributors",
  doc,
)

#include "book/00_front.typ"

#include "book/01_tour.typ"

#pagebreak()
#include "book/02_protocol.typ"

#pagebreak()
#include "book/03_durability.typ"

#pagebreak()
#include "book/04_replicated_log.typ"

#pagebreak()
#include "book/05_learner.typ"

#pagebreak()
#include "book/06_trimming.typ"

#pagebreak()
#include "book/07_simulation.typ"
