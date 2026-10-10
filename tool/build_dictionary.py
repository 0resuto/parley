#!/usr/bin/env python3
"""Build assets/dictionary/en_ru.sqlite3 from a WikDict en-ru SQLite download.

Source data: https://download.wikdict.com/dictionaries/sqlite/ (WikDict,
derived from Wiktionary, CC BY-SA). The app ships a compact derivative:
per headword up to three Russian translations, ranked by the WikDict score
(good rows first), with Wiktionary stress marks removed.

Usage:
    python tool/build_dictionary.py <wikdict-en-ru.sqlite3> [output.sqlite3]

The default output path is assets/dictionary/en_ru.sqlite3.
"""
import re
import sqlite3
import sys
from pathlib import Path

WORD_RE = re.compile(r"[A-Za-z][A-Za-z'\u2019\- ]*")
STRESS_MARK = "\u0301"
MAX_TRANSLATIONS = 3
MAX_TRANSLATION_LENGTH = 50


def normalize_key(text: str) -> str:
    """Mirrors normalizeKey() from lib/data/models/unit.dart."""
    text = text.replace("\u2019", "'")
    text = re.sub(r"\s+", " ", text).strip().lower()
    return text


def clean_translation(text: str) -> str:
    return text.replace(STRESS_MARK, "").strip()


def build(src_path: Path, out_path: Path) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    src = sqlite3.connect(f"file:{src_path}?mode=ro", uri=True)
    out = sqlite3.connect(out_path)
    out.execute("PRAGMA journal_mode=OFF")
    out.execute("CREATE TABLE entry (text_key TEXT PRIMARY KEY, translation TEXT NOT NULL)")

    best: dict[str, list[str]] = {}
    rows = src.execute(
        "SELECT written_rep, trans_list FROM translation "
        "ORDER BY is_good DESC, score DESC"
    )
    for written_rep, trans_list in rows:
        if not WORD_RE.fullmatch(written_rep):
            continue
        key = normalize_key(written_rep)
        if not key:
            continue
        current = best.setdefault(key, [])
        if len(current) >= MAX_TRANSLATIONS:
            continue
        for part in trans_list.split(" | "):
            cleaned = clean_translation(part)
            if not cleaned or len(cleaned) > MAX_TRANSLATION_LENGTH:
                continue
            if cleaned in current:
                continue
            current.append(cleaned)
            if len(current) >= MAX_TRANSLATIONS:
                break

    out.executemany(
        "INSERT OR IGNORE INTO entry (text_key, translation) VALUES (?, ?)",
        [(key, ", ".join(values)) for key, values in best.items() if values],
    )
    out.commit()
    out.execute("VACUUM")
    out.close()
    src.close()


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    src_path = Path(sys.argv[1])
    out_path = (
        Path(sys.argv[2])
        if len(sys.argv) > 2
        else Path("assets/dictionary/en_ru.sqlite3")
    )
    build(src_path, out_path)
    count = sqlite3.connect(out_path).execute("SELECT COUNT(*) FROM entry").fetchone()[0]
    print(f"{out_path}: {count} entries")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
