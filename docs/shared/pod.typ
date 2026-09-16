// Paxos Odin Discussions (POD) Specification Frame & Helper Library
// Modeled on the Zen Discussion Series (ZDS) from zenfmt.

#import "theme.typ": primary-color, secondary-color, accent-color, muted-color, bg-light, border-color

#let pod-placeholder-number = "XXXXX"

#let pod-state-fill(state) = {
  if state == "published" {
    rgb("dbeafe") // blue
  } else if state == "discussion" {
    rgb("dcfce7") // green
  } else if state == "committed" {
    rgb("ede9fe") // purple
  } else if state == "abandoned" {
    rgb("e5e7eb") // gray
  } else {
    rgb("fef3c7") // yellow
  }
}

#let pod-chip(label, fill) = box(
  inset: (x: 0.5em, y: 0.25em),
  radius: 999pt,
  fill: fill,
  stroke: none,
)[
  #text(8.5pt, weight: "bold", fill: rgb("1e293b"))[#label]
]

#let pod-title(number, title) = {
  if number == pod-placeholder-number {
    [POD #pod-placeholder-number: #title]
  } else {
    [POD #number: #title]
  }
}

#let pod-label(label) = text(8.5pt, weight: "bold", fill: rgb("64748b"))[#upper(label)]
#let pod-value(body) = text(9.5pt, fill: rgb("0f172a"))[#body]

#let pod-document(
  number,
  title,
  body,
  authors: (),
  state: "discussion",
  created: "YYYY-MM-DD",
  discussion: "",
  labels: (),
  category: "Engineering Discussion",
  status: "Draft",
  last-updated: "None",
) = {
  set document(title: [POD #number: #title], author: authors)
  set page(
    paper: "a4",
    margin: (x: 2cm, top: 2.5cm, bottom: 2.5cm),
    numbering: "1",
    header: context {
      if counter(page).get().first() > 1 {
        text(9pt, fill: muted-color)[
          POD #number: #title
          #h(1fr)
          Paxos Odin Discussions
        ]
      }
    },
    footer: context {
      text(9pt, fill: muted-color)[
        #h(1fr)
        Page #counter(page).display()
      ]
    },
  )

  set text(
    font: ("Liberation Sans", "DejaVu Sans"),
    size: 10.5pt,
    fill: primary-color,
    lang: "en",
  )

  // Document Header
  v(0.5cm)
  grid(
    columns: (1fr, auto),
    gutter: 1cm,
    [
      #text(20pt, weight: "bold", fill: rgb("0f172a"))[#pod-title(number, title)]
    ],
    [
      #pod-chip(upper(state), pod-state-fill(state))
    ]
  )
  v(0.5cm)

  let authors-str = if type(authors) == array { authors.join(", ") } else { str(authors) }
  let labels-str = if type(labels) == array { labels.join(", ") } else { str(labels) }

  // Metadata Box
  block(
    width: 100%,
    fill: bg-light,
    stroke: 0.5pt + border-color,
    radius: 6pt,
    inset: 12pt,
    [
      #grid(
        columns: (1fr, 1fr),
        row-gutter: 10pt,
        column-gutter: 20pt,
        [#pod-label("Category")\ #pod-value(category)],
        [#pod-label("Status")\ #pod-value(status)],
        [#pod-label("Authors")\ #pod-value(authors-str)],
        [#pod-label("Created")\ #pod-value(created)],
        [#pod-label("Last Updated")\ #pod-value(last-updated)],
        [#pod-label("Labels")\ #pod-value(labels-str)],
      )
    ]
  )

  v(0.8cm)
  line(length: 100%, stroke: 0.5pt + border-color)
  v(0.5cm)

  body
}

#let pod-index-page(pod-documents) = {
  set document(title: "Paxos Odin Discussions Index", author: "Paxos Odin Contributors")
  set page(
    paper: "a4",
    margin: (x: 2cm, top: 2.5cm, bottom: 2.5cm),
    numbering: "1",
    header: text(9pt, fill: muted-color)[Paxos Odin Discussions (POD) Index],
    footer: context {
      text(9pt, fill: muted-color)[#h(1fr) Page #counter(page).display()]
    },
  )
  set text(font: ("Liberation Sans", "DejaVu Sans"), size: 10pt)

  v(0.5cm)
  text(22pt, weight: "bold", fill: rgb("0f172a"))[Paxos Odin Discussions (POD)]
  v(0.2cm)
  text(11pt, fill: muted-color)[Formal design proposals, consensus derivations, and operational RFCs for Paxos-Odin.]
  v(0.8cm)

  table(
    columns: (auto, auto, 2fr, 3fr),
    stroke: 0.5pt + border-color,
    fill: (col, row) => if row == 0 { rgb("f1f5f9") } else { none },
    inset: 8pt,
    align: (col, row) => (
      if col == 0 { center }
      else if col == 1 { center }
      else { left }
    ),
    [*POD*], [*State*], [*Title*], [*Summary*],
    ..pod-documents.map(doc => (
      [#strong(doc.number)],
      pod-chip(upper(doc.state), pod-state-fill(doc.state)),
      [#strong(doc.title)\ #text(8pt, fill: muted-color)[#doc.category]],
      text(9pt)[#doc.summary],
    )).flatten()
  )
}
