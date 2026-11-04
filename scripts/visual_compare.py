#!/usr/bin/env python3
"""Compares the UI tests' screenshots with approved baselines, so a change in how a screen looks fails CI
rather than waiting for someone to notice it.

Usage:
  visual_compare.py compare <screenshots> <baselines> <diffs folder> [summary file]
  visual_compare.py accept <screenshots> <baselines>

`compare` checks each screen named in UITests/Baselines/screens.json that both folders have; a screen the run
didn't take is skipped, so a run of a few tests checks only theirs. A screen differs when more of its pixels
changed than its tolerance allows; its diff, the changed pixels in red over the new screenshot, goes in the
diffs folder. `accept` copies the listed screens from a run into the baselines, after a change that was meant.

The menu bar (its clock) and the Dock are left out of every comparison.
"""

import json
import os
import shutil
import sys

from PIL import Image, ImageChops

MENU_BAR = 25
DOCK = 64
# A channel has to move this much for a pixel to count as changed, so smoothing differences don't.
THRESHOLD = 24


def screens(baselines):
    with open(os.path.join(baselines, "screens.json")) as f:
        return json.load(f)


def compare_one(new_path, base_path, settings):
    new = Image.open(new_path).convert("RGB")
    base = Image.open(base_path).convert("RGB")
    if new.size != base.size:
        return 100.0, None, f"size {new.size[0]}x{new.size[1]}, baseline {base.size[0]}x{base.size[1]}"
    width, height = new.size
    box = (0, MENU_BAR, width, height - DOCK)
    changed = ImageChops.difference(new, base).convert("L").point(lambda v: 255 if v > THRESHOLD else 0)
    for left, top, right, bottom in settings.get("ignore", []):
        changed.paste(0, (left, top, right, bottom))
    region = changed.crop(box)
    histogram = region.histogram()
    count = sum(histogram[1:])
    percent = count / (region.width * region.height) * 100
    diff = None
    if count:
        red = Image.new("RGB", new.size, (255, 0, 0))
        diff = Image.composite(red, new.point(lambda v: v // 2 + 64), changed)
    return percent, diff, ""


def compare(shots, baselines, diffs, summary):
    listed = screens(baselines)
    os.makedirs(diffs, exist_ok=True)
    rows, failed = [], []
    for name, settings in sorted(listed["compare"].items()):
        new_path = os.path.join(shots, name + ".png")
        base_path = os.path.join(baselines, name + ".png")
        if not os.path.exists(new_path):
            continue
        if not os.path.exists(base_path):
            rows.append(f"| {name} | no baseline yet | |")
            continue
        tolerance = settings.get("tolerance", listed["tolerance"])
        percent, diff, note = compare_one(new_path, base_path, settings)
        ok = percent <= tolerance and not note
        if not ok:
            failed.append(name)
            if diff is not None:
                diff.save(os.path.join(diffs, name + ".png"))
        rows.append(f"| {name} | {percent:.3f}% {'' if ok else 'changed'} | {note} |")
    text = "## Screenshot comparison\n\n"
    if rows:
        text += f"{len(rows) - len(failed)} of {len(rows)} screens match their baselines"
        text += (f"; {len(failed)} changed, their diffs in the VisualDiffs artifact.\n\n" if failed else ".\n\n")
        text += "| Screen | Pixels changed | |\n|---|---|---|\n" + "\n".join(rows) + "\n"
    else:
        text += "No compared screens in this run.\n"
    if summary:
        with open(summary, "a") as f:
            f.write(text)
    print(text)
    return 1 if failed else 0


def accept(shots, baselines):
    listed = screens(baselines)
    taken = 0
    for name in listed["compare"]:
        source = os.path.join(shots, name + ".png")
        if os.path.exists(source):
            shutil.copy(source, os.path.join(baselines, name + ".png"))
            taken += 1
    print(f"Accepted {taken} screens as baselines.")
    return 0


if __name__ == "__main__":
    if len(sys.argv) >= 5 and sys.argv[1] == "compare":
        sys.exit(compare(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5] if len(sys.argv) > 5 else None))
    if len(sys.argv) == 4 and sys.argv[1] == "accept":
        sys.exit(accept(sys.argv[2], sys.argv[3]))
    print(__doc__)
    sys.exit(2)
