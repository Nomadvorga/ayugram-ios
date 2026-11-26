"""Syntax and algebraic checks only. Swift/UIKit/XCTest execution is separate.

Usage: python validate_style_static.py [--tree-sitter-dir PATH]
Requires tree_sitter and tree_sitter_swift; no packages are downloaded here.
"""
import argparse
from itertools import product
from math import ceil, floor
import json
from pathlib import Path
import re
import subprocess
import sys

arguments = argparse.ArgumentParser()
arguments.add_argument('--tree-sitter-dir', type=Path)
options = arguments.parse_args()
if options.tree_sitter_dir:
    sys.path.insert(0, str(options.tree_sitter_dir))
from tree_sitter import Language, Parser
import tree_sitter_swift

module = Path(__file__).resolve().parents[1]
settings = module.parent / 'SGSimpleSettings'
repo = module.parents[1]
manifest = json.loads((module / 'integration/owned-files.json').read_text(encoding='utf-8'))
sources = sorted((module / 'Sources').glob('*.swift'))
sources += sorted((module / 'Tests').glob('*.swift'))
sources += [settings / 'Sources/ExteraStyleSettings.swift', settings / 'Tests/ExteraStyleSettingsTests.swift']
sources = sorted(set(sources) | {repo / path for path in manifest['swiftSources']})
parser = Parser(Language(tree_sitter_swift.language()))
for source in sources:
    pending = [parser.parse(source.read_bytes()).root_node]
    while pending:
        node = pending.pop()
        assert node.type != 'ERROR' and not node.is_missing, (source, node.start_point)
        pending.extend(node.children)
    assert source.read_bytes().endswith(b'\n'), source
print(f'PASS: {len(sources)} scoped production/test Swift sources parse')
assert len(set(manifest['swiftSources'])) == len(manifest['swiftSources'])
for path in manifest['swiftSources'] + manifest['supportFiles']:
    assert (repo / path).is_file(), path
strings = json.loads((module / 'integration/style-strings.json').read_text(encoding='utf-8'))
assert all(set(value) == {'en', 'ru'} and all(value.values()) for value in strings.values())
assert all(strings['Extera.Style.PointUnit'][locale].startswith(' ') for locale in ('en', 'ru'))
print(f'PASS: {len(manifest["swiftSources"])} owned Swift files + {len(manifest["supportFiles"])} support files, {len(strings)} en/ru localization pairs')

tile_checks = 0
for width in (88, 96, 128, 192, 248, 320, 358, 398, 560, 736):
    inset = min(22, max(0, (width - 100) / 2))
    gap = min(18, max(0, width - 88 - 2 * inset))
    tile_width = max(0, (width - 2 * inset - gap) / 2)
    tile_height = max(64, min(88, tile_width * .5))
    assert tile_width >= 44 and tile_height >= 44
    for index in (0, 1):
        x = inset + index * (tile_width + gap)
        assert x >= 0 and x + tile_width <= width
        scale = min(tile_width / 160, tile_height / 80)
        assert 105 * scale <= tile_width and 71 * scale <= tile_height
        compose = (tile_width - 43 * scale, tile_height - 43 * scale, 33 * scale)
        assert min(compose) >= 0
        assert compose[0] + compose[2] <= tile_width and compose[1] + compose[2] <= tile_height
        tile_checks += 1
print(f'PASS: {tile_checks} style tile/vector bounds, >=44pt touch width')

track_checks = 0
for card_width, base, line_factor, fraction in product(
    (128, 192, 248, 320, 398, 560, 736), (14, 17, 22, 28, 40), (1.1, 1.25, 1.5), (0, .01, .25, .5, .75, .99, 1)
):
    width = card_width - 44
    column = width / 3
    label_height = ceil(base * .82 * line_factor * 2)
    height = max(80, 16 + label_height + 45)
    y = 16 + label_height + 18
    inset = min(6, width / 2)
    x = inset + (width - 2 * inset) * fraction
    assert 0 <= x - 6 and x + 6 <= width
    assert 16 + label_height <= y - 13 and y + 13 <= height
    for index in range(3):
        assert index * column >= 0 and index * column + max(0, column - 2) <= width
    assert abs((x - inset) / (width - 2 * inset) - fraction) < 1e-9
    track_checks += 1
print(f'PASS: {track_checks} numeric track/marker/large-font label bounds and position round trips')

normalization_checks = 0
for lower, upper, step in ((0, 64, 1), (-10, 20, 7), (0, 100, 7), (9, 9, 1), (0, 64, 0), (0, 64, -1), (-2147483648, 2147483647, 2147483647)):
    stride = max(1, step)
    def normalize(value):
        clamped = max(lower, min(upper, value))
        if clamped == upper:
            return upper
        return min(upper, lower + floor((clamped - lower) / stride + .5) * stride)
    previous = None
    for raw in sorted({lower - 1, upper + 1, lower, upper, 0, -9223372036854775808, 9223372036854775807} | set(range(-128, 129))):
        result = normalize(raw)
        assert lower <= result <= upper
        assert normalize(result) == result
        assert previous is None or result >= previous
        previous = result
        normalization_checks += 1
