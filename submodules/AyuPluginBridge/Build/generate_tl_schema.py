#!/usr/bin/env python3
"""Regenerate ``Python/_ayu_javalib/_telegram_tl_schema.py`` for ``telegram_tl.py``.

Inputs are read as text only:

- the TL scheme of the layer the iOS client speaks (``submodules/TelegramApi/swift_scheme.tl``):
  constructor ids, parameter order, wire types and flag bits;
- Android ``TLRPC.java`` and ``tgnet/tl/*.java`` of the reference client: class names, class
  hierarchy, Java field names, defaults and class constants.

Classes are joined by constructor id. A Java class whose constructor the scheme does not list
keeps the layout read from its ``serializeToStream`` (older request versions the server still
accepts); a scheme constructor without a Java class becomes ``TL_<name>``. Java classes named
``*_layerN``/``*_old``/``*_secret`` are left out unless another class extends them.

Table line: ``name|base|constructor|fields|wire|result|constants``
  fields    own Java fields ``name:kind[=default]``; kinds i l b d s y (int, long, boolean, double,
            String, byte[]), A/a (ArrayList created / null), o (object, null), n<Class> (new Class())
  wire      ``-`` when the class has a constructor but no known layout, else
            ``name:code[@flagsIndex.bit][mode]`` in serialization order; codes # (flags word) i l d s y
            B (Bool) t (flag bit only) q Q (int128, int256) o (boxed object) V<code> (vector);
            mode ? ?z ?e marks a flag Android derives from the value (non-null, non-zero, non-empty)
  result    response code of a function: o or V<code>
  name      nested class of ``TLRPC``, or ``tl.<Outer>$<Name>`` for ``org.telegram.tgnet.tl.<Outer>``
"""
from __future__ import annotations

import argparse
import base64
import collections
import hashlib
import keyword
import pathlib
import re
import sys
import zlib

CLASS = re.compile(r'^\s*public\s+(?:static\s+)?(abstract\s+)?(?:static\s+)?class\s+(\w+)(?:<[^>]*>)?(?:\s+extends\s+([\w.]+)(<[^{]*>)?)?(?:\s+implements\s+[\w., <>]+)?\s*\{')
FIELD = re.compile(r'^\s*public\s+(?!static)(?:final\s+)?([\w.]+(?:<[\w., <>\[\]]+>)?(?:\[\])?)\s+(\w+)\s*(?:=\s*(.+?))?;')
CONST = re.compile(r'^\s*public\s+(?:static\s+final|final\s+static)\s+(int|long|String|boolean)\s+(\w+)\s*=\s*(.+?);')
FLAGN = {f'FLAG_{i}': i for i in range(32)}

def bit_of(text):
    text = text.strip()
    if text in FLAGN: return FLAGN[text]
    try:
        v = int(text, 0)
    except ValueError:
        m = re.fullmatch(r'1\s*<<\s*(\d+)', text)
        if not m: return None
        return int(m.group(1))
    if v <= 0 or v & (v - 1): return None
    return v.bit_length() - 1

