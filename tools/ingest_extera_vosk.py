"""Explicit audit ingestion. Archives remain in Temp, never application assets.

Every archive is verified against its pre-published digest before ZIP inspection.
Model MD5 pins are the publisher values recorded in the feasibility audit; newly
measured SHA-256 pins and expansion limits become the application manifest.
"""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import plistlib
import re
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CACHE = Path(tempfile.gettempdir()) / 'opencode' / 'extera-vosk-artifacts'
SDK_URL = 'https://github.com/ishantve/VoskSpeechKit/releases/download/0.1.2/libvosk.xcframework.zip'
SDK_SHA = '1891ad61293278363f75f2b4e5313c606183d0acd14f4b1ff1a71f5629c676f9'


def acquire(url, filename, algorithm, expected, expected_size):
    CACHE.mkdir(parents=True, exist_ok=True)
    target = CACHE / filename
    def digest(path):
        h = hashlib.new(algorithm)
        with path.open('rb') as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b''):
                h.update(block)
        return h.hexdigest()
    if target.exists() and target.stat().st_size == expected_size and digest(target) == expected:
        return target
    partial = target.with_suffix('.partial')
    quarantine = target.with_suffix('.quarantine')
    if quarantine.exists() and 0 < quarantine.stat().st_size < expected_size:
        quarantine.replace(partial)
    try:
        count = partial.stat().st_size if partial.exists() else 0
        for attempt in range(5):
            headers = {'User-Agent': 'Extera-Vosk-artifact-audit/1', 'Accept-Encoding': 'identity'}
            if count:
                headers['Range'] = f'bytes={count}-'
            request = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(request, timeout=90) as response:
                if response.status == 206:
                    content_range = response.headers.get('Content-Range', '')
                    if not content_range.startswith(f'bytes {count}-') or not content_range.endswith(f'/{expected_size}'):
                        raise ValueError('Unexpected response range: ' + content_range)
                    mode = 'ab'
                elif response.status == 200:
                    count = 0
                    mode = 'wb'
                else:
                    raise ValueError('Unexpected HTTP status')
                with partial.open(mode) as out:
                    while block := response.read(1024 * 1024):
                        count += len(block)
                        if count > expected_size:
                            raise ValueError('Published archive length exceeded')
                        out.write(block)
            if count == expected_size:
                break
            print(f'RESUME {filename}: {count}/{expected_size} bytes', flush=True)
        actual = digest(partial)
        if count != expected_size or actual != expected:
            partial.replace(quarantine)
            raise ValueError(f'Integrity failure: {filename}: bytes={count}, expected={expected_size}; {algorithm}={actual}, expected={expected}; quarantined, never extracted')
        partial.replace(target)
        return target
    finally:
        partial.unlink(missing_ok=True)


def sdk():
    path = acquire(SDK_URL, 'libvosk-0.1.2.xcframework.zip', 'sha256', SDK_SHA, 48290797)
    output = CACHE / 'sdk'
    with zipfile.ZipFile(path) as archive:
        for entry in archive.infolist():
            if entry.filename.startswith('/') or '..' in Path(entry.filename).parts or ((entry.external_attr >> 16) & 0o170000) == 0o120000:
                raise ValueError('Unsafe SDK entry')
        # Digest verified above, before any extraction.
        archive.extractall(output)
        result = {'url': SDK_URL, 'sha256': SDK_SHA, 'bytes': path.stat().st_size,
                  'files': [{'path': e.filename, 'bytes': e.file_size} for e in archive.infolist()]}
    for p in output.rglob('Info.plist'):
        result.setdefault('plists', {})[str(p.relative_to(output))] = plistlib.loads(p.read_bytes())
    print(json.dumps(result, indent=2))
    (CACHE / 'sdk-inspection.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')


def model(row):
    language, name, url, size, md5, license = row
    path = acquire(url, name + '.zip', 'md5', md5, int(size))
    sha = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            sha.update(block)
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        # Verify all CRCs during ingestion, without extracting model files.
        if archive.testzip() is not None:
            raise ValueError('ZIP CRC failure')
        for e in entries:
            if e.filename.startswith('/') or '..' in Path(e.filename).parts or ((e.external_attr >> 16) & 0o170000) == 0o120000:
                raise ValueError('Unsafe model entry')
        total = sum(e.file_size for e in entries)
        largest = max(e.file_size for e in entries)
        roots = sorted({e.filename.split('/')[0] for e in entries})
        if roots != [name]:
            raise ValueError(f'Unexpected model roots: {roots}')
        notices = {}
        for e in entries:
            if re.search(r'(^|/)(COPYING|LICENSE|NOTICE|README)(\.[^/]*)?$', e.filename, re.I) and e.file_size < 65536:
                notices[e.filename] = archive.read(e).decode('utf-8', errors='replace')
    result = {'language': language, 'name': name, 'url': url, 'archiveBytes': int(size),
              'md5': md5, 'sha256': sha.hexdigest(), 'license': license.strip(),
              'expandedBytes': total, 'largestEntryBytes': largest, 'entryCount': len(entries), 'notices': notices}
    (CACHE / (name + '.json')).write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f'VERIFIED {language} {name} sha256={result["sha256"]} expanded={total}', flush=True)
    return result


def models():
    audit = (ROOT / 'docs/extera-vosk-ios-feasibility.md').read_text(encoding='utf-8')
    rows = re.findall(r'^\| [^|]+ `([^`]+)` \| \[(vosk-model[^]]+)\]\((https://[^)]+)\) \| (\d+) \| `([0-9a-f]+)` \| ([^|]+) \|$', audit, re.M)
    if len(rows) != 24:
        raise ValueError('Expected exact 24 pinned publisher entries')
    entries = []
    errors = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        futures = [pool.submit(model, row) for row in rows]
        for future in concurrent.futures.as_completed(futures):
            try:
                entries.append(future.result())
            except Exception as error:
                errors.append(str(error))
                print('FAILED: ' + str(error), flush=True)
    entries.sort(key=lambda item: next(i for i, row in enumerate(rows) if row[0] == item['language']))
    (CACHE / 'models-verified.json').write_text(json.dumps(entries, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f'COMPLETE: {len(entries)} models verified; manifest in ' + str(CACHE / 'models-verified.json'))
    if errors:
        raise SystemExit('\n'.join(errors))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('artifact', choices=['sdk', 'models'])
    args = parser.parse_args()
    (sdk if args.artifact == 'sdk' else models)()
