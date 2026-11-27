# Third-party Python packages for plugins

Android exteraGram pip-installs a plugin's `__requirements__` at run time and preinstalls a few packages
(`beautifulsoup4`, `debugpy`, `lxml`, `packaging`, `pillow`, `requests`, `pyyaml`). iOS cannot install or load code
at run time, so a package exists for plugins only if the app build ships it. This page records what is shipped, what
is not and why, and how the set is pinned. State as of 2026-11-26. Nothing here was built into an app or run on a
device.

## How packages are shipped

- `third-party/ayu-python/packages.lock.json` pins one artifact per distribution: file name, `files.pythonhosted.org`
  URL, SHA-256, version, the top-level modules it installs, its SPDX license, its license files and the pinned
  distributions it requires. No third-party source is committed to the repository.
- `repository.bzl` downloads each artifact with its checksum and leaves it packed. `prepare.py` (`install_packages`)
  checks the SHA-256 again and reads the archive as data: a `py3-none-any` wheel (`Root-Is-Purelib: true`), or for
  PyYAML the listed module directory of its source distribution. No `setup.py`, build backend or package code runs.
- It rejects, rather than skips, anything that is not pure Python (`.so`, `.dylib`, `.pyc`, Mach-O/ELF content), links,
  unsafe or unusual paths, a wheel whose metadata is not the pinned name and version, a runtime dependency the lock
  does not pin, top-level names other than the pinned modules, and any name already present in the library directory
  (so nothing can replace a standard-library module).
- Files go into `AyuPythonResources.bundle/python/lib/python3.15/`, next to the standard library, where `certifi`
  already was. The embedded interpreter is started with an explicit search path (that directory, `lib-dynload`, the
  SDK) and without `site`, so a separate `site-packages` directory would need a native change; this placement needs
  none. Each distribution keeps its `.dist-info/METADATA`, so `importlib.metadata.version()` works. License texts are
  copied to `AyuPythonResources.bundle/licenses/<distribution>-<file>`.
- `prepare.py` writes `AyuPythonResources.bundle/PYTHON_PACKAGES.json` (distribution, version, artifact SHA-256,
  modules, SHA-256 of every installed file). `verify_ipa.py` fails unless that manifest equals the lock and every
  listed file in the IPA has the listed hash, and rejects a `.dist-info` directory the manifest does not list.
- `certifi` moved from its own download step into the lock (same version, now the wheel instead of the sdist).
  `prepare.py` still requires `certifi/cacert.pem`, which the SDK's `requests` module uses.

A plugin can use a shipped package only when the Swift host also declares its modules in `runtime.capabilities`
(`modules` in `Sources/AyuPluginNativeHost.swift`). Imports of undeclared modules stay `DEPENDENCY` blockers. A
`__requirements__` entry is satisfied only when its distribution is in `PINNED_DISTRIBUTIONS`
(`Python/_ayu_policy.py`), the host declares its modules, and the pinned version meets every specifier, compared as
Android's `PipController.checkVersionSatisfies` does. A pin the bundled version cannot meet (`mutagen==1.47.0`)
stays a `REQUIREMENT` blocker. As on Android, specifiers of the preinstalled `beautifulsoup4`, `packaging` and
`pyyaml` are not evaluated. Tests keep the three lists equal: the lock, `PINNED_DISTRIBUTIONS`, and the Swift
`modules` literal (every declared module is an SDK file or a pinned module).

