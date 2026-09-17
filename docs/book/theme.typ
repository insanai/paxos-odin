#import "@preview/cetz:0.5.2" as cetz

#let ink = rgb("172033")
#let blue = rgb("2855a6")
#let blue_light = rgb("eaf0fb")
#let green = rgb("27734d")
#let green_light = rgb("eaf7f0")
#let amber = rgb("9a6200")
#let amber_light = rgb("fff5dc")
#let red = rgb("9f3030")
#let red_light = rgb("fcecec")
#let gray = rgb("667085")
#let rule = rgb("d4d9e2")

#let book(body) = {
  set document(
    title: "The Part-Time Parliament: Paxos-Odin",
    author: "Vikrant Varma & Paxos-Odin Contributors",
    keywords: ("Paxos", "consensus", "Odin", "distributed systems", "Multi-Paxos"),
  )
  set page(
    paper: "a4",
    margin: (inside: 25mm, outside: 20mm, top: 22mm, bottom: 24mm),
    numbering: "1",
    number-align: center,
    header: context {
      if counter(page).get().first() > 1 {
        set text(size: 8pt, fill: gray)
        // A chapter heading follows the header on its opening page. Include
        // headings on this page so the running title does not name the last chapter.
        let current-page = here().page()
        let headings = query(heading.where(level: 1)).filter(
          item => item.location().page() <= current-page,
        )
        let chapter = if headings.len() > 0 { headings.last().body } else { [] }
        grid(
          columns: (1fr, 1fr),
          box(width: 100%, clip: true)[The Part-Time Parliament · Paxos-Odin],
          box(width: 100%, clip: true, align(right, emph(chapter))),
        )
        line(length: 100%, stroke: 0.4pt + rule)
      }
    },
  )
  set text(font: "Liberation Serif", size: 10.3pt, fill: ink, lang: "en")
  set smartquote(enabled: false)
  set par(justify: true, leading: 0.74em, spacing: 0.72em)
  set heading(numbering: "1.1")
  set raw(tab-size: 4)
  show raw: set text(font: "Liberation Mono", size: 8.3pt)
  set table(stroke: 0.45pt + rule, inset: 6pt)
  show table: set par(justify: false)
  show link: set text(fill: blue)
  show heading.where(level: 1): heading => {
    pagebreak(weak: true)
    block(above: 4mm, below: 6mm)[
      #text(size: 22pt, weight: "bold", fill: ink)[#heading]
      #line(length: 38mm, stroke: 1.5pt + blue)
    ]
  }
  show heading.where(level: 2): set text(size: 15pt, fill: ink)
  show heading.where(level: 3): set text(size: 12pt, fill: blue)
  body
}

