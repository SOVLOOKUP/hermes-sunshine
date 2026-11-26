#!/usr/bin/env python3
"""Merge a published image version tag into ``versions.json``.

The control plane reads this file through jsDelivr (a static CDN copy), so the
create-session dialog can list versions even when Docker Hub is rate-limited or
unreachable from mainland China. Only plain version tags (``v?N(.N)*``) are
tracked; rolling tags such as ``latest``/``main`` never belong here.
"""

from __future__ import annotations

import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

VERSION_RE = re.compile(r"^v?\d+(?:\.\d+)*$")


def _segments(tag: str) -> tuple[int, ...]:
    core = tag[1:] if tag.startswith("v") else tag
    return tuple(int(part) for part in core.split("."))


def main() -> int:
    if len(sys.argv) != 3:
        print(
            "usage: update_versions_manifest.py <versions.json> <tag>",
            file=sys.stderr,
        )
        return 2
    path = Path(sys.argv[1])
    tag = sys.argv[2].strip()
    if not VERSION_RE.match(tag):
        print(f"skip: {tag!r} is not a plain version tag")
        return 0

    if path.exists():
        data = json.loads(path.read_text(encoding="utf-8"))
    else:
        data = {"tags": []}
    tags = list({*data.get("tags", []), tag})
    tags.sort(key=_segments, reverse=True)
    data["tags"] = tags
    data["stable"] = tags[0] if tags else None
    data["updated"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    path.write_text(
        json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    print(f"versions now: {tags}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
