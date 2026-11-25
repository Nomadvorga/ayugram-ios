"""Decode the reference APK's own lsparanoid link literals, without network access.

Usage: py tools/decode_ayu_overview_links.py --android C:/Users/PC/ayugram-apk-src
Requires a JDK. Compiles only the three original, dependency-free decoder classes.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

KEYS = {
    'channelLabel': -227889340876056, 'chatLabel': -227854981137688,
    'translationLabel': -227734722053400, 'documentationLabel': -227635937805592,
    'channelUsername': -227472729048344, 'chatUsername': -227507088786712,
    'translationURL': -227455549179160, 'documentationURL': -227257980683544,
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--android', type=Path, required=True)
    args = parser.parse_args()
    sources = args.android / 'sources'
    package = sources / 'org/lsposed/lsparanoid'
    java = [package / name for name in ['Deobfuscator$AyuGram4A$TMessagesProj.java', 'DeobfuscatorHelper.java', 'RandomHelper.java']]
    activity = sources / 'com/radolyn/ayugram/preferences/AyuMainPreferencesActivity.java'
    text = activity.read_text(encoding='utf-8')
    for key in KEYS.values():
        assert f'getString({key}L)' in text
    with tempfile.TemporaryDirectory(prefix='ayu-overview-links-') as temporary:
        folder = Path(temporary)
        harness = folder / 'DecodeAyuLinks.java'
        literals = ','.join(f'{value}L' for value in KEYS.values())
        harness.write_text('import org.lsposed.lsparanoid.Deobfuscator$AyuGram4A$TMessagesProj;\n'
                           'public class DecodeAyuLinks { public static void main(String[] args) {\n'
                           f'for (long key : new long[] {{{literals}}}) {{\n'
                           'System.out.println(Deobfuscator$AyuGram4A$TMessagesProj.getString(key));\n'
                           '} } }\n', encoding='utf-8')
        subprocess.run(['javac', '-encoding', 'UTF-8', '-d', str(folder), *map(str, java), str(harness)], check=True)
        decoded = subprocess.check_output(['java', '-cp', str(folder), 'DecodeAyuLinks'], text=True, encoding='utf-8').splitlines()
    assert len(decoded) == len(KEYS)
    print(json.dumps({'values': {name: {'key': key, 'value': value} for (name, key), value in zip(KEYS.items(), decoded)},
                      'sourceSha256': {str(path.relative_to(args.android)).replace('\\', '/'): hashlib.sha256(path.read_bytes()).hexdigest() for path in [activity, *java]}}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
