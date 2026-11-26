"""Compile the production C inflater and exercise bounded streaming via ctypes.

Requires a C compiler and zlib headers (macOS or Linux). Optional --model-cache
also drains every actual pinned ZIP member; this script never downloads files.
The Python driver follows the Swift reader's chunk/drain contract, but does not
execute Swift or prove the iOS SDK link/recognizer.
"""
import argparse
import ctypes as c
import json
import os
from pathlib import Path
import random
import shutil
import struct
import subprocess
import tempfile
import zipfile
import zlib

ROOT = Path(__file__).resolve().parents[2]


class Inflater:
    def __init__(self, library):
        self.lib = c.CDLL(str(library))
        self.lib.extera_vosk_inflate_new.restype = c.c_void_p
        self.lib.extera_vosk_inflate_free.argtypes = [c.c_void_p]
        self.lib.extera_vosk_inflate.argtypes = [c.c_void_p, c.c_void_p, c.c_size_t, c.c_void_p, c.c_size_t,
                                                c.POINTER(c.c_size_t), c.POINTER(c.c_size_t)]
        self.lib.extera_vosk_inflate.restype = c.c_int
        self.lib.extera_vosk_crc32.argtypes = [c.c_uint32, c.c_void_p, c.c_size_t]
        self.lib.extera_vosk_crc32.restype = c.c_uint32

    def drain(self, chunks, expected_size, expected_crc, output_capacity=65536, collect=False):
        state = self.lib.extera_vosk_inflate_new()
        assert state
        total = crc = 0
        ended = False
        result = bytearray()
        try:
            for data in chunks:
                if ended:
                    raise ValueError('Trailing compressed bytes')
                source = c.create_string_buffer(data)
                offset = 0
                while True:
                    output = c.create_string_buffer(output_capacity)
                    consumed, produced = c.c_size_t(), c.c_size_t()
                    status = self.lib.extera_vosk_inflate(state, c.byref(source, offset), len(data) - offset,
                                                        output, output_capacity, c.byref(consumed), c.byref(produced))
                    if status < 0:
                        raise ValueError('Invalid deflate')
                    if not consumed.value and not produced.value:
                        if status != 0 or offset != len(data):
                            raise ValueError('No progress')
                        break  # Need the next input chunk; EOF below still requires stream end.
                    offset += consumed.value
                    total += produced.value
                    if total > expected_size:
                        raise ValueError('Expansion limit')
                    crc = self.lib.extera_vosk_crc32(crc, output, produced.value)
                    if collect:
                        result.extend(output.raw[:produced.value])
                    if status == 1:
                        if offset != len(data):
                            raise ValueError('Trailing bytes in chunk')
                        ended = True
                        break
                    if offset == len(data) and produced.value < output_capacity:
                        break
            if not ended or total != expected_size or crc != expected_crc:
                raise ValueError('Truncation, length or CRC mismatch')
            return bytes(result)
        finally:
            self.lib.extera_vosk_inflate_free(state)


def chunks(data, size):
    return (data[i:i + size] for i in range(0, len(data), size))


def reject(action):
    try:
        action()
    except ValueError:
        return
    raise AssertionError('Expected rejection')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model-cache', type=Path)
    args = parser.parse_args()
    compiler = shutil.which(os.environ.get('CC', 'cc'))
    if not compiler:
        raise SystemExit('BLOCKED: C compiler absent')
    with tempfile.TemporaryDirectory(prefix='extera-vosk-native-') as temporary:
        library = Path(temporary) / 'libextera-vosk.so'
        native = ROOT / 'submodules/VoskNative'
        subprocess.run([compiler, '-std=c11', '-Wall', '-Wextra', '-Werror', '-shared', '-fPIC',
                        '-I', str(native / 'include'), str(native / 'Sources/VoskInflate.c'), '-lz', '-o', str(library)], check=True)
        subprocess.run([compiler, '-std=c11', '-Wall', '-Wextra', '-Werror', '-fsyntax-only',
                        '-I', str(native / 'include'), str(ROOT / 'Tests/ExteraVosk/NativeSmoke.c'),
                        str(ROOT / 'Tests/ExteraVosk/NativeHostStub.c')], check=True)
        inflater = Inflater(library)
        rng = random.Random(20261125)
        cases = 0
        for size in [0, 1, 65535, 65536, 65537, 131072, 3 * 65536]:
            for data in [b'x' * size, rng.randbytes(size)]:
                for level in [0, 1, 9]:
                    compressor = zlib.compressobj(level=level, wbits=-15)
                    packed = compressor.compress(data) + compressor.flush()
                    for block, capacity in [(1, 63), (4096, 65536), (65536, 65536), (65536, 1024)]:
                        actual = inflater.drain(chunks(packed, block), len(data), zlib.crc32(data), capacity, collect=True)
                        assert actual == data
                        cases += 1
                    reject(lambda: inflater.drain([packed[:-1]], len(data), zlib.crc32(data)))
                    reject(lambda: inflater.drain([packed + b'extra'], len(data), zlib.crc32(data)))
                    reject(lambda: inflater.drain([packed], len(data), zlib.crc32(data) ^ 1))
                    if data:
                        reject(lambda: inflater.drain([packed], len(data) - 1, zlib.crc32(data)))
        reject(lambda: inflater.drain([b'\x07'], 0, 0))
        print(f'PASS: actual production C inflater, {cases} streaming/boundary cases; truncation/trailing/CRC/expansion/invalid-stream rejection', flush=True)
        if args.model_cache:
            manifest = json.loads((args.model_cache / 'models-verified.json').read_text(encoding='utf-8'))
            assert len(manifest) == 24
            members = expanded = 0
            for model in manifest:
                path = args.model_cache / (model['name'] + '.zip')
                with zipfile.ZipFile(path) as archive, path.open('rb') as raw:
                    for entry in archive.infolist():
                        if entry.is_dir() or entry.compress_type == 0:
                            continue
                        assert entry.compress_type == 8
                        raw.seek(entry.header_offset)
                        header = raw.read(30)
                        name_bytes, extra_bytes = struct.unpack_from('<HH', header, 26)
                        raw.seek(name_bytes + extra_bytes, 1)
                        def blocks():
                            remaining = entry.compress_size
                            while remaining:
                                data = raw.read(min(65536, remaining))
                                assert data
                                remaining -= len(data)
                                yield data
                        inflater.drain(blocks(), entry.file_size, entry.CRC)
                        members += 1
                        expanded += entry.file_size
                print('PASS: native inflater drained ' + model['language'], flush=True)
            print(f'PASS: {members} real deflated members / {expanded} expanded bytes in all 24 pinned archives')


if __name__ == '__main__':
    main()
