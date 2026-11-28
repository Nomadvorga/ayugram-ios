"""Validate icon registration, original/derived hashes, dimensions and legacy identity.

Run with Pillow installed: py tools/check_extera_app_icons.py
This checks repository data, not the final actool/IPA output or UIApplication behavior.
"""
from pathlib import Path
import hashlib
import json
import plistlib
import re
import subprocess

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
ICONS = ROOT / 'Telegram/Telegram-iOS'
catalog = json.loads((ICONS / 'Resources/ExteraAppIconCatalog.json').read_text(encoding='utf-8'))
provenance = json.loads((ICONS / 'AppIconSources/provenance.json').read_text(encoding='utf-8'))
names = [item['name'] for item in catalog]
assert len(names) == len(set(names)) == 42
assert sum(item['family'] == 'ayu' for item in catalog) == 10
assert sum(item['family'] == 'extera' for item in catalog) == 32
assert names[0] == 'SGDefault'
assert next(item for item in catalog if item['name'] == 'ExteraAmethyst')['description'] == 'Perfectly balanced'
assert {item['androidId'] for item in catalog} >= {
    'default', 'monet', 'ayugram_alt', 'ayugram_discord', 'ayugram_spotify', 'ayugram_extera',
    'ayugram_nothing', 'ayugram_bard', 'ayugram_yaplus', 'ayutyan',
    'extera', 'monet_extera', 'orbit', 'editor', 'mole', 'echpochmak', 'avatar', 'candy',
    'guitar', 'sus', 'frog', 'hamster', 'sponge', 'invincible', 'flappy', 'nyan_cat',
    'ice_age', 'fish', 'psychosis', 'xp', 'nasa', 'cyberpunk', 'space', 'jellyfish', 'human',
    'sunset', 'amethyst', 'aurora', 'osu', 'google', 'google26',
}
build = (ROOT / 'Telegram/BUILD').read_text(encoding='utf-8')
registered = re.search(r'alternate_icon_folders = \[(.*?)\]', build, re.S).group(1)
assert set(re.findall(r'"([^"]+)"', registered)) == set(names)
for plist_name in ['AlternateIcons.plist', 'AlternateIcons-iPad.plist']:
    fragment = (ICONS / plist_name).read_bytes()
    entries = plistlib.loads(b'<?xml version="1.0"?><plist version="1.0">' + fragment + b'</plist>')
    assert set(names) <= entries.keys(), plist_name
    previous = subprocess.check_output(['git', 'show', f'HEAD:Telegram/Telegram-iOS/{plist_name}'], cwd=ROOT)
    previous_entries = plistlib.loads(b'<?xml version="1.0"?><plist version="1.0">' + previous + b'</plist>')
    assert all(entries.get(key) == value for key, value in previous_entries.items()), 'Legacy plist entry changed'
    for name in names:
        for icon_file in entries[name]['CFBundleIconFiles']:
            assert any((ICONS / (name + '.alticon')).glob(icon_file + '*.png')), (name, icon_file)
for name, source in provenance['sources'].items():
    assert hashlib.sha256((ICONS / 'AppIconSources' / name).read_bytes()).hexdigest() == source['sha256'], name
for name, digest in provenance['notices'].items():
    assert hashlib.sha256((ICONS / 'AppIconSources' / name).read_bytes()).hexdigest() == digest, name
count = 0
for name, outputs in provenance['generated'].items():
    folder = ICONS / (name + '.alticon')
    assert (folder / (next(item for item in catalog if item['name'] == name)['imageName'] + '.png')).is_file()
    assert {120, 152, 167, 180, 1024} <= {int(m.group(1)) for f in outputs if (m := re.search(r'_(\d+)x\d+.png', f))}
    for filename, digest in outputs.items():
        path = folder / filename
        assert hashlib.sha256(path.read_bytes()).hexdigest() == digest, path
        with Image.open(path) as image:
            match = re.search(r'_(\d+)x\d+.png', filename)
            expected = int(match.group(1)) if match else (120 if '@2x' in filename else 180)
            assert image.size == (expected, expected), path
            assert image.mode == 'RGB', path
        count += 1
for scale in [2, 3]:
    relative = f'Telegram/Telegram-iOS/SGDefault.alticon/SGDefault@{scale}x.png'
    previous = subprocess.check_output(['git', 'show', f'HEAD:{relative}'], cwd=ROOT)
    assert (ROOT / relative).read_bytes() == previous, 'Shipped SGDefault bytes changed'
for asset, item in provenance['overview'].items():
    path = ROOT / 'AyuGram/SGSettingsUI/Images.xcassets' / (asset + '.imageset')
    assert hashlib.sha256((path / (asset + '.png')).read_bytes()).hexdigest() == item['sha256']
    assert (path / (asset + '.png')).read_bytes() == (ROOT / item['source']).read_bytes()
    metadata = json.loads((path / 'Contents.json').read_text())
    assert metadata['images'][0]['filename'] == asset + '.png'
delegate_path = 'submodules/TelegramUI/Sources/AppDelegate.swift'
delegate = (ROOT / delegate_path).read_text(encoding='utf-8')
previous_delegate = subprocess.check_output(['git', 'show', f'HEAD:{delegate_path}'], cwd=ROOT).decode()
callback = r'\}, requestSetAlternateIconName: \{ name, completion in(.*?)\}, forceOrientation:'
assert re.search(callback, delegate, re.S).group(1) == re.search(callback, previous_delegate, re.S).group(1)
assert 'application.setAlternateIconName(name, completionHandler:' in delegate
print(f'PASS: {len(names)} icons, {count} generated PNG hashes/dimensions, 2 overview assets, both plist fragments, BUILD registry, original SGDefault bytes and native completion chain.')
