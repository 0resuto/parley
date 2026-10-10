#!/usr/bin/env python3
"""Build assets/dictionary/en_ru.sqlite3 from the kaikki.org English JSONL dump.

Source data: https://kaikki.org/dictionary/English/ (Wiktextract extraction of
English Wiktionary, CC BY-SA). The app ships a compact derivative: per headword
up to three Russian translations in Wiktionary sense order, so the common
meaning comes first, with stress marks and wiki markup removed.

Wiktextract keeps translations either on the sense they belong to or at the
entry level with a short sense label; entry-level items are matched back to a
sense by comparing that label with the sense glosses.

Inflected forms (got, could, banks, ...) whose senses carry `form_of` inherit
the translations of their lemma when they have none of their own.

Lookups are case-insensitive, so entries like "nice" and "Nice" share one key.
When several entries collide (e.g. "turkey" the bird and "Turkey" the country,
"i" the letter and "I" the pronoun) Wiktionary page order decides, but proper
names, letter names and other low-value entries only win when nothing better
exists. High-frequency function words whose Wiktionary page order reads oddly
in the popup are curated in tool/dictionary_overrides.json and merged over the
data.

Usage:
    python tool/build_dictionary.py <kaikki-english.jsonl> [output.sqlite3]

The default output path is assets/dictionary/en_ru.sqlite3. After rebuilding,
bump dictionaryAssetVersion in lib/services/dictionary/dictionary_initializer.dart
so installed apps replace their stale copy.
"""
import json
import re
import sqlite3
import sys
from pathlib import Path

WORD_RE = re.compile(r"[A-Za-z][A-Za-z'\u2019\- ]*$")
STRESS_MARK = "\u0301"
WIKI_LINK_RE = re.compile(r"\[\[(?:[^\]|]*\|)?([^\]]+)\]\]")
CYRILLIC_RE = re.compile(r"[\u0400-\u04FF]")
JUNK_RE = re.compile(r"[0-9()\[\]{}<>\"|/\\?*=~#@^_`\u2014\u2013]")
SENTENCE_RE = re.compile(r"[.,!?;:]")
SENSE_WORD_RE = re.compile(r"[^\w\s\-'\u2019.]", re.UNICODE)
LETTER_GLOSS_RE = re.compile(r"name of the .*letter|letter of the .*alphabet")

MAX_TRANSLATIONS = 3
MAX_TRANSLATION_LENGTH = 50

# Russian function words that are not dictionary meanings of a content word;
# they only survive when nothing else is available (e.g. "not" -> "не").
PARTICLE_WORDS = {"не", "ни", "же", "ведь", "ли", "бы", "аж"}

# Senses with these tags do not describe the word's everyday meaning.
BAD_SENSE_TAGS = {
    "archaic",
    "dated",
    "dialectal",
    "historical",
    "misspelling",
    "nonstandard",
    "obsolete",
    "offensive",
    "pronunciation-spelling",
    "rare",
    "slang",
    "vulgar",
}

# Entries that exist only as abbreviations, ellipses or misspellings.
ALT_FORM_TAGS = {
    "abbreviation",
    "alt-of",
    "ellipsis",
    "initialism",
    "misspelling",
    "pronunciation-spelling",
}

CONTENT_POS = {
    "adj",
    "adv",
    "conj",
    "det",
    "noun",
    "prep",
    "pron",
    "verb",
}

# Entries with these parts of speech only win when no other entry of the
# word has translations (page order decides between the remaining ones).
LOW_VALUE_POS = {
    "character",
    "name",
    "punct",
    "symbol",
    "root",
    "infix",
    "interfix",
    "circumfix",
    "prefix",
    "suffix",
}


def normalize_key(text: str) -> str:
    """Mirrors normalizeKey() from lib/data/models/unit.dart."""
    text = text.replace("\u2019", "'")
    text = re.sub(r"\s+", " ", text).strip().lower()
    return text


def clean_translation(text: str) -> str:
    text = WIKI_LINK_RE.sub(r"\1", text)
    text = text.replace(STRESS_MARK, "")
    text = text.replace("'''", "").replace("''", "")
    text = text.strip()
    if not text or len(text) > MAX_TRANSLATION_LENGTH:
        return ""
    if not CYRILLIC_RE.search(text) or JUNK_RE.search(text):
        return ""
    if SENTENCE_RE.search(text) or text.startswith("-") or text.endswith("-"):
        return ""
    return text


def normalize_label(text: str) -> str:
    return SENSE_WORD_RE.sub(" ", text.lower()).strip()


def match_sense(label: str, glosses: list[str]) -> int | None:
    """Index of the sense [label] describes, matched by gloss text."""
    lab = normalize_label(label)
    if not lab:
        return None
    for index, gloss in enumerate(glosses):
        if lab in gloss:
            return index
    lab_tokens = set(lab.split())
    if not lab_tokens:
        return None
    for index, gloss in enumerate(glosses):
        gloss_tokens = set(gloss.split())
        overlap = len(lab_tokens & gloss_tokens) / len(lab_tokens)
        if overlap >= 0.7:
            return index
    return None


def is_plain_sense(sense: dict) -> bool:
    tags = set(sense.get("tags") or [])
    return not (tags & BAD_SENSE_TAGS)