def parse_file(path, outer):
    lines = path.read_text('utf-8').split('\n')
    classes = {}
    stack = []  # (name, depth_at_open)
    depth = 0
    i = 0
    cur_method = None  # (cls, kind, depth, lines)
    while i < len(lines):
        raw = lines[i]; i += 1
        line = re.sub(r'//.*$', '', raw)
        if cur_method is None:
            m = CLASS.match(line)
            if m and stack and depth == stack[-1][1] + 1 or (m and not stack and depth == 1):
                name = m.group(2)
                qual = '$'.join([outer] + [s[0] for s in stack] + [name])
                base = m.group(3) or ''
                gen = (m.group(4) or '')
                classes[qual] = {'name': qual, 'abstract': bool(m.group(1)), 'base': base, 'gen': gen.strip('<>'),
                                 'ctor': None, 'fields': [], 'ser': None, 'resp': None, 'cases': [], 'consts': {}}
                stack.append((name, depth))
                depth += line.count('{') - line.count('}')
                continue
            if stack and depth == stack[-1][1] + 1:
                cls = classes['$'.join([outer] + [s[0] for s in stack])]
                c = CONST.match(line)
                if c:
                    if c.group(2) == 'constructor':
                        try: cls['ctor'] = int(c.group(3), 0)
                        except ValueError: pass
                    else:
                        cls['consts'][c.group(2)] = (c.group(1), c.group(3))
                else:
                    f = FIELD.match(line)
                    if f and '(' not in line.split('=')[0]:
                        cls['fields'].append((f.group(2), f.group(1).replace(' ', ''), (f.group(3) or '').strip()))
                    else:
                        mm = re.match(r'^\s*(?:@\w+\s+)?(?:final\s+)?public\s+(?:static\s+)?(?:final\s+)?[\w.<>\[\], ]+?\s+(serializeToStream|deserializeResponse|deserializeResponseT|TLdeserialize)\s*\(', line)
                        if mm and '{' in line:
                            cur_method = [cls, mm.group(1), depth, []]
        else:
            cur_method[3].append(line)
        depth += line.count('{') - line.count('}')
        if cur_method is not None and depth <= cur_method[2]:
            cls, kind, _, body = cur_method
            if kind == 'serializeToStream': cls['ser'] = body
            elif kind.startswith('deserializeResponse'): cls['resp'] = body
            else: cls['cases'] = body
            cur_method = None
        while stack and depth <= stack[-1][1]:
            stack.pop()
    return classes

def _wire_names(cls, classes):
    seen = []
    c = cls
    guard = 0
    while c and guard < 12:
        seen = [f[0] for f in c['fields']] + seen
        c = resolve(c['base'], c['name'], classes)
        guard += 1
    return set(seen)

def resolve(ref, context, classes):
    """Resolve a Java simple/qualified type reference from the context class to a schema key."""
    if not ref: return None
    ref = ref.replace('.', '$')
    outer = context.split('$')[0]
    for cand in (ref, outer + '$' + ref, 'TLRPC$' + ref):
        if cand in classes: return classes[cand]
    return None

