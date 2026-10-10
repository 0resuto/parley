# Parley

[![CI](https://github.com/0resuto/parley/actions/workflows/ci.yml/badge.svg)](https://github.com/0resuto/parley/actions/workflows/ci.yml)
![Version](https://img.shields.io/badge/version-0.1.0--alpha-orange.svg)
![Flutter](https://img.shields.io/badge/Flutter-stable-02569B.svg)
![Android](https://img.shields.io/badge/Platform-Android-3DDC84.svg)
![Riverpod](https://img.shields.io/badge/State-Riverpod-5C6BC0.svg)
![drift](https://img.shields.io/badge/Storage-drift%20%2B%20SQLite-7E57C2.svg)
![FSRS](https://img.shields.io/badge/SRS-FSRS-E91E63.svg)

An Android app for improving English by talking to an AI tutor. The chat is the
core: the tutor keeps the conversation inside the words you already know, steers
toward the words you are learning, and wraps a few new ones in `[[brackets]]`
so you can tap them. A dictionary, FSRS flashcards and two plain Markdown
documents (`rules.md`, `notes.md`) feed and steer the conversation.

## How it works

```mermaid
%%{init: {
  'theme': 'base',
  'flowchart': { 'curve': 'basis', 'nodeSpacing': 45, 'rankSpacing': 65, 'wrap': true },
  'themeVariables': {
    'fontSize': '14px',
    'primaryColor': '#37474F',
    'primaryTextColor': '#ffffff',
    'primaryBorderColor': '#78909C',
    'lineColor': '#90A4AE',
    'secondaryColor': '#37474F',
    'tertiaryColor': '#37474F'
  }
}}%%
flowchart LR
    subgraph Device["Parley — Android app"]
        direction TB
        Chat(["Chat<br/>streaming tutor"])
        Popup["Word popup<br/>translate · add · speak"]
        Dictionary["Dictionary<br/>units + statuses"]
        Cards["Cards<br/>FSRS review queue"]
        Jobs["Background tutor jobs<br/>word judge · notes updater"]
        TTS["Text-to-speech<br/>en-US"]

        Chat --> Popup
        Popup --> Dictionary
    end

    subgraph Storage["Local storage"]
        direction TB
        DB[("SQLite · drift<br/>units · reviews · conversations")]
        Docs[/"rules.md · notes.md<br/>+ version history"/]
    end

    API["OpenAI-compatible API<br/>Chat Completions"]

    Chat -->|"stream replies"| API
    Popup -->|"translate a word"| API
    Jobs -->|"JSON jobs"| API
    Chat <--> DB
    Dictionary <--> DB
    Cards <--> DB
    Jobs --> DB
    Jobs --> Docs
    Chat --> TTS

    classDef core fill:#1565C0,stroke:#90CAF9,stroke-width:1.5px,color:#ffffff
    classDef app fill:#2E7D32,stroke:#A5D6A7,stroke-width:1.5px,color:#ffffff
    classDef store fill:#6A1B9A,stroke:#CE93D8,stroke-width:1.5px,color:#ffffff

    class Chat core
    class Popup,Dictionary,Cards,Jobs,TTS app
    class DB,Docs store
    class API core

    style Device fill:none,stroke:#78909C,stroke-width:1px,color:#90A4AE
    style Storage fill:none,stroke:#78909C,stroke-width:1px,color:#90A4AE
```

- **Chat** — streaming tutor replies with Stop/Retry, several conversations, and
  every failure mapped to a clear message (offline, rejected key, rate limit, ...).
- **Tutor documents** — `rules.md` and `notes.md` are plain Markdown you can read
  and edit in the app; the tutor may change the rules only when you ask, and every
  change comes with an Undo chip.
- **Dictionary** — every word in chat is tappable: the popup translates English to
  Russian, adds the word with its inflections, and counts as a light "Again"
  review at most once per day.
- **Cards** — an FSRS due queue (Again / Hard / Good / Easy) with "Mark as known";
  known words stay in the dictionary but leave the queue.
- **Background tutor jobs** — after each reply a word judge rates how you handled
  the target words, and a notes updater rewrites `notes.md` (best-effort,
  offline-aware).
- **Voice** — assistant replies can be played with `flutter_tts` (en-US), with an
  auto-play option.
- **Data** — JSON export/import (merge by word) and CSV import (`word;translation`).

## Requirements

- Flutter stable (Dart 3) with the Android toolchain
- An Android device or emulator (the app is Android-only)
- An OpenAI-compatible Chat Completions endpoint: base URL, API key, model
  (anything that speaks `POST <base>/chat/completions`)

## Setup

```bash
git clone https://github.com/0resuto/parley.git
cd parley
flutter pub get
flutter run
```

Then open **Settings → AI provider**, fill in the base URL, API key and model,
and tap **Test connection**. Everything that can work offline does; online-only
actions show a clear message when there is no connection.

## Configuration

- **AI provider** — base URL, API key (kept in `flutter_secure_storage`), and a
  free-text model name.
- **Tutor** — new-word density (0–30 %) and editors for `rules.md` (max 6000
  chars) and `notes.md` (max 8000 chars) with version history.
- **Voice** — auto-play replies and speech speed (0.5–1.5×).
- **Data** — JSON export/import and CSV import.

## Project layout

```text
lib/
├── main.dart · app.dart      # entry point and root widget
├── core/                     # theme, failures, clock, constants, JSON helper
├── data/                     # drift database, models, repositories
├── services/                 # FSRS, LLM client, documents, TTS/STT, export, tutor jobs
└── features/                 # chat, cards, dictionary, settings (screens, widgets, controllers)
assets/templates/             # seed rules.md and notes.md
test/                         # unit and widget tests (mirrors lib/)
```

## Development

```bash
dart format .
flutter analyze
flutter test
```

Pre-commit checks run on every commit (formatting + analysis) and the test
suite runs before every push. Install the hooks once per clone (requires
`dart` and `flutter` on `PATH`):

```bash
python -m pip install --user pre-commit
pre-commit install
pre-commit install --hook-type pre-push
```

Commits follow [Conventional Commits](https://www.conventionalcommits.org/)
and releases use [Semantic Versioning](https://semver.org/); release notes
live in GitHub Releases.

## License

The app code is MIT — see [LICENSE](LICENSE). The bundled English–Russian
dictionary data (`assets/dictionary/`, built by `tool/build_dictionary.py`
from the [kaikki.org](https://kaikki.org/dictionary/English/) Wiktionary
extract) comes from Wiktionary and is licensed CC BY-SA.
