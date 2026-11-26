"""Validate UI artwork provenance, asset registration, role coverage and consumer hooks.

This is a host-side source/artifact check; it does not claim Swift execution or UI parity.
"""
import hashlib
import json
from pathlib import Path
import re
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'submodules/TelegramPresentationData/UIIconSources'
ASSETS = ROOT / 'submodules/TelegramUI/Images.xcassets'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    provenance = json.loads((SOURCES / 'provenance.json').read_text())
    inventory = json.loads((SOURCES / 'android-inventory.json').read_text())
    assert sha(SOURCES / 'android-inventory.json') == provenance['inventorySha256']
    for pack, aliases, artwork_aliases, vectors in [('solar', 631, 628, 496), ('remix', 634, 631, 497)]:
        value = inventory[pack]
        assert value['aliasCount'] == aliases == len(value['aliases'])
        assert value['packArtworkAliasCount'] == artwork_aliases
        assert value['uniqueVectorCount'] == vectors == len(set(b for b in value['aliases'].values() if b.endswith('_' + pack)))
    source = (ROOT / 'submodules/TelegramPresentationData/Sources/ExteraUIIconProvider.swift').read_text()
    roles = dict(re.findall(r'case \.(\w+): return "(\w+)"', source.split('public struct ExteraUIIconProvider')[0]))
    assert len(roles) >= 37
    records = provenance['records']
    assert len(records) == len(set(roles.values())) * 2
    assert len({r['asset'] for r in records}) == len(records)
    for record in records:
        assert sha(SOURCES / record['source']) == record['sha256']
        assert record['geometryMatchesAPK']
        pack = record['pack'].removeprefix('base.')
        for role in record['roles']:
            resource = roles[role]
            assert record['asset'] == f'ExteraUI_{pack}_{resource}'
            assert inventory[pack]['aliases'].get(resource, resource + '_' + pack) in inventory[pack]['aliases'].values()
        folder = ASSETS / (record['asset'] + '.imageset')
        contents = json.loads((folder / 'Contents.json').read_text())
        assert contents['properties']['template-rendering-intent'] == 'template'
        assert {i['scale'] for i in contents['images']} == {'1x', '2x', '3x'}
        for name, checksum in record['generated'].items():
            assert sha(folder / name) == checksum, folder / name
        for entry in contents['images']:
            with Image.open(folder / entry['filename']) as image:
                scale = int(entry['scale'][0])
                assert image.size == (24 * scale, 24 * scale)
                assert image.mode == 'RGBA'
                alpha = image.getchannel('A')
                assert alpha.getbbox() is not None
                minimum, maximum = alpha.getextrema()
                # Subpixel strokes at 1x need not contain a fully opaque pixel.
                assert minimum == 0 and maximum >= 128
    assert set(p.name for p in ASSETS.glob('ExteraUI_*.imageset')) == {r['asset'] + '.imageset' for r in records}
    for name, metadata in provenance['originals'].items():
        assert sha(SOURCES / name) == metadata['sha256']
    for name, metadata in json.loads((SOURCES / 'third-party-notices.json').read_text()).items():
        assert sha(SOURCES / name) == metadata['sha256']
    for path in ['Swiftgram/SGSimpleSettings/BUILD', 'Swiftgram/SGSettingsUI/BUILD', 'submodules/TelegramPresentationData/BUILD']:
        assert 'Sources/**/*.swift' in (ROOT / path).read_text()
    assert 'Images.xcassets/**' in (ROOT / 'submodules/TelegramUI/BUILD').read_text()
    menus = (ROOT / 'submodules/TelegramUI/Sources/ChatInterfaceStateContextMenus.swift').read_text()
    for role in ['copy', 'forward', 'reply', 'delete', 'edit', 'select', 'report', 'pin', 'unpin', 'link']:
        assert f'ExteraUIIconProvider.current.image(for: .{role}, fallback:' in menus
    for line in menus.splitlines():
        if re.search(r'UIImage\(bundleImageName: "Chat/Context Menu/(Copy|Forward|Reply|Delete|Edit|Select|Report|Pin|Unpin|Link)"', line):
            assert 'ExteraUIIconProvider.current.image' in line
    navigation = (ROOT / 'submodules/TelegramUI/Sources/ExteraRootTabController.swift').read_text()
    assert 'ExteraUIIconProvider.current.navigationImage(id: item.id' in navigation
    assert 'ExteraUIIconSettings.didChange' in navigation
    settings = (ROOT / 'submodules/TelegramPresentationData/Sources/Resources/PresentationResourcesSettings.swift').read_text()
    assert settings.count('public static var ') >= 12
    assert 'ExteraUIIconProvider.current.image(for: role)' in settings
    print(f'PASS: {len(roles)} roles, {len(records)} vector records, {len(records) * 3} PNG hashes/dimensions/alpha, catalog globs, notices, navigation/settings/message-menu consumers.')


if __name__ == '__main__':
    main()
