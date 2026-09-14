#!/usr/bin/env python3
"""Render the VoxKey comparison pages and sitemap from data files.

    python3 scripts/site/build.py          # write docs/compare/**, docs/es/compare/**, docs/sitemap.xml
    python3 scripts/site/build.py --check  # exit 1 if any generated file is out of date

Data lives in scripts/site/data: strings.toml holds interface text for both
languages, and compare/<slug>.toml holds one competitor with [en] and [es]
sections. Templates in scripts/site/templates use {{placeholders}}; every value
is HTML-escaped by this script, so the data files contain plain text only.
"""
from __future__ import annotations

import argparse
import datetime as dt
import html
import json
import pathlib
import re
import subprocess
import sys
import tomllib

ROOT = pathlib.Path(__file__).resolve().parents[2]
SITE = ROOT / "scripts" / "site"
DOCS = ROOT / "docs"
BASE = "https://voxkey.rodrigouroz.com"
LANGS = ("en", "es")
TODAY = dt.date.today().isoformat()
AUTHOR = {"@type": "Person", "name": "Rodrigo Uroz", "url": "https://cv.rodrigouroz.com/"}
# Hand-written pages that the sitemap must list, as (English path, Spanish path).
HANDWRITTEN = [("", "es/"), ("improve-transcription/", "es/improve-transcription/")]
MONTHS = {
    "en": ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"],
    "es": ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"],
}

esc = lambda s: html.escape(str(s), quote=True)


