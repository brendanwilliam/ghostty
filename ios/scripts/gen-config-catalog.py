#!/usr/bin/env python3
"""Generate ios/Resources/ConfigCatalog.json, the list of Ghostty config
options shown in the app's "All options" screen.

Inputs:
  config.mdx    from `zig build -Demit-webdata` (share/ghostty/webdata/config.mdx)
  defaults.txt  from `ghostty +show-config --default`

Usage:
  ios/scripts/gen-config-catalog.py config.mdx defaults.txt > ios/Resources/ConfigCatalog.json
"""

import json
import re
import sys

PLATFORM_MARKERS = {
    "macos": re.compile(r"\b(macOS only|only (supported|implemented|available) on macOS|on macOS only)\b", re.I),
    "gtk": re.compile(r"\b(GTK only|only (supported|implemented|available) on (GTK|Linux)|Linux only|GTK-only)\b", re.I),
}
BULLET_VALUE = re.compile(r"^\s*\*\s+`([^`]+)`")
COLOR = re.compile(r"^#[0-9a-fA-F]{6}$")
NUMBER = re.compile(r"^-?\d+(\.\d+)?$")


def parse_docs(path):
    """Return {key: doc} from config.mdx. Several `## key` headings in a row
    share the following doc text."""
    options = {}
    order = []
    pending = []
    body = []

    def flush():
        doc = "\n".join(body).strip()
        for key in pending:
            options[key] = doc
            order.append(key)

    with open(path, encoding="utf-8") as f:
        lines = f.read().split("\n")

    in_header = True
    for line in lines:
        if in_header:
            if line.startswith("## "):
                in_header = False
            else:
                continue
        m = re.match(r"^## `([^`]+)`\s*$", line)
        if m:
            if body:
                flush()
                pending, body = [], []
            pending.append(m.group(1))
            continue
        body.append(line)
    if pending:
        flush()
    return options, order


def parse_defaults(path):
    defaults = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            defaults.setdefault(key.strip(), []).append(value.strip())
    return defaults


def classify(doc, defaults):
    values = []
    for line in doc.split("\n"):
        m = BULLET_VALUE.match(line)
        if m and " " not in m.group(1) and "=" not in m.group(1):
            values.append(m.group(1))
    values = list(dict.fromkeys(values))

    default = defaults[-1] if defaults else ""
    if default in ("true", "false"):
        return "bool", []
    if len(values) >= 2 and (default in values or default == ""):
        return "enum", values
    if COLOR.match(default):
        return "color", []
    if NUMBER.match(default):
        return "number", []
    return "text", []


def plain(doc):
    """Strip MDX components and code fences down to readable text."""
    doc = re.sub(r"</?(Warning|Note|Tip|Important)>", "", doc)
    return doc.strip()


def platform(key, doc):
    if key.startswith("macos-"):
        return "macos"
    if key.startswith(("gtk-", "linux-", "x11-")):
        return "gtk"
    for name, pattern in PLATFORM_MARKERS.items():
        if pattern.search(doc):
            return name
    return None


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    docs, order = parse_docs(sys.argv[1])
    defaults = parse_defaults(sys.argv[2])

    catalog = []
    for key in order:
        doc = docs[key]
        default_values = defaults.get(key, [])
        kind, values = classify(doc, default_values)
        entry = {
            "key": key,
            "doc": plain(doc),
            "default": default_values[-1] if default_values else "",
            "kind": kind,
            "repeatable": len(default_values) > 1 or "repeated" in doc,
        }
        if values:
            entry["values"] = values
        if platform(key, doc):
            entry["platform"] = platform(key, doc)
        catalog.append(entry)

    json.dump(catalog, sys.stdout, indent=1, ensure_ascii=False)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