To add or update a package: add or edit its lock entry (URL and SHA-256 from PyPI's JSON for the exact file), the
`PINNED_DISTRIBUTIONS` entry and the Swift `modules` entry, then run the three test suites. Only pure-Python
distributions whose license can be combined with the GPL-2 application belong in the lock.

## Shipped

Corpus reach is the number of the 485 `.plugin` files that import the module / list the distribution in
`__requirements__`. All were unpacked by `install_packages` from the pinned artifacts and imported on macOS CPython
3.15.2 with `ctypes`, `subprocess` and `multiprocessing` imports refused; none imported them.

| Distribution | Version | Modules | License | Requires | Reach (import / requirement) | Installed size | Limits on iOS |
| --- | --- | --- | --- | --- | --- | --- | --- |
| mutagen | 1.48.1 | `mutagen` | GPL-2.0-or-later | none | 5 / 5 | 600 KiB | none known; satisfies `mutagen`, `==1.48.1`, `>=1.47,<2` |
| cachetools | 8.0.3 | `cachetools` | MIT | none | 2 / 2 | 73 KiB | none known |
| tinydb | 4.9.0 | `tinydb` | MIT | none | 2 / 2 | 77 KiB | none known |
| PyYAML | 6.0.4 | `yaml` | MIT | none | 3 / 0 | 216 KiB | pure-Python mode: `yaml.CLoader`, `CSafeLoader`, `CDumper` do not exist |
| beautifulsoup4 | 4.15.0 | `bs4` | MIT | soupsieve, typing-extensions | 2 / 0 | 395 KiB | only the `html.parser` builder; `lxml` and `html5lib` raise `FeatureNotFound` |
| soupsieve | 4.1.3 | `soupsieve` | MIT | none | dependency of bs4 | 214 KiB | none known |
| typing-extensions | 4.16.0 | `typing_extensions` | PSF-2.0 | none | 1 / 0, dependency of bs4 | 178 KiB | none known |
| packaging | 26.4 | `packaging` | Apache-2.0 OR BSD-2-Clause (used under BSD-2-Clause) | none | 2 / 0 | 519 KiB | `packaging.tags` imports `subprocess`; the corpus uses `packaging.version` only |
| humanize | 4.17.0 | `humanize` | MIT | none | 1 / 1 | 446 KiB | none known |
| certifi | 2026.11.20 | `certifi` | MPL-2.0 | none | 1 / 1 | 226 KiB | already shipped for the SDK's `requests`; now also declared to plugins |
| mpmath | 1.4.1 | `mpmath` | BSD-3-Clause | none | 1 / 1 | 2028 KiB (includes its tests) | pure-Python backend (no `gmpy2`) |
| urllib3 | 2.8.0 | `urllib3` | MIT | none | 4 / 0 | 437 KiB | independent of the SDK's `requests` subset, which has no adapters or retries; blocking sockets on the Python queue |

Total 5.3 MiB uncompressed, 409 files.

`yaml` is real PyYAML, not the SDK's `_ayu_yaml.py`. Android preinstalls PyYAML, so plugins expect its full API (the
corpus calls `safe_load`, `safe_dump`, `scan` and `yaml.tokens`), and a subset under the name `yaml` would fail
plugins in ways preflight cannot see. `_ayu_yaml.py` stays what it was written for: a bounded parser for untrusted
package manifests that are read before the user has trusted the package. It is not exposed as `yaml`.

## `audioop`

CPython removed the C module `audioop` in 3.13 and its PyPI replacement is a C extension. Six plugins import it, so
the SDK ships `Python/audioop.py`, a pure-Python port of exactly the eight functions the corpus calls: `ratecv`,
`tomono`, `tostereo`, `add`, `mul`, `max`, `rms`, `reverse`, for sample widths 1 to 4, with CPython 3.12's checks,
`audioop.error` messages, saturation and rounding. It is an SDK module (`SDK_MODULES`), not a pinned package. Every
other `audioop` function is absent: `audioop.lin2lin` is an `SDK_MEMBER` blocker and an `AttributeError`.

- Expected values come from the real module: `Build/generate_audioop_vectors.py` ran under CPython 3.12.16 (arm64)
  and wrote 3172 calls with their results or errors to `Tests/Python/audioop_golden.json`; CPython 3.9.6 gives the
  same values. `Tests/Python/test_deps_audioop.py` replays them.
- CPython's arm64 builds fuse the multiply and add in `tomono` and `rms` (one rounding); the port does the same
  with `math.fma`, or exact rational arithmetic before Python 3.13. Arithmetic without that fusion differed from
  the real arm64 module by one unit in 27 of 60,000 random calls.
- One call is limited to 16 MiB of input and of output (`RESOURCE_LIMIT`), because it runs to completion on the
  serial Python queue. It is far slower than the C module; speed on a device was not measured.

## Not shipped