UNKNOWN_AUTO = []
def wire_of(cls, classes):
    body = cls['ser']
    if body is None: return None
    names = _wire_names(cls, classes)
    out = []; cond = []  # stack of (flagvar, bit) or None per open brace
    seen = set()
    for line in body:
        s = line.strip()
        if not s: continue
        m = re.match(r'(flags\d?)\s*=\s*setFlag\(\s*flags\d?\s*,\s*([\w<> ]+?)\s*,\s*(.+)\)\s*;', s)
        if not m:
            m2 = re.match(r'(flags\d?)\s*=\s*(.+?)\s*\?\s*\(?\s*flags\d?\s*\|\s*([\w<> ]+?)\s*\)?\s*:\s*\(?\s*flags\d?\s*&\s*~\s*([\w<> ]+?)\s*\)?\s*;', s)
            if m2: m = type('M', (), {'group': lambda self, n, m2=m2: (m2.group(1), m2.group(3), m2.group(2))[n - 1]})()
        if m:
            var, bit, expr = m.group(1), bit_of(m.group(2)), m.group(3).strip()
            if bit is not None and re.fullmatch(r'\w+', expr) and expr in names and ('!' + expr) not in seen:
                out.append((expr, var, bit, True)); seen.add('!' + expr)
            elif bit is not None:
                # presence expression such as `x != null`, `!TextUtils.isEmpty(x)`: remember as auto presence
                e = expr.strip()
                if e.startswith('(') and e.endswith(')') and e.count('(') == 1: e = e[1:-1].strip()
                ma = re.fullmatch(r'(\w+)\s*!=\s*null', e)
                mz = re.fullmatch(r'(\w+)\s*!=\s*0', e)
                me = re.fullmatch(r'(\w+)\s*!=\s*null\s*&&\s*!\s*(\w+)\.isEmpty\(\)', e)
                mb = re.fullmatch(r'(\w+)\s*!=\s*null\s*&&\s*(\w+)', e)
                if ma and ma.group(1) in names: out.append((ma.group(1), var, bit, 'auto'))
                elif mz and mz.group(1) in names: out.append((mz.group(1), var, bit, 'autoz'))
                elif me and me.group(1) in names and me.group(1) == me.group(2): out.append((me.group(1), var, bit, 'autoe'))
                elif mb and mb.group(1) in names and mb.group(1) == mb.group(2) and ('!' + mb.group(1)) not in seen:
                    out.append((mb.group(1), var, bit, True)); seen.add('!' + mb.group(1))
                else: UNKNOWN_AUTO.append((cls['name'], expr))
            continue
        opened = s.count('{'); closed = s.count('}')
        c = re.match(r'(?:\}\s*else\s*)?if\s*\((.*)\)\s*\{?$', s)
        this_cond = None
        if c:
            e = c.group(1)
            mm = re.search(r'hasFlag\(\s*(flags\d?)\s*,\s*([\w<> ]+?)\s*\)', e) or re.search(r'\(\s*(flags\d?)\s*&\s*([\w<> ]+?)\s*\)\s*!=\s*0', e)
            if mm:
                b = bit_of(mm.group(2))
                if b is not None: this_cond = (mm.group(1), b)
        for _ in range(closed):
            if cond: cond.pop()
        # written field on this line
        w = (re.search(r'stream\.write\w+\(\s*(?:\([\w.]+\)\s*)?(\w+)\s*[,)]', s) or re.search(r'(?:^|[\s(])(\w+)\.serializeToStream\(', s)
             or re.search(r'Vector\.serialize\w*\(\s*stream\s*,\s*(?:[\w:.>\- ()]+,\s*)?(\w+)\s*\)', s) or re.search(r'=\s*(\w+)\.size\(\)', s)
             or re.search(r'stream\.write\w+\(\s*(\w+)\s*\?', s))
        if w and w.group(1) in names and w.group(1) not in seen and w.group(1) not in ('flags', 'flags2', 'flags3'):
            active = next((x for x in reversed(cond) if x), None) or this_cond
            out.append((w.group(1), active[0] if active else None, active[1] if active else None, False))
            seen.add(w.group(1))
        for _ in range(opened):
            cond.append(this_cond)
            this_cond = None if not c else this_cond
    return out

def response_of(cls, classes):
    if cls['gen']: return cls['gen'].replace(' ', '')
    body = cls['resp']
    if not body: return ''
    text = ' '.join(body)
    m = re.search(r'Vector\.TLDeserialize(Int|Long)?\(\s*stream\s*,\s*constructor\s*,\s*exception(?:\s*,\s*([\w.]+)::TLdeserialize)?', text)
    if m:
        return 'Vector<' + (m.group(1) or m.group(2) or '?') + '>'
    m = re.search(r'return\s+([\w.]+)\.TLdeserialize\(', text)
    if m: return m.group(1)
    m = re.search(r'([\w.]+)\s+\w+\s*=\s*new\s+([\w.]+)\(\)', text)
    if m: return m.group(2)
    return '?'

LEGACY = re.compile(r'(_layer\d+\w*|_old\d*|_secret|_legacy\w*)$', re.I)
SCHEME_CODES = {'int': 'i', 'long': 'l', 'double': 'd', 'string': 's', 'bytes': 'y', 'Bool': 'B', 'true': 't',
                'int128': 'q', 'int256': 'Q', '#': '#'}
JAVA_KINDS = {'int': 'i', 'long': 'l', 'boolean': 'b', 'double': 'd', 'float': 'd', 'short': 'i', 'byte': 'i',
              'String': 's', 'byte[]': 'y'}
RESERVED = {'default': 'isDefault', 'public': 'isPublic', 'final': 'isFinal', 'long': '_long', 'static': 'isStatic',
            'short': 'isShort'}
AUTO = {'auto': '?', 'autoz': '?z', 'autoe': '?e'}


