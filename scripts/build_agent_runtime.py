#!/usr/bin/env python3
"""Builds the trimmed dsh runtime that Spot Chat bundles for running commands.

Usage: build_agent_runtime.py --node <extracted Node distribution> --out <folder>

The folder gets:
  node            the Node binary from the given distribution
  app/            agent/package.json and its lock installed with `npm ci`, then trimmed
  profile/        Spot Chat's dsh profile (agent/profile)
  dsh             a launcher: dsh [args...]

Trimming keeps dsh's code but not what it never reads:
  - packages listed in agent/runtime-packages.txt (the ones whose code loads) lose TypeScript
    sources, declarations, source maps and Markdown;
  - a platform-specific package (name ending in -darwin-arm64 and the like) is kept like the
    package of its family that loads on the machine the list was made on;
  - every other package keeps only package.json and its licence, so dsh's startup scan of the
    installation still finds it.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AGENT = os.path.join(ROOT, "agent")
PLATFORM = re.compile(r"-(darwin|linux|win32|freebsd|android)-(arm64|x64|ia32|arm)(-gnu|-musl|-msvc)?$")
DROPPED_SUFFIXES = (".ts", ".mts", ".cts", ".map", ".md", ".markdown", ".tsbuildinfo")
KEPT_IN_STUBS = re.compile(r"^(package\.json|licen[sc]e.*|notice.*|copying.*)$", re.IGNORECASE)


def package_roots(app):
    """Every installed package folder, relative to `app`, such as node_modules/@scope/name."""
    roots = []
    for current, dirs, files in os.walk(app):
        rel = os.path.relpath(current, app)
        parts = rel.split(os.sep)
        is_root = (
            "package.json" in files
            and len(parts) >= 2
            and (parts[-2] == "node_modules" or (len(parts) >= 3 and parts[-3] == "node_modules" and parts[-2].startswith("@")))
        )
        if is_root:
            roots.append(rel.replace(os.sep, "/"))
    return roots


def family(root):
    return PLATFORM.sub("", root)


def remove(path):
    if os.path.isdir(path) and not os.path.islink(path):
        shutil.rmtree(path)
    else:
        os.remove(path)


def trim(app, kept_list):
    roots = package_roots(app)
    root_set = set(roots)
    kept = {r for r in roots if r in kept_list}
    kept_families = {family(r) for r in kept_list}
    for r in roots:
        if r not in kept and PLATFORM.search(r) and family(r) in kept_families:
            kept.add(r)
    nested = lambda r: [o for o in root_set if o != r and o.startswith(r + "/")]
    before = du(app)
    for r in roots:
        path = os.path.join(app, r)
        inner = {os.path.join(app, o) for o in nested(r)}
        for current, dirs, files in os.walk(path, topdown=True):
            # Nested packages are handled as roots of their own.
            dirs[:] = [d for d in dirs if os.path.join(current, d) not in inner and not (d == "node_modules" and any(i.startswith(os.path.join(current, d)) for i in inner))]
            for f in files:
                full = os.path.join(current, f)
                if r in kept:
                    if f.endswith(DROPPED_SUFFIXES) and not f.endswith(".d.json"):
                        remove(full)
                elif not (current == path and KEPT_IN_STUBS.match(f)):
                    remove(full)
    # Folders left empty by trimming.
    for current, dirs, files in os.walk(app, topdown=False):
        if not dirs and not files and current != app:
            os.rmdir(current)
    return before, du(app), len(kept), len(roots)


def du(path):
    total = 0
    for current, _, files in os.walk(path):
        for f in files:
            try:
                total += os.lstat(os.path.join(current, f)).st_size
            except OSError:
                pass
    return total


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--node", required=True, help="an extracted Node distribution (with bin/node)")
    parser.add_argument("--out", required=True)
    parser.add_argument("--npm", default="npm")
    args = parser.parse_args()

    out = os.path.abspath(args.out)
    if os.path.exists(out):
        shutil.rmtree(out)
    app = os.path.join(out, "app")
    os.makedirs(app)
    for name in ("package.json", "package-lock.json"):
        shutil.copy(os.path.join(AGENT, name), app)
    subprocess.run([args.npm, "ci", "--ignore-scripts", "--no-audit", "--no-fund", "--omit=dev"], cwd=app, check=True)

    kept_list = {
        line.strip() for line in open(os.path.join(AGENT, "runtime-packages.txt"))
        if line.strip() and not line.startswith("#")
    }
    before, after, kept, total = trim(app, kept_list)
    print(f"Trimmed node_modules from {before / 1e6:.0f} MB to {after / 1e6:.0f} MB, keeping the code of {kept} of {total} packages.")

    node = os.path.join(args.node, "bin", "node")
    shutil.copy(node, os.path.join(out, "node"))
    licence = os.path.join(args.node, "LICENSE")
    if os.path.exists(licence):
        shutil.copy(licence, os.path.join(out, "NODE-LICENSE"))
    shutil.copytree(os.path.join(AGENT, "profile"), os.path.join(out, "profile"))

    launcher = os.path.join(out, "dsh")
    with open(launcher, "w") as f:
        f.write('#!/bin/sh\nhere="$(cd "$(dirname "$0")" && pwd)"\n'
                'exec "$here/node" "$here/app/node_modules/@deepseek-ai/dsh/lib/bin.js" "$@"\n')
    os.chmod(launcher, 0o755)
    version = json.load(open(os.path.join(app, "node_modules", "@deepseek-ai", "dsh", "package.json")))["version"]
    with open(os.path.join(out, "VERSION"), "w") as f:
        f.write(version + "\n")
    print(f"dsh {version} runtime in {out} ({du(out) / 1e6:.0f} MB)")


if __name__ == "__main__":
    sys.exit(main())
