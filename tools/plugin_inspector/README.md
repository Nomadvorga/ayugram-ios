# Plugin inspector

A Python standard-library-only AST inspector for Android Telegram `.plugin` source. It reads a single source file and an explicit bridge support manifest. It never imports the plugin or its dependencies, evaluates expressions, contacts services, installs packages, or extracts API keys and other settings.

```sh
python3 -B -m tools.plugin_inspector /path/to/example.plugin --format json
python3 -B -m tools.plugin_inspector /path/to/example.plugin --manifest /path/to/bridge-support.json --format markdown --output /path/to/report.md
python3 -B -m unittest tools.plugin_inspector.tests
```

Run from the repository root. `python3 tools/plugin_inspector/inspector.py ...` is also supported. JSON is the default. The CLI exits 0 after a completed inspection, including an `unsupported` or `unknown` report; it exits 2 for invalid source, bounds exceeded, bad manifests, or file errors. Compatibility status is a report field, not the process exit code. Source and manifest inputs cannot be used as the output destination, including aliases through symlinks or existing hard links.

## Status contract

- `supported`: the **exact statically identified requirement** is declared implemented in the supplied manifest. This is not proof that the implementation behaves correctly.
- `partial`: the manifest explicitly declares partial implementation of that exact requirement.
- `unsupported`: an explicit negative manifest declaration, or external process creation, unavailable in the intended iOS host.
- `unknown`: absent mapping, incomplete declaration, a positive declaration without implementation provenance, or a dynamic/unresolved operation.

Overall status precedence is `unsupported`, then `unknown`, then `partial`, then `supported`. An empty inventory remains `unknown`. Every report has `execution_verified: false` and `runtime_validation_required: true`, even when its static status is `supported`.

The bundled [support-manifest.json](support-manifest.json) is intentionally unconfigured. It asserts no shipped Python runtime, bridge modules, Java classes, methods, or third-party packages. Runtime bridge owners must publish a manifest from their implementation inventory and pass it explicitly. Adding a name to the inspector is never evidence that its implementation exists.

## Manifest schema v1

Top-level fields:

| Field | Meaning |
| --- | --- |
| `schema_version` | Integer `1`. Other versions are rejected. |
| `bridge` | Optional identity metadata for bridge owners; not copied to reports. |
| `python.version` | Embedded interpreter version, or null when not configured. |
| `python.implementation` | Concrete runtime build/package provenance. |
| `python.stdlib` | Explicit list of shipped standard-library roots; no host-Python autodetection. |
| `modules` | Exact Python bridge module names and their symbol inventories. |
| `java_classes` | Exact virtual Java class names and their member inventories. |
| `features` | Explicit operational capabilities such as reflection or proxies. |
| `dependencies` | Packaged Python dependency roots or distribution names. |

Each entry in `modules`, `java_classes`, `features`, and `dependencies` has a `status` from the four values above. A `supported` or `partial` entry additionally needs a nonempty `implementation` string naming a concrete implementation file/build artifact. The inspector treats a missing implementation reference as `unknown`; it does **not** inspect, import, or trust the content of that referenced path. The producer is responsible for correctness and release/build correspondence.

Module entries may have `symbols`. Symbol entries may have `members` recursively. A supported module does not support arbitrary imports or members. Java-class entries may have `members`. A supported Java class does not imply that any of its methods or fields are supported. Inventories are exact; there are no wildcard-positive declarations.

For example, once a real implementation exists, an inventory can take this shape (paths below are illustrative, not a statement about the current bridge):