def ordered_translations(entry: dict) -> list[str]:
    """Russian translations in sense order, at most MAX_TRANSLATIONS."""
    word = entry.get("word") or ""
    lowercase_headword = word == word.lower()
    senses = entry.get("senses") or []
    glosses = [
        " ".join(sense.get("glosses") or []).lower() for sense in senses
    ]
    buckets: list[list[str]] = [[] for _ in senses]
    tail: list[str] = []
    for item in entry.get("translations") or []:
        if item.get("lang_code") != "ru":
            continue
        cleaned = clean_translation(item.get("word") or "")
        if not cleaned:
            continue
        if lowercase_headword and cleaned[0].isupper():
            # Example sentences leaked into translation tables.
            continue
        index = match_sense(item.get("sense") or "", glosses)
        if index is not None and not is_plain_sense(senses[index]):
            continue
        if index is None:
            tail.append(cleaned)
        else:
            buckets[index].append(cleaned)
    for sense, bucket in zip(senses, buckets):
        if not is_plain_sense(sense):
            continue
        for item in sense.get("translations") or []:
            if item.get("lang_code") != "ru":
                continue
            cleaned = clean_translation(item.get("word") or "")
            if not cleaned:
                continue
            if lowercase_headword and cleaned[0].isupper():
                continue
            bucket.append(cleaned)
    ordered: list[str] = []
    seen: set[str] = set()
    for word in [word for bucket in buckets for word in bucket] + tail:
        if word in seen:
            continue
        seen.add(word)
        ordered.append(word)
    if entry.get("pos") in CONTENT_POS:
        meaningful = [w for w in ordered if w not in PARTICLE_WORDS]
        if meaningful:
            ordered = meaningful
    return ordered[:MAX_TRANSLATIONS]


def is_low_value(entry: dict) -> bool:
    if entry.get("pos") in LOW_VALUE_POS:
        return True
    senses = entry.get("senses") or []
    if not senses:
        return False
    if all(set(s.get("tags") or []) & ALT_FORM_TAGS for s in senses):
        return True
    first_gloss = " ".join(senses[0].get("glosses") or []).lower()
    return bool(LETTER_GLOSS_RE.search(first_gloss))


def entry_lemma(entry: dict) -> str:
    """Lemma of an inflected form, or '' when the entry is not a form."""
    for sense in entry.get("senses") or []:
        for form_of in sense.get("form_of") or []:
            word = (form_of.get("word") or "").strip()
            if word:
                return normalize_key(word)
    return ""


def build(src_path: Path, out_path: Path, overrides: dict[str, str]) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out = sqlite3.connect(out_path)
    out.execute("PRAGMA journal_mode=OFF")
    out.execute(
        "CREATE TABLE entry (text_key TEXT PRIMARY KEY, translation TEXT NOT NULL)"
    )

    best: dict[str, list[str]] = {}
    fallback: dict[str, list[str]] = {}
    forms: dict[str, str] = {}
    best_index: dict[str, int] = {}
    fallback_index: dict[str, int] = {}
    form_index: dict[str, int] = {}
    counter = 0
    with src_path.open("r", encoding="utf-8") as src:
        for line in src:
            if '"lang_code": "en"' not in line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            counter += 1
            word = entry.get("word") or ""
            if not WORD_RE.fullmatch(word):
                continue
            key = normalize_key(word)
            if not key:
                continue
            translations = ordered_translations(entry)
            if translations:
                if is_low_value(entry):
                    if key not in fallback:
                        fallback[key] = translations
                        fallback_index[key] = counter
                elif key not in best:
                    best[key] = translations
                    best_index[key] = counter
                continue
            lemma = entry_lemma(entry)
            if lemma and lemma != key and key not in forms:
                forms[key] = lemma
                form_index[key] = counter

    def resolve(key: str, depth: int = 0) -> list[str]:
        own = best.get(key)
        own_index = best_index.get(key)
        if own is None:
            own = fallback.get(key)
            own_index = fallback_index.get(key)
        lemma = forms.get(key)
        if (
            depth < 4
            and lemma is not None
            and form_index.get(key, 1 << 60)
            < (own_index if own_index is not None else 1 << 60)
        ):
            resolved = resolve(lemma, depth + 1)
            if resolved:
                return resolved
        if own:
            return own
        if lemma and depth < 4:
            return resolve(lemma, depth + 1)
        return []

    entries: dict[str, str] = {}
    for key in best.keys() | fallback.keys() | forms.keys():
        translations = resolve(key)
        if translations:
            entries[key] = ", ".join(translations)
    for key, lemma in forms.items():
        if key in overrides or lemma not in overrides:
            continue
        if best.get(key) is None and fallback.get(key) is None:
            # A pure inflected form (banks, could, ...) of an overridden word.
            entries[key] = overrides[lemma]
    entries.update(overrides)

    out.executemany(
        "INSERT OR IGNORE INTO entry (text_key, translation) VALUES (?, ?)",
        sorted(entries.items()),
    )
    out.commit()
    out.execute("VACUUM")
    out.close()


def load_overrides() -> dict[str, str]:
    path = Path(__file__).with_name("dictionary_overrides.json")
    if not path.exists():
        return {}
    with path.open("r", encoding="utf-8") as f:
        data = json.load(f)
    return {
        normalize_key(key): value.strip()
        for key, value in data.items()
        if not key.startswith("_") and value.strip()
    }


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
    build(src_path, out_path, load_overrides())
    count = (
        sqlite3.connect(out_path)
        .execute("SELECT COUNT(*) FROM entry")
        .fetchone()[0]
    )
    print(f"{out_path}: {count} entries")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