print(f'PASS: {normalization_checks} range boundary/idempotence/monotonicity checks (algebraic)')

for enabled, native, energy, theme, force, reduce_transparency in product((False, True), repeat=6):
    effective = enabled and native and energy and (theme or force) and not reduce_transparency
    if not enabled or not native or not energy or reduce_transparency:
        assert not effective
    elif theme or force:
        assert effective
print('PASS: 64-case style/native/energy/theme/force/accessibility truth table (algebraic)')

# Evaluate the actual scalar Swift conditions, not a second handwritten policy.
# This intentionally supports only these boolean operators and named inputs.
def swift_boolean(expression, inputs):
    for name, value in sorted(inputs.items(), key=lambda item: -len(item[0])):
        expression = expression.replace(name, repr(value))
    expression = expression.replace('&&', ' and ').replace('||', ' or ').replace('!', ' not ')
    return bool(eval(expression, {'__builtins__': {}}, {}))

backgrounds = (repo / 'submodules/Display/Source/NavigationBackgroundView.swift').read_text(encoding='utf-8')
conditions = re.findall(r'if (?:let color = self\._color, )?(self\.enableBlur && .+) \{', backgrounds)
assert len(conditions) == 2
consumer_checks = 0
for condition in conditions:
    for native, style, energy, reduce, force, keep in product((False, True), repeat=6):
        for alpha in (0.0, 0.5, 1.0):
            result = swift_boolean(condition, {
                'self.enableBlur': native, 'self.exteraStyleAllowsBlur': style,
                'ExteraEnergyRuntime.allows(.blur)': energy,
                'sharedIsReduceTransparencyEnabled': reduce,
                'ExteraStyleSettings.shared.forceBlur': force, 'forceKeepBlur': keep,
                'self._color.alpha': alpha, 'color.alpha': alpha, '.ulpOfOne': 2.220446049250313e-16
            })
            assert result == (native and style and energy and not reduce and (0 < alpha < .95 or force or keep))
            consumer_checks += 1
glass_source = (repo / 'submodules/TelegramUI/Components/GlassBackgroundComponent/Sources/GlassBackgroundComponent.swift').read_text(encoding='utf-8')
style_condition = re.search(r'let styleAllowsGlass = (.+)', glass_source).group(1)
glass_condition = re.search(r'let glassAllowed = (.+)', glass_source).group(1)
for marked, setting, blur, glass in product((False, True), repeat=4):
    style = swift_boolean(style_condition, {'self.exteraStyleIsMessageMenu': marked, 'ExteraStyleSettings.shared.glassMessageMenu': setting})
    result = swift_boolean(glass_condition, {'styleAllowsGlass': style, 'ExteraEnergyRuntime.allows(.blur)': blur, 'ExteraEnergyRuntime.allows(.liquidGlass)': glass})
    assert result == ((not marked or setting) and blur and glass)
    consumer_checks += 1
print(f'PASS: {consumer_checks} actual shared-consumer boolean conditions preserve native/style/energy ceilings')

for path in (
    'Swiftgram/SGSimpleSettings/Sources/ExteraEnergySettings.swift',
    'Swiftgram/SGSimpleSettings/Sources/ExteraEnergyRuntime.swift',
    'submodules/TelegramPresentationData/Sources/ExteraEnergyPolicy.swift',
    'submodules/TelegramPresentationData/Sources/PresentationData.swift',
    'submodules/Display/Source/NavigationExpansion.swift'
):
    baseline = subprocess.run(['git', 'show', manifest['baseline'] + ':' + path], cwd=repo, capture_output=True, check=True).stdout
    assert baseline.replace(b'\r\n', b'\n') == (repo / path).read_bytes().replace(b'\r\n', b'\n'), path
print('PASS: energy model/runtime, PresentationData policy/resolver and NavigationExpansion unchanged from checkpoint')
subprocess.run(['git', 'diff', '--check', '--'] + manifest['swiftSources'] + manifest['supportFiles'], cwd=repo, check=True)
for path in manifest['swiftSources'] + manifest['supportFiles']:
    tracked = subprocess.run(['git', 'ls-files', '--error-unmatch', '--', path], cwd=repo, capture_output=True).returncode == 0
    if not tracked:
        assert all(line.rstrip(b' \t') == line for line in (repo / path).read_bytes().splitlines()), path
print('PASS: scoped git diff --check and whitespace of new files')
print('Limits: no Swift typecheck, UIKit font metrics, XCTest execution or runtime/frame evidence.')