| Name | Reach (import / requirement) | Reason |
| --- | --- | --- |
| Pillow (`PIL`) | 17 / 0 | C extension; needs signed frameworks. Usage is listed below. |
| websocket-client 1.9.2 (`websocket`) | 2 / 2 | Pure Python, no dependencies, imports on 3.15, but Apache-2.0 only, which cannot be combined with GPL-2.0-only code. Owner decision: it is acceptable only if the app is distributed under GPL-3 terms. (Apache-2.0 code is already in the tree: the hls.js port noted in `docs/native-hls-player.md`.) |
| yt-dlp 2026.11.23 (`yt_dlp`) | 2 / 2 | Unlicense and pure Python, but 10.2 MiB; it imports `subprocess` when imported, merges formats through an ffmpeg process and solves YouTube challenges through an external JavaScript runtime, none of which iOS allows. Extractors go stale within weeks while the app can only ship a pinned copy, and one plugin pins `==2026.8.19`. |
| yt-dlp-ejs | 0 / 1 | Only useful with yt-dlp and an external JavaScript runtime. |
| yandex-music 3.2.2 | 1 / 1 | LGPL-3.0-only, which cannot be combined with GPL-2.0-only code; requires upstream `requests[socks]`, not the SDK's subset. |
| PySocks 1.7.1 (`socks`) | 0 / 1 | BSD-3-Clause and feasible, but its only consumer also needs yt-dlp and yandex-music, so shipping it unblocks nothing. |
| Babel 2.19.0 | 1 / 1 | BSD-3-Clause and pure Python, but 32 MiB unpacked (locale data) for one call, `Locale("ru").territories`. |
| debugpy 1.8.22 | 2 / 0 | Android-preinstalled remote debugger; its wheel carries native attach helpers (`.dylib`, `.so`, `.dll`, `.exe`), 27 MiB unpacked. |
| lxml | 0 / 0 | Android-preinstalled C extension. |
| nowfy 1.4.66 | 1 / 1 | On PyPI without any license, 14 MiB unpacked. It is the plugin's own implementation (the `.plugin` file is a stub that imports `nowfy.plugin`): Android code using `java`, `android`, `org.telegram` and `hook_utils`, and it requires yt-dlp, ytmusicapi and musicbrainzngs. Shipping it would run plugin code that preflight never inspected. |
| exteragram-alib 1.0.6 (`alib`) | 1 / 1 | MIT, on PyPI, but it is an Android plugin library (imports `android.*`, `org.telegram.*`, `android_utils`, `hook_utils`, `client_utils`), not a general package. It would have to pass the same class and operation preflight as plugin code; bundling it as a dependency would bypass that. |

Names that are not PyPI packages:

- `plugins_manager` (2 plugins: `plugins_manager.PluginsManager._plugins`, `._plugins_dir`): a module of an older
  exteraGram Python SDK. It does not exist in plugin SDK 1.4.6.5 at exteraGram b4d852f, so these imports fail on
  current Android too.
- `quantahut` (2), `lyrics` (1), `cactuslib` (1): other plugins, imported by their `__id__`. Android registers each
  loaded plugin as a module of that name. The corpus contains `QuantaHut.plugin` and `lyrics.plugin`; CactusLib itself
  is not in the corpus (`cactusLibMini.plugin` has the id `cactuslib_mini`). Supporting this is a bridge feature
  (cross-plugin imports with load ordering), not packaging.

## Binary modules the corpus uses

Measured with `ast` only; method names on values are found by following assignments from PIL calls, so a few counts
are approximate.

PIL, 17 plugins (8 guard the import):

- Modules: `Image` 17, `ImageDraw` 8, `ImageFilter` 8, `ImageFont` 7, `ImageOps` 5, `ImageChops` 2, `ImageEnhance` 2,
  `ImageColor` 1, `ImageSequence` 1.
- `Image`: `open` 17, `new` 10, `alpha_composite` 3, `composite` 2, `blend` 1, `merge` 1, `radial_gradient` 1;
  `Resampling.LANCZOS`/`LANCZOS` 10, `BICUBIC` 3, `NEAREST` 2, `BILINEAR` 1, `ADAPTIVE` 2, `Transform.AFFINE` 1.