#let title_page() = {
  let cover_ink = rgb("233149")
  let cover_muted = rgb("626b77")
  let cover_gold = rgb("a98337")
  let cover_blue = rgb("275d98")
  let cover_green = rgb("356b52")
  let cover_rule = rgb("d8d3c9")
  let cover_paper = rgb("fdfcf9")

  set page(
    margin: (x: 23mm, top: 15mm, bottom: 18mm),
    header: none,
    numbering: none,
    background: rect(width: 100%, height: 100%, fill: cover_paper),
  )

  align(center)[
    #v(8mm)
    #text(size: 45pt, weight: "light", tracking: 7pt, fill: cover_ink)[PAXOS-ODIN]
    #v(7mm)
    #grid(
      columns: (1fr, auto, 1fr),
      column-gutter: 7pt,
      align: horizon,
      line(length: 100%, stroke: 0.65pt + cover_gold),
      circle(radius: 2.3pt, fill: cover_gold),
      line(length: 100%, stroke: 0.65pt + cover_gold),
    )
    #v(7mm)
    #text(size: 12pt, weight: "medium", tracking: 2.2pt, fill: cover_gold)[
      THE PART-TIME PARLIAMENT IN ODIN
    ]
    #v(7mm)
    #text(size: 9pt, weight: "medium", tracking: 2pt, fill: cover_ink)[
      A LITERATE GUIDE TO CONSENSUS
    ]
    #v(2mm)
    #text(size: 9pt, weight: "medium", tracking: 2pt, fill: cover_ink)[
      FOR UNRELIABLE TIMES
    ]
    #v(8mm)

    #cetz.canvas(length: 1cm, {
      import cetz.draw: *

      // A restrained parliament icon.
      circle((0, 3.15), radius: 0.72, fill: cover_paper,
        stroke: 0.85pt + cover_muted)
      rect((-0.82, 2.28), (0.82, 3.15), fill: cover_paper, stroke: none)
      line((-0.78, 2.74), (0.78, 2.74), stroke: 0.85pt + cover_muted)
      line((0, 3.88), (0, 4.58), stroke: 0.75pt + cover_muted)
      line((0, 4.53), (0.48, 4.4), (0, 4.25), stroke: 0.8pt + cover_gold)
      rect((-0.95, 2.45), (0.95, 2.68), fill: cover_paper,
        stroke: 0.85pt + cover_muted)
      rect((-1.1, 2.27), (1.1, 2.47), fill: cover_paper,
        stroke: 0.85pt + cover_muted)
      rect((-1.25, 2.08), (1.25, 2.28), fill: cover_paper,
        stroke: 0.85pt + cover_muted)
      for x in (-0.8, -0.4, 0, 0.4, 0.8) {
        line((x, 2.08), (x, 2.45), stroke: 0.7pt + cover_muted)
      }
      rect((-1.35, 1.9), (1.35, 2.08), fill: cover_paper,
        stroke: 0.85pt + cover_muted)
      content((0, 1.48), text(size: 8pt, weight: "medium",
        tracking: 1.5pt, fill: cover_ink)[LEARNERS])

      // Learners observe a quorum through several independently arriving votes.
      for p in ((-1.8, 1.22), (-1.5, 0.88), (-1.0, 0.65),
        (-0.5, 0.53), (0, 0.49), (0.5, 0.53), (1.0, 0.65),
        (1.5, 0.88), (1.8, 1.22)) {
        circle(p, radius: 0.055, fill: rgb("aeb2b6"), stroke: none)
      }
      circle((-1.12, 0.65), radius: 0.11, fill: rgb("8e9295"), stroke: none)
      circle((0, 0.49), radius: 0.11, fill: rgb("8e9295"), stroke: none)
      circle((1.12, 0.65), radius: 0.11, fill: rgb("8e9295"), stroke: none)
      line((0, 0.38), (0, -0.42), stroke: 0.7pt + rgb("b7b9bb"))

      // Proposer and acceptor remain visually distinct but symmetric.
      circle((-3.55, -1.35), radius: 1.45, fill: cover_paper,
        stroke: 0.9pt + cover_blue)
      circle((3.55, -1.35), radius: 1.45, fill: cover_paper,
        stroke: 0.9pt + cover_green)
      content((-3.55, -0.72), text(size: 8.5pt, weight: "medium",
        tracking: 1pt, fill: cover_blue)[PROPOSERS])
      content((3.55, -0.72), text(size: 8.5pt, weight: "medium",
        tracking: 1pt, fill: cover_green)[ACCEPTORS])

      // Person glyph.
      circle((-3.55, -1.45), radius: 0.22, fill: cover_paper,
        stroke: 1pt + cover_blue)
      line((-3.92, -2.08), (-3.88, -1.85), (-3.72, -1.68),
        (-3.55, -1.62), (-3.38, -1.68), (-3.22, -1.85),
        (-3.18, -2.08), stroke: 1pt + cover_blue)

      // Shield and check glyph.
      line((3.55, -1.28), (3.98, -1.42), (3.92, -1.91),
        (3.75, -2.12), (3.55, -2.25), (3.35, -2.12),
        (3.18, -1.91), (3.12, -1.42), (3.55, -1.28),
        stroke: 1pt + cover_green)
      line((3.32, -1.78), (3.49, -1.96), (3.8, -1.61),
        stroke: 1pt + cover_green)

      // Both roles converge on the same chosen fact.
      line((-2.1, -1.35), (-0.38, -1.35), mark: (end: ">"),
        stroke: 0.9pt + cover_blue)
      line((2.1, -1.35), (0.38, -1.35), mark: (end: ">"),
        stroke: 0.9pt + cover_green)
      circle((0, -1.35), radius: 0.2, fill: cover_gold,
        stroke: 0.6pt + rgb("8d6e30"))
    })

    #v(4mm)
    #text(size: 15pt, fill: cover_ink)[
      $ |Q_1| + |Q_2| > N quad => quad Q_1 ∩ Q_2 != ∅ $
    ]
    #v(6mm)
    #line(length: 49mm, stroke: 0.55pt + cover_gold)
    #v(5mm)
    #text(size: 10.5pt, style: "italic", fill: cover_muted)[
      Agreement, even when members come and go.
    ]
    #v(35mm)
    #text(size: 10pt, weight: "medium", tracking: 2pt, fill: cover_ink)[
      VIKRANT VARMA
    ]
    #v(2mm)
    #text(size: 7.5pt, tracking: 0.6pt, fill: cover_muted)[
      AND THE PAXOS-ODIN COMMUNITY
    ]
  ]
}

