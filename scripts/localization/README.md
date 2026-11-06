# Application localization

English is the default and fallback language, independently of the system language. Settings → General → App Language offers English and 简体中文, persisted as appLanguage through AppPreferences. The selected UI language is resolved once per process and changes apply on the next launch so AppKit menus and retained windows stay consistent. Explicit AppleLanguages command-line arguments remain available for isolated artwork previews when no appLanguage preference is saved. L10n translates UI templates, then substitutes captured interpolation values without translating user content. Stable enum raw values remain unchanged.

`source-keys.json` and human-authored `en.tsv` contain the original catalog. `extra-strings.json` holds support and AppIntent strings. Run `python3 scripts/localization/apply.py` only when regenerating resources after editing translations. This command defaults to resource generation and does not remigrate source.

`extract.swift` uses installed Xcode SwiftParser/SwiftSyntax for syntax-aware literal extraction. `--migrate-source` was a one-time operation against the original byte-offset snapshot; do not repeat against migrated or edited sources. Diagnostic, benchmark, and fixture sources were excluded.

When adding visible text, add matching strings to both locale resources, keep translations in the catalog, and call L10n.text for templates or L10n.translate for stable keys. Keep filesystem identifiers, regex patterns and saved data independent of UI language.
