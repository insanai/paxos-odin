#!/usr/bin/env python3
"""Assemble Typst documents and the generated API reference into GitHub Pages."""
from html import escape
from html.parser import HTMLParser
from pathlib import Path
import re
import shutil
import subprocess
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / 'docs/build'
SITE = ROOT / '_site'
BASE = '/paxos-odin/'


def shell(title, body, pdf=None):
    download = f'<a href="{BASE}downloads/{escape(pdf)}" download>Download PDF ↓</a>' if pdf else ''
    return f'''<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{escape(title)} · Paxos-Odin</title><link rel="stylesheet" href="{BASE}assets/site.css"></head>
<body><a class="skip" href="#main">Skip to content</a><header class="nav">
<a class="brand" href="{BASE}"><span class="mark">p.</span> paxos-odin</a><nav aria-label="Main">
<a href="{BASE}book/">Book</a><a href="{BASE}pods/">PODs</a><a href="{BASE}api/">Python API</a>
<a href="https://github.com/insanai/paxos-odin">GitHub ↗</a></nav></header>
<main id="main" class="reading"><div class="reader-tools"><a href="{BASE}">← Home</a>
<span>{escape(title)}</span>{download}</div><article>{body}</article></main>
<footer><p>Authored by Vikrant Rathore, with assistance from Ronak Rathore.<br>
© 2026 Vikrant Rathore and Ronak Rathore · MIT License</p>
<a href="https://github.com/insanai/paxos-odin/blob/main/LICENSE">License ↗</a></footer></body></html>'''


def document(source, destination, title, pdf):
    text = source.read_text()
    body = re.search(r'<body[^>]*>(.*)</body>', text, re.S)[1]
    # The POD index's local PDFs and source links become stable public routes.
    body = re.sub(r'href="([^"]+\.pdf)"',
                  lambda m: f'href="{BASE}downloads/{Path(m[1]).name}"', body)
    body = re.sub(r'href="(docs/[^"]+\.typ)"',
                  lambda m: f'href="https://github.com/insanai/paxos-odin/blob/main/{m[1]}"', body)
    body = f'<h1>{escape(title)}</h1>' + body
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(shell(title, body, pdf))


class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.targets = []

    def handle_starttag(self, tag, attrs):
        for key, value in attrs:
            if key in {'href', 'src'} and value:
                self.targets.append(value)


def validate():
    broken = []
    for path in SITE.rglob('*.html'):
        parser = Links()
        parser.feed(path.read_text())
        for target in parser.targets:
            url = urlsplit(target)
            if url.scheme or url.netloc or not url.path:
                continue
            part = unquote(url.path)
            if part.startswith(BASE):
                dest = SITE / part[len(BASE):]
            elif part.startswith('/'):
                broken.append((path.relative_to(SITE), target))
                continue
            else:
                dest = path.parent / part
            if not dest.exists():
                broken.append((path.relative_to(SITE), target))
    if broken:
        raise SystemExit(f'Broken local site links: {broken[:30]}')
    assert '<svg' in (SITE / 'book/index.html').read_text()
    print(f'PASS website: {len(list(SITE.rglob("*.html")))} HTML pages, local links and book vectors')


def main():
    if SITE.exists():
        shutil.rmtree(SITE)
    (SITE / 'assets').mkdir(parents=True)
    (SITE / 'downloads').mkdir()
    shutil.copy2(ROOT / 'docs/site/index.html', SITE / 'index.html')
    shutil.copy2(ROOT / 'docs/site/site.css', SITE / 'assets/site.css')
    (SITE / '.nojekyll').touch()
    for pdf in BUILD.glob('*.pdf'):
        shutil.copy2(pdf, SITE / 'downloads' / pdf.name)
    document(BUILD / 'html/paxos-spec.html', SITE / 'book/index.html', 'The Paxos-Odin book', 'paxos-spec.pdf')
    registry = (ROOT / 'docs/pod/registry.typ').read_text()
    rows = []
    for record in re.findall(r'  \(\n(.*?)\n  \),', registry, re.S):
        fields = dict(re.findall(r'^    (\w+): "([^"]*)",', record, re.M))
        stem = f"pod-{fields['number']}-{fields['slug']}"
        document(BUILD / f'html/{stem}.html', SITE / f'pods/{stem}.html',
                 f"POD {fields['number']}: {fields['title']}", fields['pdf'])
        rows.append(f'''<section class="pod-row"><span class="meta">POD {fields['number']} · {fields['status']}</span>
<h2><a href="{stem}.html">{escape(fields['title'])} ↗</a></h2><p>{escape(fields['summary'])}</p>
<a href="{BASE}downloads/{fields['pdf']}" download>Download PDF ↓</a></section>''')
    (SITE / 'pods/index.html').write_text(shell('Paxos Odin Discussions',
        '<p class="eyebrow">DECISIONS, EXPLAINED</p><h1>Paxos Odin Discussions</h1>'
        '<p>Design records, protocol contracts and dated verification evidence. '
        'Each record states its status; an open proposal is not an implemented feature.</p>'
        '<div class="pod-list">'+''.join(rows)+'</div>', 'pod-index.pdf'))
    shutil.copytree(BUILD / 'html/paxodin', SITE / 'api')
    validate()


if __name__ == '__main__':
    main()
