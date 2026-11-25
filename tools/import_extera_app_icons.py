"""Import real Android launcher layers and render the iOS alternate icons.

Requires Pillow and @resvg/resvg-js 2.6.2 (installed outside the repository).
See docs/extera-app-icon-picker.md for provenance, license notices and invocation.
No artwork is synthesized. Android's 108 -> 72 adaptive-icon viewport is retained.
"""
from pathlib import Path
import argparse
import colorsys
import hashlib
import io
import json
import re
import subprocess
import xml.etree.ElementTree as ET
import zipfile
import zlib

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / 'Telegram/Telegram-iOS'
SOURCES = DEST / 'AppIconSources'
EXTERA_REVISION = 'b4d852f48f2734a0bee1a74a0939be621612262a'
AYU_REVISION = '7013145676d36d82ee13c02a89f72097b7490dcd'
APK_SHA256 = 'b7195bd9f3126543566acf3e1e5d3d1cc1fa163db927e85918877f7cb65cb113'
ANDROID = '{http://schemas.android.com/apk/res/android}'
SIZES = [20, 29, 40, 58, 60, 76, 80, 87, 120, 152, 167, 180, 1024]
NAMES = {
    'default': 'SGDefault', 'monet': 'AyuMonet', 'ayugram_alt': 'AyuAlt',
    'ayugram_discord': 'AyuDiscord', 'ayugram_spotify': 'AyuSpotify',
    'ayugram_extera': 'AyuExtera', 'ayugram_nothing': 'AyuNothing',
    'ayugram_bard': 'AyuBard', 'ayugram_yaplus': 'AyuYandexPlus', 'ayutyan': 'AyuTyan',
    'extera': 'ExteraDefault', 'monet_extera': 'ExteraMonet',
}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def git(repo, path):
    return subprocess.check_output(['git', 'show', f'{EXTERA_REVISION}:{path}'], cwd=repo)


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def vector_svg(data):
    root = ET.fromstring(data)
    svg = ET.Element('svg', xmlns='http://www.w3.org/2000/svg', viewBox='0 0 108 108', width='108', height='108')
    for child in root.iter('path'):
        fill = child.attrib[ANDROID + 'fillColor']
        if fill == '@color/ic_foreground_monet':
            fill = '#C2E8FF'  # Exact dominant foreground in reference frame 24, dark Monet.
        ET.SubElement(svg, 'path', d=child.attrib[ANDROID + 'pathData'], fill=fill)
    return ET.tostring(svg)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--android', type=Path, required=True, help='Extracted APK root with sources/ and resources/.')
    parser.add_argument('--apk', type=Path, required=True)
    parser.add_argument('--extera', type=Path, required=True, help='Sparse git clone containing the pinned revision.')
    parser.add_argument('--ayu', type=Path, required=True, help='AyuGram4A clone for its original license and notices.')
    parser.add_argument('--renderer', type=Path, required=True, help='Path to installed @resvg/resvg-js module.')
    args = parser.parse_args()
    assert sha(args.apk.read_bytes()) == APK_SHA256, 'Unexpected APK; review and pin its provenance first.'
    SOURCES.mkdir(parents=True, exist_ok=True)
    res = args.android / 'resources/res'
    java = (args.android / 'sources/com/exteragram/messenger/appicons/GeneratedAppIcons.java').read_bytes()
    upstream = json.loads(git(args.extera, 'TMessagesProj/appicons/icons.json'))
    upstream_icons = {item['id']: item for item in upstream['icons']}
    source_records = {}
    with zipfile.ZipFile(args.apk) as apk:
        apk_files = {}
        for item in apk.infolist():
            apk_files.setdefault((item.CRC, item.file_size), []).append(item.filename)
        revision_info = apk.read('META-INF/version-control-info.textproto').decode()

        def import_resource(reference, family, upstream_id, role):
            kind, resource = reference.split('.')[-2:]
            if kind == 'color':
                colors = {'white': '#FFFFFF', 'ic_background_ayutyan': '#E3D7FF',
                          'ic_background_extera': '#E83030', 'ic_background_sus': '#FFDE2A',
                          'ic_background_cyberpunk': '#0C0E15', 'ic_background_monet': '#2D3134'}
                return {'color': colors[resource]}
            source = res / ('mipmap-xxxhdpi' if kind == 'mipmap' else 'drawable-v31') / (resource + ('.webp' if kind == 'mipmap' else '.xml'))
            data = source.read_bytes()
            matches = apk_files.get((zlib.crc32(data), len(data)), [])
            # Raster inputs are byte-identical APK payloads; XML is the decoded binary drawable.
            assert kind != 'mipmap' or any(apk.read(n) == data for n in matches), source
            origin = {'apkResource': str(source.relative_to(args.android)).replace('\\', '/'),
                      'apkEntries': matches, 'apkResourceSha256': sha(data)}
            suffix = source.suffix
            if family == 'extera' and upstream_id in upstream_icons and kind == 'mipmap':
                item = upstream_icons[upstream_id]
                folder = item.get('author', 'exteragram')
                if folder == 'exteraGram':
                    folder = 'exteragram'
                for extension in ['webp', 'png', 'svg']:
                    original = f'TMessagesProj/appicons/{folder}/{upstream_id}/ic_launcher_{role}.{extension}'
                    exists = subprocess.run(['git', 'cat-file', '-e', f'{EXTERA_REVISION}:{original}'], cwd=args.extera, capture_output=True)
                    if exists.returncode == 0:
                        data = git(args.extera, original)
                        suffix = '.' + extension
                        origin.update(gitPath=original, gitRevision=EXTERA_REVISION)
                        break
            filename = f'{family}_{upstream_id}_{role}{suffix}'
            (SOURCES / filename).write_bytes(data)
            origin['sha256'] = sha(data)
            source_records[filename] = origin
            return {'file': filename}

        records = []
        strings = {e.attrib['name']: ''.join(e.itertext()).replace("\\'", "'") for e in ET.parse(res / 'values/strings.xml').getroot() if e.tag == 'string'}
        for raw in re.findall(r'AppIcon.of\((.*?)\)', java.decode()):
            values = raw.split(', ')
            identifier = json.loads(values[0])
            family = 'ayu' if identifier in NAMES and not identifier.endswith('extera') else 'extera'
            if identifier == 'ayugram_extera':
                family = 'ayu'
            upstream_id = 'default' if identifier == 'extera' else ('monet' if identifier == 'monet_extera' else identifier)
            name = NAMES.get(identifier, 'Extera' + ''.join(p.title() for p in identifier.split('_')))
            title_resource = values[3].split('.')[-1] if values[3] != '0' else None
            title = strings.get(title_resource) if title_resource else json.loads(values[4])
            description = strings.get(values[5].split('.')[-1]) if values[5] != '0' else None
            if identifier == 'default':
                title = 'Main'
            localized_name = title_resource.removeprefix('AppIcon') if title_resource and title_resource.startswith('AppIcon') and identifier not in ['default', 'monet', 'monet_extera'] else None
            record = {'name': name, 'androidId': identifier, 'family': family, 'title': title,
                      'titleKey': 'Extera.AppIcon.Name.' + localized_name if localized_name else None,
                      'description': description, 'author': None if values[8] == 'null' else json.loads(values[8]),
                      'seasonal': identifier == 'winter', 'imageName': name + '_1024x1024',
                      'background': import_resource(values[10], family, upstream_id, 'background'),
                      'foreground': import_resource(values[12], family, upstream_id, 'foreground')}
            records.append(record)
    # Keep the registry and source notices so the generated artwork is independently traceable.
    (SOURCES / 'GeneratedAppIcons.java.txt').write_bytes(java)
    for original, output in [('LICENSE', 'EXTERAGRAM-LICENSE.txt'), ('ADDITIONAL_TERMS.md', 'EXTERAGRAM-ADDITIONAL-TERMS.md'), ('TMessagesProj/appicons/README.md', 'EXTERAGRAM-APPICONS-README.md'), ('TMessagesProj/appicons/icons.json', 'extera-icons.json')]:
        (SOURCES / output).write_bytes(git(args.extera, original))
    for original, output in [('LICENSE', 'AYUGRAM-LICENSE.txt'), ('README.md', 'AYUGRAM-README.md')]:
        data = subprocess.check_output(['git', 'show', f'{AYU_REVISION}:{original}'], cwd=args.ayu)
        (SOURCES / output).write_bytes(data)
    notice_hashes = {path.name: sha(path.read_bytes()) for path in SOURCES.iterdir()
                    if path.name.startswith(('AYUGRAM-', 'EXTERAGRAM-')) or path.name in ['GeneratedAppIcons.java.txt', 'extera-icons.json']}
    renderer_js = "const fs=require('fs'); const {Resvg}=require(process.argv[1]); process.stdout.write(new Resvg(fs.readFileSync(0),{fitTo:{mode:'width',value:1536}}).render().asPng());"

    def render_layer(layer):
        if 'color' in layer:
            return Image.new('RGBA', (1536, 1536), layer['color'])
        path = SOURCES / layer['file']
        if path.suffix in ['.xml', '.svg']:
            data = vector_svg(path.read_bytes()) if path.suffix == '.xml' else path.read_bytes()
            rendered = subprocess.check_output(['node', '-e', renderer_js, str(args.renderer)], input=data)
            return Image.open(io.BytesIO(rendered)).convert('RGBA')
        return Image.open(path).convert('RGBA').resize((1536, 1536), Image.Resampling.LANCZOS)

    generated = {}
    sheet = Image.new('RGB', (800, ((len(records) + 7) // 8) * 132), '#181818')
    sheet_draw = ImageDraw.Draw(sheet)
    for index, record in enumerate(records):
        image = Image.alpha_composite(render_layer(record['background']), render_layer(record['foreground']))
        # The Android preview draws layers at [-size/4, size*5/4], exposing the central 72/108.
        image = image.crop((256, 256, 1280, 1280))
        # A few lossless Android backgrounds contain alpha=254 from their source export.
        # Flatten that one-level residue; iOS launcher icons must have no alpha channel.
        assert image.getextrema()[3][0] >= 254, record['name']
        image = Image.alpha_composite(Image.new('RGBA', image.size, '#000000'), image).convert('RGB')
        colored = []
        for r, g, b in image.resize((24, 24)).get_flattened_data():
            h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
            if s > 0.25 and v > 0.2:
                colored.append((h, s))
        hue = colored[len(colored) // 2][0] if colored else 0.73
        record['heroColor'] = '#%02X%02X%02X' % tuple(round(v * 255) for v in colorsys.hsv_to_rgb(hue, 0.65, 0.24))
        folder = DEST / (record['name'] + '.alticon')
        folder.mkdir(exist_ok=True)
        outputs = {}
        for size in SIZES:
            filename = f"{record['name']}_{size}x{size}.png"
            output = folder / filename
            image.resize((size, size), Image.Resampling.LANCZOS).save(output, optimize=True)
            outputs[filename] = sha(output.read_bytes())
        # Preserve all previously shipped SGDefault bytes and names.
        if record['name'] != 'SGDefault':
            for scale, size in [(2, 120), (3, 180)]:
                output = folder / f"{record['name']}@{scale}x.png"
                image.resize((size, size), Image.Resampling.LANCZOS).save(output, optimize=True)
                outputs[output.name] = sha(output.read_bytes())
        generated[record['name']] = outputs
        sheet.paste(image.resize((88, 88), Image.Resampling.LANCZOS), ((index % 8) * 100 + 6, (index // 8) * 132 + 4))
        sheet_draw.text(((index % 8) * 100 + 3, (index // 8) * 132 + 98), record['name'].removeprefix('Extera'), fill='white')
    sheet.save(SOURCES / 'contact-sheet.jpg', quality=95)
    overview = {}
    for asset, source in [('AyuOverviewIcon', DEST / 'Swiftgram.icon/Assets/AyuGram.png'),
                          ('ExteraOverviewIcon', DEST / 'ExteraDefault.alticon/ExteraDefault_1024x1024.png')]:
        folder = ROOT / 'Swiftgram/SGSettingsUI/Images.xcassets' / (asset + '.imageset')
        folder.mkdir(parents=True, exist_ok=True)
        data = source.read_bytes()
        (folder / (asset + '.png')).write_bytes(data)
        write_json(folder / 'Contents.json', {'images': [{'filename': asset + '.png', 'idiom': 'universal'}], 'info': {'author': 'xcode', 'version': 1}})
        overview[asset] = {'source': source.relative_to(ROOT).as_posix(), 'sha256': sha(data)}
    write_json(DEST / 'Resources/ExteraAppIconCatalog.json', records)
    write_json(SOURCES / 'provenance.json', {'apk': {'file': args.apk.name, 'sha256': APK_SHA256, 'buildMetadata': revision_info},
               'exteraRepository': 'https://github.com/exteraSquad/exteraGram', 'exteraRevision': EXTERA_REVISION,
               'ayuRepository': 'https://github.com/AyuGram/AyuGram4A', 'ayuNoticesRevision': AYU_REVISION,
               'resvg': {'version': '2.6.2', 'integrity': 'sha512-xBaJish5OeGmniDj9cW5PRa/PtmuVU3ziqrbr5xJj901ZDN4TosrVaNZpEiLZAxdfnhAe7uQ7QFWfjPe9d9K2Q=='},
               'monetPalette': {'background': '#2D3134', 'foreground': '#C2E8FF', 'source': 'Dominant interior colors measured in reference frame 24.'},
               'sources': source_records, 'generated': generated, 'overview': overview, 'notices': notice_hashes})
    print(f'Imported {len(records)} icons: {sum(r["family"] == "ayu" for r in records)} AyuGram, {sum(r["family"] == "extera" for r in records)} exteraGram.')


if __name__ == '__main__':
    main()
