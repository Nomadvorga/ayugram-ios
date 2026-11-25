# AI service User-Agent

The service editor exposes User-Agent under exteraGram → AI → Services → a service.
Each service keeps an independent choice. It is applied to Chat Completions,
Responses/Agent generation (including retries) and model discovery, using the
same service snapshot as the endpoint, model and API key. Selecting a preset or
editing the custom value changes only the draft until Save. Cancel and Back do
not persist it. Request execution locks the selector.

| Choice | Explicit HTTP User-Agent |
| --- | --- |
| Default | None; URLSession supplies the normal client value |
| OpenCode | `opencode` |
| Claude Code | `claude-cli` |
| ZCode | `ZCode` |
| Codex | `codex_cli_rs` |
| Cursor | `Cursor` |
| Cline | `Cline` |
| Roo Code | `RooCode` |
| Custom | Exact validated user input |

These are unversioned client identifiers. They do not assert a specific installed
version or reproduce another client's API dialect, authentication, system prompt,
tools, beta headers or TLS fingerprint. Providers may inspect those independently.
The editor displays the actual configured string, and Custom accepts a provider's
documented value when its gateway requires a particular format/version.

Custom values must contain 1–512 printable ASCII bytes, with no leading/trailing
spaces. CR, LF, NUL, tabs and non-ASCII input are rejected before persistence or
transport. API credentials and request bodies retain their existing handling.
Redirects remain disabled. Old service JSON defaults to Default and an empty
custom value. Services, including these fields, remain outside the portable
settings backup, which excludes endpoints and credentials.

Tests in `Tests/ExteraAI/ExteraAIClientTests.swift` cover legacy JSON, every preset's
Codable round trip, invalid values and atomic failure, and intercept both HTTP
request paths for all explicit choices. Local tree-sitter parsing is separate from
Swift compilation and execution on the Mac CI runner.

Before visual capture, expect the selector to mark exactly the chosen preset;
the header preview must update in the same list publication. Custom Cancel keeps
the preceding choice, invalid input keeps its editor, and successful Save/reopen
retains the value independently per service. Record EN/RU, light/dark, large text,
selector open/close and Back paths using `simctl io recordVideo`. Inspect labelled
frames with indices/timestamps and `tools/animation_sheet.py` per `AGENTS.md`.
No simulator recording or visual acceptance is claimed by this source change.
