"""Read-only qualification of the already pinned SDK. No network or extraction.

Usage: python3 docs/integration/extera-vosk-sdk-evidence.py /path/to/cache
JSON goes to stdout. The existing inspector is imported without running its main.
"""
import collections
import hashlib
import json
from pathlib import Path
import plistlib
import struct
import sys
import zipfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
from inspect_extera_vosk_sdk import macho, members, REQUIRED

PIN = '1891ad61293278363f75f2b4e5313c606183d0acd14f4b1ff1a71f5629c676f9'
ARCHES = {(12, 9): 'armv7', (12, 11): 'armv7s', (0x100000c, 0): 'arm64', (0x1000007, 3): 'x86_64'}

def digest(data):
    return hashlib.sha256(data).hexdigest()

def run(cache):
    path = cache / 'libvosk-0.1.2.xcframework.zip'
    data = path.read_bytes()
    assert len(data) == 48290797 and digest(data) == PIN, 'SDK ZIP identity mismatch'
    report = {'zip': {'file': path.name, 'bytes': len(data), 'sha256': PIN}, 'libraries': []}
    with zipfile.ZipFile(path) as archive:
        assert archive.testzip() is None
        report['members'] = archive.namelist()
        info_name = next(p for p in archive.namelist() if p.endswith('.xcframework/Info.plist'))
        info_data = archive.read(info_name)
        info = plistlib.loads(info_data)
        report['infoPlistSHA256'] = digest(info_data)
        report['availableLibraries'] = info['AvailableLibraries']
        prefix = info_name.removesuffix('Info.plist')
        for entry in info['AvailableLibraries']:
            name = prefix + entry['LibraryIdentifier'] + '/' + entry['LibraryPath']
            fat = archive.read(name)
            assert fat[:4] == b'\xca\xfe\xba\xbe'
            library = {'path': name, 'bytes': len(fat), 'sha256': digest(fat), 'slices': []}
            for i in range(struct.unpack_from('>I', fat, 4)[0]):
                cpu, subtype, offset, size, align = struct.unpack_from('>5I', fat, 8+i*20)
                body = fat[offset:offset+size]
                assert len(body) == size
                defined, undefined = set(), set()
                platforms, commands, tools = collections.Counter(), collections.Counter(), collections.Counter()
                objects = 0
                for _, obj in members(body):
                    m = macho(obj)
                    if not m:
                        continue
                    objects += 1
                    assert m['arch'] == ('arm' if cpu == 12 else ARCHES[(cpu, subtype)])
                    assert m['subtype'] & 0xffffff == subtype & 0xffffff
                    defined.update(m['defined'])
                    undefined.update(m['undefined'])
                    platforms.update(m['platforms'])
                    pos = 32 if obj[:4] == b'\xcf\xfa\xed\xfe' else 28
                    for _ in range(struct.unpack_from('<I', obj, 16)[0]):
                        cmd, length = struct.unpack_from('<II', obj, pos)
                        if cmd in (0x25, 0x32):
                            commands[hex(cmd)] += 1
                        if cmd == 0x32:
                            count = struct.unpack_from('<I', obj, pos+20)[0]
                            for j in range(count):
                                tool, version = struct.unpack_from('<II', obj, pos+24+j*8)
                                tools[f'{tool}:{version:#x}'] += 1
                        pos += length
                missing = sorted(REQUIRED - defined)
                assert objects == 223 and not missing
                library['slices'].append({
                    'arch': ARCHES[(cpu, subtype)], 'cpuType': hex(cpu), 'cpuSubtype': subtype,
                    'offset': offset, 'bytes': size, 'alignmentExponent': align,
                    'sha256': digest(body), 'objects': objects,
                    'platforms': [{'platform': p[0], 'minimum': p[1], 'sdk': p[2], 'objects': n} for p,n in platforms.items()],
                    'versionLoadCommands': dict(commands), 'buildVersionTools': dict(tools),
                    'requiredMissing': missing, 'undefinedOutsideArchiveCount': len(undefined-defined),
                })
            assert sorted(s['arch'] for s in library['slices']) == sorted(entry['SupportedArchitectures'])
            report['libraries'].append(library)
    return report

if __name__ == '__main__':
    print(json.dumps(run(Path(sys.argv[1])), indent=2))
