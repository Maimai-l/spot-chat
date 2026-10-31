#!/usr/bin/env python3
"""Exports a UI test result bundle's screenshots as PNGs named after their attachments, and writes a
summary of the run in Markdown.

Usage: export_test_results.py <result bundle> <screenshot folder> [summary file]
"""
import json
import os
import re
import subprocess
import sys


def run(*args):
    return subprocess.run(["xcrun", "xcresulttool", *args], capture_output=True, text=True)


def export_screenshots(bundle, folder):
    os.makedirs(folder, exist_ok=True)
    result = run("export", "attachments", "--path", bundle, "--output-path", folder)
    manifest = os.path.join(folder, "manifest.json")
    if result.returncode != 0 or not os.path.exists(manifest):
        print(result.stderr, file=sys.stderr)
        return []
    names = []
    with open(manifest) as f:
        for test in json.load(f):
            for attachment in test.get("attachments", []):
                exported = os.path.join(folder, attachment["exportedFileName"])
                if not os.path.exists(exported):
                    continue
                readable = attachment.get("suggestedHumanReadableName", attachment["exportedFileName"])
                # Only screenshots; XCTest also attaches text, such as a failed query's debug description.
                if not readable.lower().endswith((".png", ".jpg", ".jpeg", ".heic")):
                    os.remove(exported)
                    continue
                # "Capsule_0_6F1C….png" becomes "Capsule.png", without characters artifacts refuse.
                name = re.sub(r"_\d+_[0-9A-Fa-f-]{36}", "", readable)
                name = re.sub(r'[\\/"<>:|*?\r\n]', "-", name)
                os.replace(exported, os.path.join(folder, name))
                names.append(name)
    os.remove(manifest)
    return sorted(names)


def summary(bundle, screenshots):
    result = run("get", "test-results", "summary", "--path", bundle)
    lines = ["## UI tests", ""]
    if result.returncode == 0:
        data = json.loads(result.stdout)
        lines.append(
            f"{data.get('result', 'Unknown')}: {data.get('passedTests', 0)} passed, "
            f"{data.get('failedTests', 0)} failed, {data.get('skippedTests', 0)} skipped"
        )
        for failure in data.get("testFailures", []):
            lines.append(f"- {failure.get('testName', '')}: {failure.get('failureText', '').strip()}")
    else:
        lines.append("No test summary in the result bundle.")
    if screenshots:
        lines += ["", f"{len(screenshots)} screenshots in the Screenshots artifact."]
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    bundle, folder = sys.argv[1], sys.argv[2]
    shots = export_screenshots(bundle, folder) if os.path.exists(bundle) else []
    text = summary(bundle, shots) if os.path.exists(bundle) else "## UI tests\n\nThe tests did not run.\n"
    if len(sys.argv) > 3:
        with open(sys.argv[3], "a") as f:
            f.write(text)
    print(text)