```json
{
  "schema_version": 1,
  "python": {
    "version": "3.13",
    "implementation": "artifacts/Python.xcframework",
    "stdlib": ["json", "math", "typing"]
  },
  "modules": {
    "java": {
      "status": "supported",
      "implementation": "bridge/python/java.py",
      "symbols": {
        "jclass": {"status": "supported", "implementation": "bridge/python/java.py"}
      }
    },
    "base_plugin": {
      "status": "partial",
      "implementation": "bridge/python/base_plugin.py",
      "symbols": {
        "BasePlugin": {
          "status": "partial",
          "implementation": "bridge/python/base_plugin.py",
          "members": {
            "get_setting": {"status": "supported", "implementation": "bridge/python/base_plugin.py"}
          }
        }
      }
    }
  },
  "java_classes": {
    "org.telegram.ui.MainTabsActivity": {
      "status": "partial",
      "implementation": "bridge/MainTabsAdapter.swift",
      "members": {
        "getInstance": {
          "status": "supported",
          "implementation": "bridge/MainTabsAdapter.swift",
          "returns": "self"
        }
      }
    }
  },
  "features": {
    "reflection": {"status": "partial", "implementation": "bridge/VirtualReflection.swift"}
  },
  "dependencies": {
    "requests": {"status": "unsupported", "native": false}
  }
}
```

A Java member's optional `returns` is `self` or an exact declared Java-class name. It resolves simple returned-object chains. Without a declared return type, subsequent Java-member access remains unknown. This deliberately avoids guessing that `getInstance`, `getChildAt`, or any other similarly named method returns a compatible object. Nested Java class paths obtained through attributes also require tracing/mapping; a dotted Python attribute is not automatically a virtual Java inner class.

Recognized feature keys include `method_hooks`, `reflection`, `dynamic_proxy`, `native_ffi`, and `restricted_android_api`. Unavoidable static ambiguities use unknown findings such as `computed_hook`, `computed_reflection`, `enumerated_reflection`, `unresolved_hook_target`, `dynamic_java_members`, `dynamic_code`, `dynamic_attributes`, `conditional_binding`, `relative_import`, `wildcard_import`, `scope_mutation`, and `dynamic_dependency`. Marking a broad feature supported cannot remove evidence for an unresolved target.

## What is inspected

- Plain top-level identity/version metadata: ID, name, plugin version, app/minimum/SDK version requirements. Arbitrary computed metadata is not evaluated.
- Direct imports and simple aliases; literal/constant `jclass` and `find_class`; Java class imports; module/class import phase versus function bodies.
- Explicit Java method/field usage and direct SDK calls, including BasePlugin instance calls.
- MethodHook subclasses, hook calls, literal target coverage, reflection and overload/member enumeration, dynamic proxies.
- Dynamic import/code/attribute constructs, FFI and known native packages, declared requirements, external processes, Android-specific overlay/VM/code-loading APIs.
- Simple assignment and return-type flow, argument shadowing, and conservative merging of conditional/loop aliases.

Each finding contains the AST line, one-based column, phase, category, API-like target, status, and a fixed explanation. No source excerpt, arbitrary call argument, URL, key value, exception text, or full input filename is copied to the report. Requirements that are URLs are reported as unresolved without printing their content. Metadata is restricted to bounded identity/version values; sensitive-looking values are redacted. A source SHA-256 identifies the exact inspected bytes.

## Limits and performance

This is an inventory aid, not a Python interpreter, security scanner, or proof of compatibility. It does not resolve imported plugin-local modules, arbitrary object types, inherited custom class behavior, decorators that execute bodies, monkey patches, interprocedural execution, or all Python dynamic constructs. Method bodies are conservatively inspected even if never called. Branches are not pruned. A function-call expression at module level can execute a user-defined function; the inspector does not infer that function's execution phase. Generator/lambda phase reporting is approximate. Syntax/runtime version and semantic correctness still need testing against the embedded interpreter.

The input read is bounded to 4 MiB plus one byte; ASTs above 100,000 nodes are rejected. Manifests are bounded to 1 MiB with member nesting capped. Analysis is scoped to one file; it does not recursively scan repositories, import libraries, or run network requests. No compiled dependencies, background tasks, or processes are started. Parser warnings are suppressed so source-derived warning text cannot escape through stderr.

