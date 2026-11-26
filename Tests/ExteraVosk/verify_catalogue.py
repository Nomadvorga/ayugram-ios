"""Offline validation of exact Android catalogue and optional ingestion evidence."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import zipfile

ROOT = Path(__file__).resolve().parents[2]
LANGUAGES = 'en es zh hi fa fr ru pt de ja ko it uk gu pl nl tr vi cs uz eo kk tg ca'.split()


def records():
    text = (ROOT / 'submodules/Media/VoskSpeech/Sources/VoskVerifiedModels.swift').read_text(encoding='utf-8')
    result = []
    for row in re.findall(r'\.init\(([^\n]+)\)', text):
        fields = dict(re.findall(r'(\w+): ("[^"\n]*"|\d+)', row))
        result.append({key: json.loads(value) for key, value in fields.items()})
    assert [entry['language'] for entry in result] == LANGUAGES
    assert sum(entry['archiveBytes'] for entry in result) == 1288393315
    assert sum(entry['expandedBytes'] for entry in result) == 2758240586
    audit = (ROOT / 'docs/extera-vosk-ios-feasibility.md').read_text(encoding='utf-8')
    expected = re.findall(r'^\| [^|]+ `([^`]+)` \| \[(vosk-model[^]]+)\]\((https://[^)]+)\) \| (\d+) \| `([0-9a-f]+)` \| ([^|]+) \|$', audit, re.M)
    assert len(expected) == 24
    for entry, (language, name, url, size, md5, license) in zip(result, expected):
        assert (entry['language'], entry['name'], entry['archiveBytes'], entry['md5'], entry['license']) == (language, name, int(size), md5, license.strip())
        assert url == f'https://alphacephei.com/vosk/models/{name}.zip'
        assert re.fullmatch('[a-f0-9]{64}', entry['sha256'])
        assert re.fullmatch('[a-f0-9]{32}', md5)
    return result


def check_cache(cache, entries):
    evidence = json.loads((cache / 'models-verified.json').read_text(encoding='utf-8'))
    assert len(evidence) == 24
    for entry, measured in zip(entries, evidence):
        for key, value in entry.items():
            assert measured[key] == value, (entry['language'], key)
        path = cache / (entry['name'] + '.zip')
        sha, md5 = hashlib.sha256(), hashlib.md5()
        with path.open('rb') as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b''):
                sha.update(block)
                md5.update(block)
        assert path.stat().st_size == entry['archiveBytes']
        assert sha.hexdigest() == entry['sha256']
        assert md5.hexdigest() == entry['md5']
        with zipfile.ZipFile(path) as archive:
            members = archive.infolist()
            assert len(members) == entry['entryCount']
            assert sum(item.file_size for item in members) == entry['expandedBytes']
            assert max(item.file_size for item in members) == entry['largestEntryBytes']
            names = set()
            for item in members:
                components = item.filename.rstrip('/').split('/')
                assert components[0] == entry['name']
                assert all(p not in ['', '.', '..'] for p in components)
                assert not any(ch in item.filename for ch in ['\\', ':', '\0'])
                name = '/'.join(components).lower()
                assert name not in names
                names.add(name)
                assert ((item.external_attr >> 16) & 0o170000) in [0, 0o100000, 0o040000]
                assert item.flag_bits & ~0x80e == 0 and item.compress_type in [0, 8]
                if item.is_dir():
                    assert item.file_size == item.compress_size == item.CRC == item.compress_type == 0
            required = ['final.mdl', 'mfcc.conf', 'HCLr.fst', 'Gr.fst'] if entry['language'] in ['pt', 'tr'] else ['am/final.mdl', 'conf/model.conf']
            assert all(entry['name'] + '/' + name in archive.namelist() for name in required)
    print('PASS: all 24 complete cached archives match SHA-256, publisher MD5, sizes, member limits and extraction path/type policy')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model-cache', type=Path)
    args = parser.parse_args()
    entries = records()
    print('PASS: exact 24 Android languages/IDs/URLs/publisher pins/licenses and complete SHA-256/expansion catalogue')
    strings = json.loads((ROOT / 'docs/integration/extera-vosk-strings.json').read_text(encoding='utf-8'))
    screen = (ROOT / 'Swiftgram/SGSettingsUI/Sources/ExteraVoskRecognitionController.swift').read_text(encoding='utf-8')
    keys = {'Extera.Vosk.' + key for key in re.findall(r'self\.text\("([^"]+)"\)', screen)}
    assert keys == set(strings['en']) == set(strings['ru'])
    patch = (ROOT / 'docs/integration/extera-vosk-root.patch').read_text(encoding='utf-8')
    for language in ['en', 'ru']:
        section = patch.split(f'diff --git a/Swiftgram/SGStrings/Strings/{language}.lproj/SGLocalizable.strings ', 1)[1].split('diff --git ', 1)[0]
        values = {key: json.loads(value) for key, value in re.findall(r'^\+"(Extera\.Vosk\.[^"]+)" = (".*");$', section, re.M)}
        assert values == strings[language]
    print('PASS: all 21 UI localization keys have exact English/Russian integration hunks')
    if args.model_cache:
        check_cache(args.model_cache, entries)


if __name__ == '__main__':
    main()