def parse_scheme(path):
    """Scheme entries; generic wrappers (``invokeWithLayer`` ...) and ``vector``/``true`` are skipped."""
    entries, function = [], False
    for line in path.read_text('utf-8').split('\n'):
        line = line.strip()
        if line in ('---functions---', '---types---'):
            function = line == '---functions---'
            continue
        if not line or line.startswith('//'):
            continue
        match = re.match(r'^([\w.]+)#([0-9a-f]+)\s*(.*?)\s*=\s*(.+?);$', line)
        if not match:
            raise SystemExit('Unreadable scheme line: ' + line[:80])
        name, constructor, params, result = match.groups()
        parts = params.split()
        if name in ('true', 'vector') or any(part.startswith('{') or ':' not in part for part in parts):
            continue
        entries.append({'name': name, 'id': int(constructor, 16), 'params': [tuple(part.split(':', 1)) for part in parts],
                        'result': result, 'fn': function})
    return entries


def scheme_code(kind):
    if kind in SCHEME_CODES:
        return SCHEME_CODES[kind]
    match = re.fullmatch(r'[Vv]ector<(.+)>', kind)
    return 'V' + scheme_code(match.group(1)) if match else 'o'


def top_constants(path):
    found, depth = [], 0
    for raw in path.read_text('utf-8').split('\n'):
        line = re.sub(r'//.*$', '', raw)
        if depth == 1:
            match = CONST.match(line)
            if match and match.group(1) in ('int', 'long'):
                try:
                    found.append((match.group(2), int(match.group(3).rstrip('L'), 0)))
                except ValueError:
                    pass
        depth += line.count('{') - line.count('}')
    return found


