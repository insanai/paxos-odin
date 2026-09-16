// Shared theme and typography for Paxos-Odin documentation

#let primary-color = rgb("1e293b")
#let secondary-color = rgb("334155")
#let accent-color = rgb("2563eb")
#let muted-color = rgb("64748b")
#let bg-light = rgb("f8fafc")
#let border-color = rgb("e2e8f0")

#let configure-document(
  title: "Paxos Odin",
  author: "Paxos Odin Contributors",
  body,
) = {
  set document(title: title, author: author)
  set page(
    paper: "a4",
    margin: (x: 2cm, top: 2.5cm, bottom: 2.5cm),
    numbering: "1",
    header: context {
      if counter(page).get().first() > 1 {
        text(9pt, fill: muted-color, font: "Liberation Sans")[
          #title
          #h(1fr)
          Paxos Odin Specification
        ]
      }
    },
    footer: context {
      text(9pt, fill: muted-color, font: "Liberation Sans")[
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

  show heading: it => [
    #v(0.6em)
    #text(fill: rgb("0f172a"), weight: "bold")[#it.body]
    #v(0.3em)
  ]

  show raw: it => {
    if it.block {
      block(
        width: 100%,
        fill: bg-light,
        stroke: 0.5pt + border-color,
        inset: 10pt,
        radius: 4pt,
        text(font: ("Liberation Mono", "DejaVu Sans Mono"), size: 9pt)[#it]
      )
    } else {
      box(
        fill: bg-light,
        inset: (x: 3pt, y: 1pt),
        radius: 3pt,
        text(font: ("Liberation Mono", "DejaVu Sans Mono"), size: 9.5pt)[#it]
      )
    }
  }

  body
}