def git_date(*paths: pathlib.Path) -> str:
    """Last commit date touching any of the paths, or today when one is uncommitted."""
    rel = [str(p.relative_to(ROOT)) for p in paths]
    run = lambda *args: subprocess.run(["git", *args, "--", *rel], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    if run("status", "--porcelain"):
        return TODAY
    return run("log", "-1", "--format=%cs") or TODAY


def long_date(iso: str, lang: str) -> str:
    d = dt.date.fromisoformat(iso)
    return f"{MONTHS[lang][d.month - 1]} {d.day}, {d.year}" if lang == "en" else f"{d.day} de {MONTHS[lang][d.month - 1]} de {d.year}"


def fill(template: str, values: dict[str, str]) -> str:
    def sub(m: re.Match) -> str:
        key = m.group(1)
        if key not in values:
            raise KeyError(f"template placeholder {{{{{key}}}}} has no value")
        return values[key]
    return re.sub(r"\{\{(\w+)\}\}", sub, template)


def ld(graph: list[dict]) -> str:
    return json.dumps({"@context": "https://schema.org", "@graph": graph}, ensure_ascii=False, indent=2)


def load() -> tuple[dict, list[dict], dict[str, pathlib.Path]]:
    strings = tomllib.loads((SITE / "data" / "strings.toml").read_text(encoding="utf-8"))
    files = sorted((SITE / "data" / "compare").glob("*.toml"))
    items = [tomllib.loads(f.read_text(encoding="utf-8")) for f in files]
    items.sort(key=lambda i: i["order"])
    paths = {i["slug"]: f for i, f in zip(items, files)}
    for item in items:
        for lang in LANGS:
            if lang not in item:
                raise SystemExit(f"{item['slug']}: missing [{lang}] section")
    return strings, items, paths


def common(s: dict, lang: str, path: str) -> dict[str, str]:
    """Header, footer, and language-switcher values shared by both templates."""
    other = "es" if lang == "en" else "en"
    paths = {lang: f"{s[lang]['prefix']}/{path}", other: f"{s[other]['prefix']}/{path}"}
    values = {k: esc(v) for k, v in s[lang].items() if isinstance(v, str)}
    values.update({
        "url": f"{BASE}{paths[lang]}",
        "url_en": f"{BASE}{paths['en']}",
        "url_es": f"{BASE}{paths['es']}",
        "path_en": paths["en"],
        "path_es": paths["es"],
        "current_en": ' aria-current="page"' if lang == "en" else "",
        "current_es": ' aria-current="page"' if lang == "es" else "",
        "home_href": f"{s[lang]['prefix']}/",
        "hub_href": f"{s[lang]['prefix']}/compare/",
        "og_image": f"{BASE}{s[lang]['og_image']}",
    })
    return values


def render_detail(s: dict, items: list[dict], item: dict, lang: str, modified: str, template: str) -> str:
    t, d = s[lang], item[lang]
    prefix, slug, name = t["prefix"], item["slug"], d["name"]
    path = f"compare/{slug}/"
    v = common(s, lang, path)
    url, hub = v["url"], f"{BASE}{prefix}/compare/"
    rows = "\n".join(
        f'<tr><th scope="row">{esc(r["label"])}</th><td data-label="VoxKey">{esc(r["voxkey"])}</td><td data-label="{esc(name)}">{esc(r["other"])}</td></tr>'
        for r in d["rows"])
    sources = "\n".join(f'<li><a href="{esc(src["url"])}">{esc(src["label"])}</a></li>' for src in d["sources"])
    related = "".join(f'<a href="{prefix}/compare/{o["slug"]}/">{esc(o[lang]["name"])}</a>' for o in items if o["slug"] != slug)
    extra = ""
    if "extra_h" in d:
        extra = (f'    <section class="compare-section compare-extra" aria-labelledby="extra-title"><h2 id="extra-title">{esc(d["extra_h"])}</h2>'
                 f'<p>{esc(d["extra_p"])} <a href="{esc(d["extra_href"])}">{esc(d["extra_link"])}</a></p></section>')
    graph = [
        {"@type": "WebSite", "@id": f"{BASE}/#website", "name": "VoxKey", "url": f"{BASE}/", "inLanguage": list(LANGS)},
        {"@type": "WebPage", "@id": f"{url}#webpage", "url": url, "name": d["title"], "description": d["description"], "inLanguage": lang,
         "dateModified": modified, "isPartOf": {"@id": f"{BASE}/#website"}, "breadcrumb": {"@id": f"{url}#breadcrumb"},
         "primaryImageOfPage": {"@type": "ImageObject", "url": v["og_image"], "width": 1200, "height": 630}, "author": AUTHOR,
         "mainEntity": {"@id": f"{url}#article"}},
        {"@type": "BreadcrumbList", "@id": f"{url}#breadcrumb", "itemListElement": [
            {"@type": "ListItem", "position": 1, "name": "VoxKey", "item": f"{BASE}{prefix}/"},
            {"@type": "ListItem", "position": 2, "name": t["breadcrumb_compare"], "item": hub},
            {"@type": "ListItem", "position": 3, "name": f"VoxKey vs {name}", "item": url}]},
        {"@type": "Article", "@id": f"{url}#article", "headline": d["title"], "description": d["description"], "url": url,
         "mainEntityOfPage": {"@id": f"{url}#webpage"}, "image": v["og_image"], "datePublished": item["published"], "dateModified": modified,
         "inLanguage": lang, "author": AUTHOR, "publisher": {"@type": "Organization", "name": "VoxKey", "url": f"{BASE}/"},
         "about": [{"@type": "SoftwareApplication", "name": "VoxKey", "url": f"{BASE}/"}, {"@type": "SoftwareApplication", "name": name}]},
    ]
    v.update({
        "title": esc(d["title"]), "description": esc(d["description"]), "name": esc(name), "eyebrow": esc(d["eyebrow"]), "lead": esc(d["lead"]),
        "researched_iso": item["researched"], "researched": esc(t["researched"].format(date=long_date(item["researched"], lang))),
        "choose_voxkey_h": esc(t["choose_voxkey"]), "choose_other_h": esc(t["choose_other"].format(name=name)),
        "choose_voxkey": esc(d["choose_voxkey"]), "choose_other": esc(d["choose_other"]),
        "rows": rows, "note": esc(d["note"]), "sources": sources, "related": related, "extra": extra,
        "limits_line": esc(t["limits_line"]).replace("{link}", f'<a href="{prefix}/compare/#limits">{esc(t["limits_link"])}</a>'),
        "sources_intro": esc(t["sources_intro"]).replace("{link}", f'<a href="{prefix}/compare/#method">{esc(t["method_link"])}</a>'),
        "ld_json": ld(graph),
    })
    return fill(template, v)


def render_hub(s: dict, items: list[dict], lang: str, modified: str, template: str) -> str:
    t = s[lang]
    prefix = t["prefix"]
    v = common(s, lang, "compare/")
    url = v["url"]
    g = t["glance_voxkey"]
    glance_rows = [f'<tr class="voxkey-row"><th scope="row">VoxKey</th><td data-label="{esc(t["col_price"])}">{esc(g["price"])}</td>'
                   f'<td data-label="{esc(t["col_processing"])}">{esc(g["processing"])}</td><td data-label="{esc(t["col_useful"])}">{esc(g["useful_for"])}</td></tr>']
    cards = []
    for n, item in enumerate(items, 1):
        d, href = item[lang], f"{prefix}/compare/{item['slug']}/"
        gl = d["glance"]
        glance_rows.append(f'<tr><th scope="row"><a href="{href}">{esc(d["name"])}</a></th><td data-label="{esc(t["col_price"])}">{esc(gl["price"])}</td>'
                           f'<td data-label="{esc(t["col_processing"])}">{esc(gl["processing"])}</td><td data-label="{esc(t["col_useful"])}">{esc(gl["useful_for"])}</td></tr>')
        cards.append(f'      <article class="compare-card"><p class="eyebrow">{esc(t["card_eyebrow"].format(n=f"{n:02d}"))}</p><h3><a href="{href}">{esc(d["name"])}</a></h3>'
                     f'<p>{esc(d["card"])}</p><a href="{href}" class="text-link">{esc(t["read"])}</a></article>')
    researched = max(i["researched"] for i in items)
    graph = [
        {"@type": "WebSite", "@id": f"{BASE}/#website", "name": "VoxKey", "url": f"{BASE}/", "inLanguage": list(LANGS)},
        {"@type": "CollectionPage", "@id": f"{url}#webpage", "url": url, "name": t["hub_title"], "description": t["hub_description"], "inLanguage": lang,
         "dateModified": modified, "isPartOf": {"@id": f"{BASE}/#website"}, "breadcrumb": {"@id": f"{url}#breadcrumb"},
         "primaryImageOfPage": {"@type": "ImageObject", "url": v["og_image"], "width": 1200, "height": 630}, "author": AUTHOR,
         "mainEntity": {"@id": f"{url}#comparisons"}},
        {"@type": "BreadcrumbList", "@id": f"{url}#breadcrumb", "itemListElement": [
            {"@type": "ListItem", "position": 1, "name": "VoxKey", "item": f"{BASE}{prefix}/"},
            {"@type": "ListItem", "position": 2, "name": t["breadcrumb_compare"], "item": url}]},
        {"@type": "ItemList", "@id": f"{url}#comparisons", "numberOfItems": len(items), "itemListElement": [
            {"@type": "ListItem", "position": n, "name": f"VoxKey vs {i[lang]['name']}", "url": f"{BASE}{prefix}/compare/{i['slug']}/"}
            for n, i in enumerate(items, 1)]},
    ]
    v.update({
        "title": esc(t["hub_title"]), "description": esc(t["hub_description"]),
        "researched_iso": researched, "researched": esc(t["researched"].format(date=long_date(researched, lang))),
        "glance_rows": "\n".join(glance_rows), "cards": "\n".join(cards), "ld_json": ld(graph),
    })
    return fill(template, v)


def render_sitemap(items: list[dict], paths: dict[str, pathlib.Path], shared: list[pathlib.Path]) -> str:
    entries: list[tuple[str, str, str]] = []  # (en path, es path, lastmod)
    for en, es in HANDWRITTEN:
        entries.append((en, es, git_date(DOCS / en / "index.html", DOCS / es / "index.html")))
    entries.append(("compare/", "es/compare/", git_date(*paths.values(), *shared, SITE / "templates" / "compare-hub.html")))
    for item in items:
        entries.append((f"compare/{item['slug']}/", f"es/compare/{item['slug']}/", git_date(paths[item["slug"]], *shared)))
    out = ["<?xml version='1.0' encoding='utf-8'?>",
           '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">']
    for en, es, lastmod in entries:
        for loc in (en, es):
            out += [f"  <url>", f"    <loc>{BASE}/{loc}</loc>", f"    <lastmod>{lastmod}</lastmod>",
                    f'    <xhtml:link rel="alternate" hreflang="en" href="{BASE}/{en}" />',
                    f'    <xhtml:link rel="alternate" hreflang="es" href="{BASE}/{es}" />',
                    f'    <xhtml:link rel="alternate" hreflang="x-default" href="{BASE}/{en}" />', "  </url>"]
    out.append("</urlset>")
    return "\n".join(out) + "\n"


def build() -> dict[pathlib.Path, str]:
    strings, items, paths = load()
    detail_t = (SITE / "templates" / "compare-detail.html").read_text(encoding="utf-8")
    hub_t = (SITE / "templates" / "compare-hub.html").read_text(encoding="utf-8")
    shared = [SITE / "data" / "strings.toml", SITE / "build.py"]
    out: dict[pathlib.Path, str] = {}
    hub_modified = git_date(*paths.values(), *shared, SITE / "templates" / "compare-hub.html")
    for lang in LANGS:
        prefix = strings[lang]["prefix"].strip("/")
        base = DOCS / prefix if prefix else DOCS
        out[base / "compare" / "index.html"] = render_hub(strings, items, lang, hub_modified, hub_t)
        for item in items:
            modified = git_date(paths[item["slug"]], *shared, SITE / "templates" / "compare-detail.html")
            out[base / "compare" / item["slug"] / "index.html"] = render_detail(strings, items, item, lang, modified, detail_t)
    out[DOCS / "sitemap.xml"] = render_sitemap(items, paths, shared)
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="report files that differ from the rendered output instead of writing")
    args = parser.parse_args()
    out = build()
    stale = [p for p, content in out.items() if not p.exists() or p.read_text(encoding="utf-8") != content]
    if args.check:
        for p in stale:
            print("out of date:", p.relative_to(ROOT))
        print("up to date" if not stale else f"{len(stale)} file(s) need `python3 scripts/site/build.py`")
        return 1 if stale else 0
    for p in stale:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(out[p], encoding="utf-8")
        print("wrote", p.relative_to(ROOT))
    print(f"{len(out)} files rendered, {len(stale)} changed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
