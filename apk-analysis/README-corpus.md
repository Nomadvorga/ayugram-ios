# Corpus audit

Offline AST audit of the Android AyuGram plugin corpus against the iOS bridge
facade. Plugin code is parsed with `ast`, never executed.

## Run

```sh
PYTHONIOENCODING=utf-8 py apk-analysis/audit_corpus.py "<corpus dir>" --out apk-analysis
```

Example (the exported Telegram chat corpus):

```sh
PYTHONIOENCODING=utf-8 py apk-analysis/audit_corpus.py "C:\Users\PC\Downloads\Telegram Desktop\ChatExport_2026-11-24\files"
```

## Outputs

- `corpus-audit.json` — per-plugin records (metadata, imports, missing facade
  symbols, reason categories, verdict) plus aggregates and near-duplicate
  clusters (content hash).
- `corpus-audit.md` — human summary: totals, top missing modules, top
  unsupported reasons, the most valuable plugins to make work.

## Verdicts

- **supported** — only facade-covered or stdlib surface; no native/reflection
  reasons.
- **partial** — unsupported, but only a small missing surface (e.g. one helper
  module), the best porting candidates.
- **unsupported** — native Android/Telegram-class APIs beyond the facade,
  reflection (`getDeclaredMethod`), or the screenshot-privacy class.

Classification tables live at the top of `audit_corpus.py` (`FACADE_CLASSES`,
`FACADE_PACKAGES`, `STDLIB_ROOTS`); extend them as the facade grows.