def build(tlrpc, tl_dir, scheme):
    classes = parse_file(tlrpc, 'TLRPC')
    for path in sorted(tl_dir.glob('*.java')):
        classes.update(parse_file(path, path.stem))
    entries = parse_scheme(scheme)
    by_id = {entry['id']: entry for entry in entries}

    def base_key(cls):
        base = resolve(cls['base'], cls['name'], classes)
        return base['name'] if base else ''

    def inherited_fields(cls):
        chain, current = [], cls
        while current and len(chain) < 12:
            chain.append(current)
            current = resolve(current['base'], current['name'], classes)
        fields = {}
        for current in reversed(chain):
            for name, kind, _ in current['fields']:
                fields[name] = kind
        return fields

    keep = {key: cls for key, cls in classes.items() if not LEGACY.search(key)}
    grew = True
    while grew:
        grew = False
        for cls in list(keep.values()):
            base = base_key(cls)
            if base and base not in keep:
                keep[base], grew = classes[base], True
    stats = collections.Counter()
    extra, wires, results, used = collections.defaultdict(list), {}, {}, set()
    for key, cls in keep.items():
        constructor = None if cls['ctor'] is None else cls['ctor'] & 0xffffffff
        entry = by_id.get(constructor)
        fields = inherited_fields(cls)
        java_wire = wire_of(cls, classes) or [] if cls['ser'] is not None else []
        if entry is not None:
            used.add(constructor)
            # A flag Android derives from a value is listed once where it is computed and again
            # where the value is written; only the write takes part in name alignment.
            java_names = [item[0] for item in java_wire if item[3] not in AUTO]
            java_mode = {item[0]: item[3] for item in java_wire if item[3] in AUTO}
            names = [name for name, kind in entry['params'] if kind != '#']
            alias = {}
            if len(java_names) == len(names):
                for scheme_name, java_name in zip(names, java_names):
                    if scheme_name != java_name and scheme_name not in fields and java_name in fields and java_name not in names:
                        alias[scheme_name] = java_name
            flag_words = [name for name, kind in entry['params'] if kind == '#']
            items = []
            for name, kind in entry['params']:
                condition = ''
                match = re.fullmatch(r'(flags\d?)\.(\d+)\?(.+)', kind)
                if match:
                    condition, kind = f'@{flag_words.index(match.group(1))}.{match.group(2)}', match.group(3)
                code = scheme_code(kind)
                attribute = name if name in fields else alias.get(name) or (RESERVED[name] if RESERVED.get(name) in fields else None)
                if attribute is None:
                    attribute = name + '_' if keyword.iskeyword(name) else name
                    extra[key].append((attribute, code))
                    stats['scheme_only_fields'] += 1
                mode = AUTO.get(java_mode.get(attribute), '') if condition and code != 't' else ''
                items.append(f'{attribute}:{code}{condition}{mode}')
            wires[key] = ' '.join(items)
            stats['scheme_layouts'] += 1
            if entry['fn']:
                results[key] = scheme_code(entry['result'])
        elif constructor is not None and cls['ser'] is not None:
            if any(item[1] not in (None, 'flags') for item in java_wire):
                stats['java_layouts_skipped'] += 1
                continue
            items = ['flags:#'] if any(item[1] for item in java_wire) else []
            derived = {item[0]: item[3] for item in java_wire if item[3] in AUTO}
            for name, word, bit, mode in java_wire:
                if mode in AUTO:
                    continue
                mode = derived.get(name, mode)
                kind = fields.get(name, '')
                match = re.fullmatch(r'ArrayList(?:<(.+)>)?', kind)
                if match:
                    code = 'V' + {'Integer': 'i', 'Long': 'l', 'String': 's', 'byte[]': 'y'}.get(match.group(1) or '', 'o')
                elif kind == 'boolean':
                    code = 't' if mode is True else 'B'
                else:
                    code = JAVA_KINDS.get(kind, 'o')
                condition = f'@0.{bit}' if word else ''
                items.append(f'{name}:{code}{condition}' + (AUTO.get(mode, '') if condition and code != 't' else ''))
            wires[key] = ' '.join(items)
            stats['java_layouts'] += 1
            if cls['resp'] is not None or cls['gen']:
                response = response_of(cls, classes)
                results[key] = ('V' + ('i' if 'Int' in response else 'l' if 'Long' in response else 'o')
                                if response.startswith('Vector<') else 'o')
    generated = []
    for entry in entries:
        if entry['id'] in used:
            continue
        key = 'TLRPC$TL_' + entry['name'].replace('.', '_')
        if key in keep:
            if entry['fn']:
                stats['scheme_functions_shadowed'] += 1
                continue
            key += '_scheme'
        base = 'TLRPC$' + entry['result'].replace('.', '_')
        base = base if not entry['fn'] and base in keep and keep[base]['ctor'] is None else ''
        flag_words = [name for name, kind in entry['params'] if kind == '#']
        items, fields = [], []
        for name, kind in entry['params']:
            condition = ''
            match = re.fullmatch(r'(flags\d?)\.(\d+)\?(.+)', kind)
            if match:
                condition, kind = f'@{flag_words.index(match.group(1))}.{match.group(2)}', match.group(3)
            code = scheme_code(kind)
            attribute = name + '_' if keyword.iskeyword(name) else name
            items.append(f'{attribute}:{code}{condition}')
            fields.append((attribute, code))
        generated.append((key, base, entry['id'], fields, ' '.join(items), scheme_code(entry['result']) if entry['fn'] else ''))
        stats['scheme_only_classes'] += 1

    def java_kind(kind, default, context):
        if re.fullmatch(r'ArrayList(?:<.+>)?', kind):
            return 'A' if default.startswith('new ') else 'a'
        if kind in JAVA_KINDS:
            code = JAVA_KINDS[kind]
            if re.fullmatch(r'-?\d+L?|-?0x[0-9a-fA-F]+|true', default) and default != '0':
                return code + '=' + ('1' if default == 'true' else str(int(default.rstrip('L'), 0)))
            if re.fullmatch(r'"[^"|\s\\]*"', default):
                return code + '=' + default
            return code
        match = re.fullmatch(r'new ([\w.]+)\(\)', default)
        if match:
            target = resolve(match.group(1), context, classes)
            if target is not None and target['name'] in keep:
                return 'n' + short(target['name'])
        return 'o'

    def scheme_kind(code):
        return {'#': 'i', 'i': 'i', 'l': 'l', 'd': 'd', 's': 's', 'y': 'y', 'B': 'b', 't': 'b', 'q': 'y',
                'Q': 'y'}.get(code, 'A' if code.startswith('V') else 'o')

    def short(key):
        # ``TLRPC`` nested classes are bare; classes of ``tgnet/tl/<Outer>.java`` are ``tl.<Outer>$<Name>``.
        return key[6:] if key.startswith('TLRPC$') else 'tl.' + key if key else key

    lines = []
    for key, cls in keep.items():
        own = [f'{name}:{java_kind(kind, default, key)}' for name, kind, default in cls['fields'] if not keyword.iskeyword(name)]
        own += [f'{name}:{scheme_kind(code)}' for name, code in extra.get(key, [])]
        constructor = '' if cls['ctor'] is None else format(cls['ctor'] & 0xffffffff, 'x')
        constants = ' '.join(f'{name}={int(value.rstrip("L"), 0)}' for name, (kind, value) in cls['consts'].items()
                             if kind in ('int', 'long') and re.fullmatch(r'-?\d+L?|-?0x[0-9a-fA-F]+', value))
        lines.append('|'.join([short(key), short(base_key(cls)), constructor, ' '.join(own),
                               wires.get(key, '-' if constructor else ''), results.get(key, ''), constants]).rstrip('|'))
    for key, base, constructor, fields, wire, result in generated:
        own = ' '.join(f'{name}:{scheme_kind(code)}' for name, code in fields)
        lines.append('|'.join([short(key), short(base), format(constructor, 'x'), own, wire, result]).rstrip('|'))
    constants = top_constants(tlrpc)
    layer = dict(constants).get('LAYER')
    if layer is None:
        raise SystemExit('TLRPC.LAYER was not found')
    return '\n'.join(sorted(lines)) + '\n', constants, layer, stats


