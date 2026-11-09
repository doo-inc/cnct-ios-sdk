#!/usr/bin/env python3
"""Write CNCTUI's Localizable.strings from docs/chat-ui/strings.json.

The JSON is the shared table — the same keys and words the web and Android SDKs ship — so it is the
source, and the .strings files are generated from it rather than edited. `StringsTests` fails when
the two disagree; run this to bring them back:

    python3 scripts/generate-strings.py
"""
import json
import pathlib

root = pathlib.Path(__file__).resolve().parent.parent
table = json.loads((root / "docs/chat-ui/strings.json").read_text(encoding="utf-8"))


def escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


for language, words in table.items():
    lines = [
        "/* Generated from docs/chat-ui/strings.json by scripts/generate-strings.py. Do not edit. */",
        "",
    ]
    for key, value in words.items():
        lines.append(f'"{escape(key)}" = "{escape(value)}";')
    path = root / f"Sources/CNCTUI/Resources/{language}.lproj/Localizable.strings"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"{path.relative_to(root)}: {len(words)} keys")
