# Changelog

## 2026-11-25 — Plugin API compatibility and installation

- Open `.plugin` attachments and document-picker imports in a native detail window before installation; include metadata, declared requirements, blockers, update/install actions, explicit activation and settings.
- Preserve settings on disabled-plugin updates and bind installation to the previewed SHA-256. Align source-only limits to 4 MiB across staging, storage, Objective-C and Python.
- Extend portable SDK signatures, settings descriptors, account-bound callbacks, cleanup, text formatting, logging, file/URI utilities and basic alerts/bulletins. Unsupported native operations remain explicit errors.
- Correct outgoing hook final/cancel semantics, validate text replacements and discard stale generations. Add atomic owner-scoped settings replacement and generation-checked UI reloads.
- Inventory 493 standalone sources and 21 archives without executing attachments. Add deterministic corpus/audit tooling and packaging checks for all bundled SDK modules.

Native compilation, iPhone execution, visual fidelity and broad Android plugin compatibility remain unverified. This entry does not mark the full API port complete. See [handoff](HANDOFF.md), [corpus inventory](docs/plugins-corpus-compatibility.md) and [visual acceptance](docs/plugins-installation-validation.md).