- Image methods: `convert` 17 (modes RGB, RGBA, P, L), `save` 15 (JPEG 11, PNG 3, WEBP 1; `quality`, `optimize`,
  `subsampling`, `method`), `resize` 12, `paste` 10, `filter` 7, `load` 4, `copy` 3, `crop` 3, `putalpha` 3,
  `thumbnail` 3, `split` 2, `getdata` 2, `putdata` 2, `getbbox` 2, `getcolors` 2, `getpalette` 2, `rotate` 1,
  `transform` 1, `point` 1, `quantize` 1, `getchannel` 1, `getexif` 1, `draft` 1, `verify` 1; attributes `size` 11,
  `mode` 7, `width`, `height`, `format`, `info`.
- `ImageDraw.Draw` 8: `text` 7, `textbbox` 4, `line` 4, `ellipse` 3, `rounded_rectangle` 3, `rectangle` 2,
  `textlength` 2, `multiline_textbbox` 1, `textsize` 1.
- `ImageFont`: `truetype` 7, `load_default` 6; font `getbbox`, `getlength`, `getmask`, `getname`,
  `set_variation_by_name`.
- `ImageFilter`: `GaussianBlur` 4, `CONTOUR` 3, `EMBOSS` 3, `DETAIL` 2, `EDGE_ENHANCE_MORE` 2, `FIND_EDGES` 2,
  `SHARPEN` 2, `SMOOTH_MORE` 2, `SMOOTH` 1, `MaxFilter` 1, `MedianFilter` 1, `UnsharpMask` 1.
- `ImageOps`: `colorize` 3, `fit` 3, `grayscale` 3, `invert` 3, `posterize` 2, `solarize` 2, `autocontrast` 1,
  `exif_transpose` 1, `flip` 1, `mirror` 1. `ImageEnhance`: `Contrast` 2, `Brightness`, `Color`, `Sharpness`.
  `ImageChops`: `difference`, `multiply`, `offset`, `subtract`. `ImageColor.getcolor`, `ImageSequence.Iterator`.

`audioop`, 6 plugins (4 guard the import), always 16-bit PCM (`width` 2): `ratecv`, `tomono`, `tostereo`, `add`,
`mul`, `max`, `rms`, `reverse`. These are the functions the SDK module above provides.

## Measurements

Corpus meter (`python3 -X utf8 -B -m tools.plugin_inspector preflight-corpus --plugin-dir plugins --top 40`), plugins
blocked per kind before and after:

| | Before | After |
| --- | --- | --- |
| `DEPENDENCY` | 47 plugins, 40 distinct | 37 plugins, 18 distinct; 31 plugins, 17 distinct with `audioop` |
| `REQUIREMENT` | 14 plugins, 14 distinct | 7 plugins, 8 distinct |
| Pass, today's host | 9 | 9 |
| Pass, host with the 19 operations of `protocol-telegram.md` | 47 | 48 from this change alone (`genius_lyrics.plugin`) |

Ten plugins lost all their `DEPENDENCY` and `REQUIREMENT` blockers. On today's host all ten are still blocked by
classes or operations; one passes on a host with the 19 operations. Packages are not what keeps plugins from
passing. The remaining `DEPENDENCY` blockers are `PIL` 17 and the names in the tables above.

Submodules of a bundled shim. `requests` is one SDK source file that the host declares, not a package. Importing a
submodule it does not publish (`from requests.adapters import HTTPAdapter`), importing a name it lacks, or reading a
missing name as a namespace (`requests.utils.quote(...)`) is now an `SDK_MEMBER` blocker, unless the import sits in a
`try` that absorbs `ImportError` or the access in one that names `AttributeError`. Six plugins gained such a blocker
(`requests.utils` 4, `requests.adapters` 2). None changes status on today's host; on a host with the 19 operations
two that passed are now blocked (`anixart_plugin`, `genius_lyrics`), both by `requests.utils.quote`. A plain missing
member (`requests.not_supported()`) is still not reported.

## Not verified

- The Bazel repository rule was edited but never run: the downloads through `ctx.download`, and the resource bundle
  with the new files, are untested. The same `install_packages` code was run by hand on the real pinned artifacts.
- The packages were imported on macOS CPython 3.15.2, not on the BeeWare iOS runtime (3.15-b3). Nothing proves they
  import or work on a device, and network packages (`urllib3`) block the Python queue like any socket use.
- Preflight accepts any submodule of a declared top-level module, so `import yaml.missing` passes statically and
  fails at import.