The unit suite uses synthetic snippets, an explicit test-only manifest, and temporary reports. It tests non-execution, credential/source omission, alias/shadowing behavior, exact member matching, reflection/hook detection, native/dynamic requirements, bounds, status propagation and CLI output. Real plugins should also be inspected with the release bridge inventory, then validated in a separately controlled runtime harness.

## Corpus inventory and SDK comparison

```sh
python3 -B -m tools.plugin_inspector.corpus "$CORPUS_DIR" \
  --android-sdk "$ANDROID_SDK" --bridge-sdk submodules/AyuPluginBridge/Python \
  --rank-limit 50 --output /outside/input/directories/inventory.json
python3 -B -m tools.plugin_inspector.corpus "$CORPUS_DIR" --format markdown
```

The existing bridge audit entry point also accepts corpus mode with the same options:

```sh
python3 -B submodules/AyuPluginBridge/Build/audit-plugin-requirements.py \
  --corpus-dir "$CORPUS_DIR" --android-sdk "$ANDROID_SDK" \
  --bridge-sdk submodules/AyuPluginBridge/Python --rank-limit 50 --output inventory.json
```

Corpus mode inspects only immediate `.plugin`, `.elyx`, and `.eaf` files. ZIP Python source members are parsed in memory, independently; they are never extracted, imported, executed or resolved against one another. Bytecode, DEX, native binaries and assets are counted by payload kind. Their contents are not validated. Nested archives are not opened. Unsafe, encrypted and unreadable archive members remain explicit inventory issues. Corpus mode does not use the pinned 19-plugin manifest or import the bridge SDK.

Rankings include imports, imported SDK symbols, SDK calls, Java classes/members, features, lifecycle overrides, declared dependencies and native requirements. `files` measures attachment reach, including archives. `unique_sources` deduplicates exact source bytes and can exceed `files` when an archive contains several relevant modules. `occurrences` measures statically observed sites, including all branches; it is not an execution count. Family features may have several sites per class/import. Rankings sort by descending attachment reach, descending distinct source reach, then API name. Every ranking includes its full distinct-target count and explicit omitted-target count.

The optional SDK directories are read as declarations only, using bounded AST parsing. An API is `declared` only when its exact module or public symbol/member is found. `absent` means absent from the inspected declaration tree; it does not establish runtime unavailability, since inherited/dynamic/generated exports are not resolved. `not_compared` means no SDK directory was supplied. Imported names and guarded declarations are included conservatively. Wildcard re-exports union public declarations from files already inspected in the supplied SDK tree, with a 16-pass bound; `__all__` is not evaluated. The `android_declared_bridge_absent` ranking is computed over all observed SDK targets before truncation. Plugin-owned `self` helpers and assigned attributes are excluded from inherited SDK call requirements. Chaquopy's `java` APIs come from outside Android's Python SDK tree, so their `absent` Android declaration is expected.

Reports contain aggregate counts and bounded API identifiers, with fingerprints for the attachment multiset and SDK declarations. They omit attachment names, archive member names, input paths, identity metadata, arbitrary literals and source excerpts. JSON and Markdown use the same aggregate model. No compatibility or runtime success is inferred from declaration presence; `execution_verified` always remains false. The default support manifest remains unconfigured.

Bounds: 2,048 attachments, 8,192 immediate directory entries, 4 MiB per source, 100,000 AST nodes per source, 8,192 source units, 32 MiB compressed per archive, 4,096 members and 64 MiB declared expansion per archive, and 256 MiB total attachment/source reads. SDK traversal is confined to explicitly supplied directories, at most eight levels, 2,048 Python files and 256 MiB. Symlink inputs are rejected. ZIP64 counts beyond the member bound are rejected before central-directory allocation. Requirement targets are capped at 20,000 across all ranking families; output shows at most 200 per family (default 100). Outputs cannot overwrite input directories, manifests or hard-link aliases.

