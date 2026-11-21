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

The input read is bounded to 2 MiB plus one byte; ASTs above 100,000 nodes are rejected. Manifests are bounded to 1 MiB with member nesting capped. Analysis is scoped to one file; it does not recursively scan repositories, import libraries, or run network requests. No compiled dependencies, background tasks, or processes are started.

The unit suite uses synthetic snippets, an explicit test-only manifest, and temporary reports. It tests non-execution, credential/source omission, alias/shadowing behavior, exact member matching, reflection/hook detection, native/dynamic requirements, bounds, status propagation and CLI output. Real plugins should also be inspected with the release bridge inventory, then validated in a separately controlled runtime harness.
