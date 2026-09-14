# Website generator

The public site in `docs/` is static HTML on GitHub Pages. The home pages,
`improve-transcription/`, and `404.html` are written by hand. The comparison
section is rendered from data so that both languages, the hub, the sitemap, and
the shared wording stay in step:

```sh
python3 scripts/site/build.py          # render docs/compare/**, docs/es/compare/**, docs/sitemap.xml
python3 scripts/site/build.py --check  # exit 1 when a generated file is out of date
```

Python 3.11 or later; no dependencies.

## Layout

| Path | Purpose |
| --- | --- |
| `data/strings.toml` | Interface text for `[en]` and `[es]`: navigation, headings, the shared method and limits paragraphs, CTA, footer, analytics notice, social image |
| `data/compare/<slug>.toml` | One competitor: `slug`, `order`, `published`, `researched`, then `[en]` and `[es]` with name, title, description, eyebrow, lead, hub card text, at-a-glance cells, the two choice paragraphs, table rows, a note, and the official sources |
| `templates/compare-detail.html` | One "VoxKey vs X" page |
| `templates/compare-hub.html` | `/compare/` |

Data files hold plain text. The build escapes every value, so write `&` and `<`
literally. Optional `extra_h`, `extra_p`, `extra_link`, and `extra_href` add one
short section between the table and the sources (used by the Apple page to point
at `/improve-transcription/`).

## Dates

- `researched` is a claim about when the sources were checked. Update it by hand
  when you re-verify a comparison.
- `published` is the first publication date, used for `datePublished`.
- `dateModified` and the sitemap `lastmod` come from the last commit that touched
  the data file, the strings, or the template. Uncommitted changes render as today.

## Adding a comparison

1. Copy an existing `data/compare/*.toml`, set a new `slug` and `order`, and fill
   both language sections. Every source link should be an official vendor page.
2. Run the build. The hub table, cards, related links, ItemList schema, and
   sitemap update on their own.
3. Commit the data file and the rendered HTML together.
