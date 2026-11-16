# Tool catalogue

`gen.py` holds the table of 221 tools. `emit.py` turns it into
`ios/App/Albus/Models/StudyTool.swift`. Nothing edits that Swift file by hand.

```bash
python3 emit.py          # regenerate StudyTool.swift, then copy it into ios/
```

## Names, IDs and destinations

A tool's name is the site its tile opens. A tile opens `https://<host>` and
nothing more specific, so the host has to be one that answers on its own:
`usgs.gov` and `noisli.com` only answer with `www.`.

A tool's Swift case, and so its `logo-<id>` asset, is derived from its name. To
rename a tool without moving either, give it its old ID in `IDS` in `gen.py`;
`emit.py`, `make_assets.py` and `fetch_logos.py` all read that table.

When a site closes, delete its row from `gen.py`, its line in
`capabilities.py` and its `logo-<id>.imageset`, then regenerate. Four went this
way on 15 November 2026: Open Access Button (shut down 18 November 2025),
typewritermode.com (the domain no longer exists), Cram (retired 9 November
2026) and Socratic (now a Google Search page).

## Logos

**A tool shows its real logo or it shows nothing.** Never a letter, never a
stand-in glyph, never a colour this app picked for it. An invented brand colour
is a claim about someone else's identity and is the loudest possible sign that
nobody checked.

```bash
python3 fetch_logos.py            # fetch missing logos into ./logos
python3 fetch_logos.py --report   # what is still missing
python3 make_assets.py            # rebuild ios/App/Albus/Assets.xcassets
```

`fetch_logos.py` prefers a site's declared `apple-touch-icon` — the mark a brand
chose for a small square on a phone, which is exactly this use — then a declared
`icon`, then the well-known paths, then Google's favicon endpoint for the hosts
that refuse a non-browser client outright. Anything under 64px or that is not a
real raster image is dropped rather than shipped blurry.

This runs on a developer's machine and the results are committed. The app never
fetches a logo at runtime: doing that would tell two hundred companies when a
student opened the Tools tab, cost a request per tile, and break the screen
offline.

**170 of 221 are covered.** The other 51 ship with no mark, which is the correct
outcome, not a gap to be filled with something invented. To improve one by hand,
drop a square PNG at `logos/<tool-id>.png` and re-run `make_assets.py`.

`logos/` is deliberately not committed — it would be an exact duplicate of every
PNG in the asset catalogue, which is the copy the app builds from. Run
`python3 make_assets.py --restore` to rebuild it from the catalogue offline
before editing.

Showing a company's logo to link to that company is ordinary nominative use for
a directory. If a brand asks not to appear, delete its PNG and re-run
`make_assets.py` — or remove the row from `gen.py` entirely.