Exit 0 means a completed inventory with no source/archive errors; 2 means a rejected input/bound/output, or a completed inventory with explicit source/archive issues. Static unsupported/unknown findings alone still exit 0. The documented unit command also includes the corpus suite.

## Corpus preflight meter

```sh
python3 -X utf8 -B -m tools.plugin_inspector preflight-corpus --plugin-dir "$CORPUS_DIR" [--top 25] [--ids] [--json] [--output report]
python3 -X utf8 -B -m tools.plugin_inspector preflight-corpus --plugin-dir "$CORPUS_DIR" --capabilities capabilities.json
```

This mode measures what the bridge itself would decide. It imports the bridge SDK from `--bridge` (default `submodules/AyuPluginBridge`), which is repository code, and calls `Runtime.preflight_plugin_json` for every immediate `.plugin` file; nested directories are not read. Immediate `.elyx` and `.eaf` packages are counted separately with the bridge's `preflight_package_json`, which validates the archive and inventories its modules without unpacking or executing anything. Plugin source is parsed by that preflight and never imported or executed. A stand-in host answers only `runtime.capabilities`, so the SDK's own capability validation runs and Python-local classes (`_ayu_javalib`) count exactly as they do in a load.

Host capabilities are either an explicit `runtime.capabilities` JSON result (`--capabilities`, for example one captured from a device) or scraped from the Swift sources: operations from the `operations`/`capabilities` array literals, modules from `static let modules`, proxy interfaces from `static let proxyInterfaces`, and classes from every Java-class-shaped string literal in `Sources/` and `Integration/`. The scraped class set is an upper bound of the registered adapters, not a compiled registry. Adapters that a file's `enabled` filter leaves unregistered are removed from it. The class member table (`members`, see "Class members" in the bridge's `Python/protocol.md`) is scraped by `swift_members.py` from the `AyuBridgeClassAdapter(...)` literals: a class is listed only when every member argument resolves to a literal (inline, a `let` of the same member, or a `static let`), any other class has unknown members and produces no `MEMBER` blocker, and the built-in view classes get the union of all view methods (an upper bound). `Host member tables` in the report says how many classes fall in each group; `Member accesses` gives the corpus totals of accesses on a known receiver class and on an unknown one.

The report gives the pass, blocked and rejected counts, the number of plugins blocked per blocker kind (a plugin counts once per kind), plugins whose blockers are all of one kind, a histogram of distinct blockers per plugin, how many plugins declare each version/requirement key, and per kind the top `--top` blockers ranked by number of plugins, then by name. `rejected` means the SDK refused the source before preflight (invalid syntax, non-literal metadata, unreadable bytes). `--ids` adds the validated `__id__` of passing plugins. The `packages` section (JSON key `packages`) gives the number of packages, how many are inspectable (not rejected as archives or manifests), pass or are blocked, and their blockers per kind, including the package-only kind `PACKAGE`. Details that are not API-like identifiers are reported as `<unprintable>`; file names, paths and source text are omitted. A pass is the absence of static blockers, never runtime evidence. Exit 0 means a completed measurement, 2 an invalid directory, bridge, capability file, bound or output. A bridge SDK that fails to import, or that rejects the capabilities or one of its class providers, is reported on stderr by exception type and SDK message; that happens before any plugin is read.

The audit script's separate `--refresh-implementation-hashes --plugin-dir plugins` mode verifies the existing extended catalog against committed source provenance and exact local source bytes, then updates only implementation hashes. Add `--check-refresh` for a dry run. It never imports the SDK, changes plugin requirements or grants runtime support. Run it after implementation edits settle; see the [catalog refresh instructions](../../docs/plugins-corpus-compatibility.md#refreshing-the-extended-pinned-catalog). The documented test command includes synthetic hash/provenance regression tests.
