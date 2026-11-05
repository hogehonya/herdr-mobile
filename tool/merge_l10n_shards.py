#!/usr/bin/env python3
"""Merge localization shards into the two ARB files.

Each shard is `app/lib/l10n/shards/<area>.json`:

    {"entries": [{"key": "uiFoo", "en": "Foo", "ja": "フー",
                  "placeholders": {"p0": "String"}}]}

Keys already present are checked, not overwritten: the English text must match,
so a screen that already shows the string does not change. Run from anywhere:

    python3 tool/merge_l10n_shards.py [--dry-run]
"""

from __future__ import annotations

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
L10N = ROOT / "app" / "lib" / "l10n"
SHARDS = L10N / "shards"
KEY = re.compile(r"^[a-z][A-Za-z0-9]*$")


def load(path: pathlib.Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> int:
    dry = "--dry-run" in sys.argv
    en_path, ja_path = L10N / "app_en.arb", L10N / "app_ja.arb"
    en, ja = load(en_path), load(ja_path)
    added, same, conflicts = [], [], []

    for shard in sorted(SHARDS.glob("*.json")):
        data = load(shard)
        for entry in data.get("entries", []):
            key, text_en, text_ja = entry.get("key"), entry.get("en"), entry.get("ja")
            if not key or not KEY.match(key):
                conflicts.append(f"{shard.name}: bad key {key!r}")
                continue
            if not text_en or not text_ja:
                conflicts.append(f"{shard.name}: {key} needs both en and ja")
                continue
            if key in en:
                if en[key] == text_en:
                    same.append(key)
                else:
                    conflicts.append(f"{shard.name}: {key} already has other English {en[key]!r}")
                continue
            en[key] = text_en
            # ARB v2 placeholders: `flutter gen-l10n` rejects the old
            # {"p0": "String"} form, so each name carries a {"type": ...} map.
            meta = None
            if entry.get("placeholders"):
                meta = {
                    "placeholders": {
                        name: {"type": kind}
                        for name, kind in entry["placeholders"].items()
                    }
                }
            if meta:
                en["@" + key] = meta
            ja[key] = text_ja
            added.append(key)

    print(f"added {len(added)}, already present {len(same)}, conflicts {len(conflicts)}")
    for line in conflicts:
        print("  conflict:", line)
    if conflicts:
        return 1
    if dry or not added:
        return 0

    en_path.write_text(json.dumps(en, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    ja_path.write_text(json.dumps(ja, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