def render(table, constants, layer):
    payload = base64.b85encode(zlib.compress(table.encode('utf-8'), 9)).decode('ascii')
    rows = '\n'.join('    "' + payload[index:index + 110] + '"' for index in range(0, len(payload), 110))
    return (f'"""Telegram TL class table for ``telegram_tl``; generated by Build/generate_tl_schema.py, do not edit.\n\n'
            f'Layer {layer}: {table.count(chr(10))} classes, {len(table.encode("utf-8"))} bytes of table text stored as\n'
            f'zlib level 9 + base85. The line format is described in the generator.\n"""\n'
            f'LAYER = {layer}\n'
            f'CLASS_COUNT = {table.count(chr(10))}\n'
            f'TABLE_BYTES = {len(table.encode("utf-8"))}\n'
            f'TABLE_SHA256 = "{hashlib.sha256(table.encode("utf-8")).hexdigest()}"\n'
            f'CONSTANTS = "{" ".join(f"{name}={value}" for name, value in constants)}"\n'
            f'TABLE = (\n{rows}\n)\n')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--tlrpc', type=pathlib.Path, required=True, help='Android TLRPC.java')
    parser.add_argument('--tl-dir', type=pathlib.Path, required=True, help='Android tgnet/tl directory')
    parser.add_argument('--scheme', type=pathlib.Path, required=True, help='TL scheme of the layer')
    parser.add_argument('--output', type=pathlib.Path, required=True, help='_telegram_tl_schema.py to write')
    parser.add_argument('--table', type=pathlib.Path, help='Also write the uncompressed table text here')
    args = parser.parse_args(argv)
    table, constants, layer, stats = build(args.tlrpc, args.tl_dir, args.scheme)
    args.output.write_text(render(table, constants, layer), 'utf-8')
    if args.table:
        args.table.write_text(table, 'utf-8')
    print(f'layer {layer}: {table.count(chr(10))} classes, {len(table.encode("utf-8"))} table bytes, '
          f'{args.output.stat().st_size} file bytes; ' + ', '.join(f'{key} {value}' for key, value in sorted(stats.items())))
    return 0


if __name__ == '__main__':
    sys.exit(main())
