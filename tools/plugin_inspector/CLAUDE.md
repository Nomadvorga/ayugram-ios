# Plugin inspector

This directory owns a stdlib-only, static AST compatibility inspector. Do not import or execute inspected plugins, resolve network dependencies, install packages, or copy user-provided plugin source into this repository.

- The bridge implementation owns support declarations. Keep the default manifest unconfigured until real implementations and runtime build provenance exist. Never infer all members are supported from a module/class declaration.
- Preserve `execution_verified: false` and `runtime_validation_required: true`. Static support is an inventory assertion, not a runtime or security guarantee.
- Reports contain API identifiers, line evidence and bounded identity/version metadata. Do not include raw source, arbitrary literals, endpoints, settings, keys, filesystem input paths, or exception messages. Malformed input errors must remain generic.
- Keep reads, AST size, manifest size and recursion bounded. Do not recursively scan directories or import plugin-local code.
- JSON and Markdown reports share one underlying finding model; retain deterministic ordering and exact status semantics documented in README.md.
- `preflight.py` (`preflight-corpus`) is the one mode that imports the bridge SDK: it reports the bridge's own `preflight_plugin_json` blockers over a directory through a capabilities-only stand-in host. It still never imports or executes a plugin; keep its flags and JSON keys stable, other tooling measures progress with it.
- Tests: `python3 -B -m unittest tools.plugin_inspector.tests` from the repository root. Synthetic fixtures must never require Android, Telegram, a network service, a compiled extension, or an iOS build. User-device thermal/battery constraints take precedence over running tests immediately.
