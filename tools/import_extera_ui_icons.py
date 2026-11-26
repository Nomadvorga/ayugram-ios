"""Import verified built-in Android UI vectors. Requires @resvg/resvg-js 2.6.2.

Only writes UIIconSources and ExteraUI_*.imageset, independently of launcher icons.
The role table in ExteraUIIconProvider.swift is the iOS coverage authority.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'submodules/TelegramPresentationData/UIIconSources'
ASSETS = ROOT / 'submodules/TelegramUI/Images.xcassets'
REVISION = 'b4d852f48f2734a0bee1a74a0939be621612262a'
APK_SHA256 = 'b7195bd9f3126543566acf3e1e5d3d1cc1fa163db927e85918877f7cb65cb113'
ANDROID = '{http://schemas.android.com/apk/res/android}'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def vector_svg(data):
    root = ET.fromstring(data)
    assert root.tag == 'vector'
    width = root.attrib[ANDROID + 'viewportWidth']
    height = root.attrib[ANDROID + 'viewportHeight']
    svg = ET.Element('svg', xmlns='http://www.w3.org/2000/svg', viewBox=f'0 0 {width} {height}', width='24', height='24')
    def append(parent, child):
        attrs = {key.removeprefix(ANDROID): value for key, value in child.attrib.items()}
        if child.tag == 'group':
            assert not attrs, f'Unsupported transformed group: {attrs}'
            group = ET.SubElement(parent, 'g')
            for element in child:
                append(group, element)
            return
        assert child.tag == 'path', f'Unsupported vector element: {child.tag}'
        assert set(attrs) <= {'fillColor', 'pathData', 'fillType', 'fillAlpha', 'strokeColor', 'strokeWidth', 'strokeLineCap', 'strokeLineJoin', 'strokeAlpha'}, attrs
        for color_key in ['fillColor', 'strokeColor']:
            if color_key in attrs:
                assert re.fullmatch(r'#[fF]{6,8}', attrs[color_key]), attrs[color_key]
        values = {'d': attrs['pathData'], 'fill': '#ffffff' if 'fillColor' in attrs else 'none',
                  'fill-rule': 'evenodd' if attrs.get('fillType') == 'evenOdd' else 'nonzero',
                  'fill-opacity': attrs.get('fillAlpha', '1')}
        if 'strokeColor' in attrs:
            values.update({'stroke': '#ffffff', 'stroke-width': attrs['strokeWidth'],
                           'stroke-linecap': attrs.get('strokeLineCap', 'butt'),
                           'stroke-linejoin': attrs.get('strokeLineJoin', 'miter'),
                           'stroke-opacity': attrs.get('strokeAlpha', '1')})
        ET.SubElement(parent, 'path', **values)
    for child in root:
        append(svg, child)
    return ET.tostring(svg, encoding='utf-8')


def geometry(data):
    root = ET.fromstring(data)
    return [(e.tag, sorted((k, v.lower() if k.endswith('Color') else v) for k, v in e.attrib.items())) for e in root.iter()]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--android', type=Path, required=True)
    parser.add_argument('--apk', type=Path, required=True)
    parser.add_argument('--extera', type=Path, required=True)
    parser.add_argument('--renderer', type=Path, required=True)
    args = parser.parse_args()
    assert sha(args.apk.read_bytes()) == APK_SHA256
    renderer_package = json.loads((args.renderer / 'package.json').read_text())
    assert renderer_package['version'] == '2.6.2'
    SOURCES.mkdir(parents=True, exist_ok=True)

    def git(path):
        return subprocess.check_output(['git', 'show', f'{REVISION}:{path}'], cwd=args.extera)

    originals = {}
    for name in ['LICENSE', 'ADDITIONAL_TERMS.md']:
        data = git(name)
        (SOURCES / name).write_bytes(data)
        originals[name] = {'gitPath': name, 'sha256': sha(data)}
    upstream = 'TMessagesProj/src/main/java/com/exteragram/messenger/icons/BaseIconPacks.kt'
    data = git(upstream)
    (SOURCES / 'BaseIconPacks.kt').write_bytes(data)
    originals['BaseIconPacks.kt'] = {'gitPath': upstream, 'sha256': sha(data)}
    java = (args.android / 'sources/com/exteragram/messenger/icons/BaseIconPacks.java').read_bytes()
    role_source = (ROOT / 'submodules/TelegramPresentationData/Sources/ExteraUIIconProvider.swift').read_text()
    roles = dict(re.findall(r'case \.(\w+): return "(\w+)"', role_source.split('public struct ExteraUIIconProvider')[0]))
    records = []
    inventory = {}
    jobs = []
    for pack in ['solar', 'remix']:
        body = re.search(r'public static final SparseIntArray ' + pack + r'_delegate\$lambda\$\d+\(\) \{(.*?)return sparseIntArray;', java.decode(), re.S).group(1)
        pairs = re.findall(r'sparseIntArray.put\(C2294R.drawable.(\w+), C2294R.drawable.(\w+)\)', body)
        pack_pairs = [(a, b) for a, b in pairs if b.endswith('_' + pack)]
        inventory[pack] = {'aliasCount': len(pairs), 'uniqueTargetCount': len(set(b for a, b in pairs)),
                           'packArtworkAliasCount': len(pack_pairs), 'uniqueVectorCount': len(set(b for a, b in pack_pairs)),
                           'aliases': dict(pairs)}
        for resource in sorted(set(roles.values())):
            android_name = inventory[pack]['aliases'].get(resource, resource + '_' + pack)
            assert android_name in inventory[pack]['aliases'].values(), android_name
            git_path = f'TMessagesProj/src/main/res-{pack}/drawable/{android_name}.xml'
            data = git(git_path)
            decoded_path = f'resources/res/drawable/{android_name}.xml'
            decoded = (args.android / decoded_path).read_bytes()
            assert geometry(data) == geometry(decoded), f'APK/upstream geometry differs: {android_name}'
            source_name = android_name + '.xml'
            (SOURCES / source_name).write_bytes(data)
            svg = vector_svg(data)
            asset = 'ExteraUI_' + pack + '_' + resource
            folder = ASSETS / (asset + '.imageset')
            folder.mkdir(parents=True, exist_ok=True)
            images = []
            for scale in [1, 2, 3]:
                filename = f'icon@{scale}x.png'
                jobs.append({'svg': svg.decode(), 'size': 24 * scale, 'path': str(folder / filename)})
                images.append({'idiom': 'universal', 'filename': filename, 'scale': f'{scale}x'})
            write_json(folder / 'Contents.json', {'images': images, 'info': {'author': 'xcode', 'version': 1}, 'properties': {'template-rendering-intent': 'template'}})
            records.append({'pack': 'base.' + pack, 'roles': [k for k, v in roles.items() if v == resource],
                            'asset': asset, 'source': source_name, 'sha256': sha(data), 'gitPath': git_path,
                            'apkDecodedPath': decoded_path, 'apkDecodedSha256': sha(decoded),
                            'geometryMatchesAPK': True})
    script = """
const fs = require('fs');
const {Resvg} = require(process.argv[1]);
const jobs = JSON.parse(fs.readFileSync(0, 'utf8'));
for (const job of jobs) {
  const png = new Resvg(job.svg, {fitTo: {mode: 'width', value: job.size}}).render().asPng();
  fs.writeFileSync(job.path, png);
}
"""
    subprocess.run(['node', '-e', script, str(args.renderer)], input=json.dumps(jobs), text=True, check=True)
    for record in records:
        folder = ASSETS / (record['asset'] + '.imageset')
        record['generated'] = {p.name: sha(p.read_bytes()) for p in sorted(folder.iterdir())}
    write_json(SOURCES / 'android-inventory.json', inventory)
    write_json(SOURCES / 'provenance.json', {'apkSha256': APK_SHA256, 'upstreamRevision': REVISION,
               'baseIconPacksJavaSha256': sha(java), 'renderer': '@resvg/resvg-js@2.6.2',
               'inventorySha256': sha((SOURCES / 'android-inventory.json').read_bytes()),
               'originals': originals, 'records': records})
    print(f'Imported {len(records)} verified vectors / {len(jobs)} PNGs for {len(roles)} semantic roles.')


if __name__ == '__main__':
    main()
