#!/usr/bin/env python3
"""Turn fetched logos into the app's asset catalogue.

Separate from fetching on purpose: fetching touches the network and is slow,
this is deterministic and instant. Re-run it after adding or removing a logo by
hand — dropping a better PNG into `logos/` and running this is the whole
workflow for improving one tool's mark.

Anything not in `logos/` simply has no asset, and `ToolIcon` renders no mark at
all rather than inventing one.
"""

import importlib.util
import json
import pathlib
import re
import shutil
import sys

HERE = pathlib.Path(__file__).parent
LOGOS = HERE / "logos"
CATALOGUE = HERE.parent.parent / "ios" / "App" / "Albus" / "Assets.xcassets"


# Tools that keep an ID their name no longer derives: see `IDS` in gen.py.
IDS: dict[str, str] = {}


def load_tools():
    spec = importlib.util.spec_from_file_location("gen", HERE / "gen.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    IDS.update(module.IDS)
    return module.T


def ident(name: str) -> str:
    if name in IDS:
        return IDS[name]
    s = re.sub(r"[^A-Za-z0-9]+", " ", name).title().replace(" ", "")
    s = s[0].lower() + s[1:]
    if s[0].isdigit():
        s = "t" + s
    return s


def restore() -> int:
    """Copy the committed artwork back out of the catalogue into `logos/`.

    `logos/` is not committed — it would be an exact duplicate of every PNG in
    the asset catalogue, which is the copy the app actually builds from. This
    puts the working directory back so `make_assets.py` can be re-run after
    deleting a logo, without needing the network.
    """
    LOGOS.mkdir(exist_ok=True)
    count = 0
    for imageset in CATALOGUE.glob("logo-*.imageset"):
        for png in imageset.glob("*.png"):
            shutil.copy2(png, LOGOS / png.name)
            count += 1
    print(f"restored {count} logos into {LOGOS}")
    return 0


def main() -> int:
    if "--restore" in sys.argv:
        return restore()

    tools = load_tools()

    # Rebuilt from scratch so a logo deleted from `logos/` actually disappears
    # from the app rather than lingering in the catalogue.
    if CATALOGUE.exists():
        shutil.rmtree(CATALOGUE)
    CATALOGUE.mkdir(parents=True)
    (CATALOGUE / "Contents.json").write_text(
        json.dumps({"info": {"author": "albus", "version": 1}}, indent=2) + "\n"
    )

    # The moment a catalogue exists, actool insists on an AppIcon set and fails
    # the build without one — the app had no icon and no catalogue before this.
    # An empty set keeps the build green and is where a real icon will go.
    appicon = CATALOGUE / "AppIcon.appiconset"
    appicon.mkdir()
    (appicon / "Contents.json").write_text(json.dumps({
        "images": [{"idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "albus", "version": 1},
    }, indent=2) + "\n")

    written = 0
    for tool in tools:
        key = ident(tool[0])
        source = LOGOS / f"{key}.png"
        if not source.exists():
            continue

        # Matches StudyTool.logoAssetName. If these ever disagree the app shows
        # no logos at all, which is why ToolCatalogTests asserts on the count.
        imageset = CATALOGUE / f"logo-{key}.imageset"
        imageset.mkdir()
        shutil.copy2(source, imageset / f"{key}.png")
        (imageset / "Contents.json").write_text(json.dumps({
            "images": [{"filename": f"{key}.png", "idiom": "universal"}],
            "info": {"author": "albus", "version": 1},
        }, indent=2) + "\n")
        written += 1

    print(f"{written} logo imagesets written to {CATALOGUE.relative_to(CATALOGUE.parents[3])}")
    print(f"{len(tools) - written} tools ship with no mark")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