#let part_page(number, title, summary) = {
  set page(header: none)
  pagebreak(to: "odd")
  align(center + horizon)[
    #text(size: 11pt, tracking: 1.6pt, fill: blue)[PART #number]
    #v(5mm)
    #text(size: 28pt, weight: "bold")[#title]
    #v(7mm)
    #line(length: 34mm, stroke: 1.5pt + blue)
    #v(7mm)
    #box(width: 72%, text(size: 10.5pt, fill: gray)[#summary])
  ]
  pagebreak()
}

#let callout(title, body, kind: "note") = {
  let colors = if kind == "warning" {
    (red, red_light)
  } else if kind == "idea" {
    (green, green_light)
  } else {
    (blue, blue_light)
  }
  block(
    width: 100%,
    inset: 10pt,
    outset: (y: 3pt),
    radius: 3pt,
    fill: colors.at(1),
    stroke: (left: 2pt + colors.at(0)),
  )[
    #text(weight: "bold", fill: colors.at(0))[#title]
    #h(5pt)
    #body
  ]
}

#let definition(term, body) = callout(term, body, kind: "idea")
#let warning(title, body) = callout(title, body, kind: "warning")

#let book_quote(body, attribution) = block(
  width: 88%,
  inset: (left: 12pt, right: 8pt, y: 7pt),
  outset: (y: 4pt),
  stroke: (left: 1.2pt + blue),
)[
  #emph(body)
  #linebreak()
  #align(right, text(size: 9pt, fill: gray)[#text("- ")#attribution])
]

#let exercise(number, body, hint: none) = block(
  width: 100%,
  inset: 9pt,
  outset: (y: 3pt),
  radius: 3pt,
  fill: amber_light,
  stroke: 0.6pt + amber,
)[
  #text(weight: "bold", fill: amber)[Exercise #number.]
  #h(4pt)
  #body
  #if hint != none [
    #linebreak()
    #text(size: 9pt, fill: gray)[Hint: #hint]
  ]
]

#let transcript(rows) = table(
  columns: (auto, auto, 1fr),
  align: (right, left, left),
  table.header(
    [*Step*], [*Actor*], [*Event and reason*],
  ),
  ..rows,
)

#let objectives(body) = callout([Learning contract], body, kind: "idea")
#let checkpoint(title, body) = callout([Checkpoint: #title], body)
#let predict(body) = callout([Predict before reading on], body, kind: "warning")

#let teach_back(body) = block(
  width: 100%,
  inset: 9pt,
  outset: (y: 3pt),
  radius: 3pt,
  fill: blue_light,
  stroke: 0.6pt + blue,
)[
  #text(weight: "bold", fill: blue)[Teach it back.]
  #h(4pt)
  #body
]

#let api_anchor(symbol, purpose, source: none) = {
  let location = if source == none { [] } else { [ in #source] }
  callout([API anchor: #symbol], [#purpose#location])
}

#let code_file(path, body) = block(
  width: 100%,
  inset: 0pt,
  outset: (y: 4pt),
  stroke: 0.6pt + rule,
  radius: 3pt,
)[
  #block(width: 100%, inset: 6pt, fill: blue_light)[
    #text(size: 8pt, weight: "bold", fill: blue)[#path]
  ]
  #block(width: 100%, inset: 8pt)[#body]
]

#let fit_figure(body) = layout(size => {
  let width = measure(body).width
  let factor = calc.min(1, size.width / width)
  scale(x: factor * 100%, y: factor * 100%, reflow: true, body)
})

#let book_figure(caption, body) = figure(
  placement: none,
  context {
    if target() == "html" {
      html.frame(block(width: 165mm, fit_figure(body)))
    } else { fit_figure(body) }
  },
  kind: image,
  caption: text(size: 9pt, fill: gray)[#caption],
)
