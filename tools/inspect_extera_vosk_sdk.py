"""Inspect already SHA-256 verified Temp SDK without Apple developer tools."""
import collections
import hashlib
import json
from pathlib import Path
import struct
import tempfile

CACHE = Path(tempfile.gettempdir()) / 'opencode/extera-vosk-artifacts'
ARCHES = {0x100000c: 'arm64', 0x1000007: 'x86_64', 12: 'arm'}
PLATFORMS = {1: 'macOS', 2: 'iOS', 7: 'iOS Simulator'}
REQUIRED = {'_vosk_model_new','_vosk_model_free','_vosk_recognizer_new',
            '_vosk_recognizer_accept_waveform','_vosk_recognizer_result',
            '_vosk_recognizer_final_result','_vosk_recognizer_free','_vosk_set_log_level'}

def version(n):
    return f'{n >> 16}.{(n >> 8) & 255}.{n & 255}'

def macho(data):
    if data[:4] not in [b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe']:
        return None
    is64 = data[:4] == b'\xcf\xfa\xed\xfe'
    _, cpu, subtype, kind, ncmds, _, _ = struct.unpack_from('<7I', data)
    pos = 32 if is64 else 28
    result = {'arch': ARCHES.get(cpu,str(cpu)), 'subtype':subtype, 'platforms':[], 'defined':set(), 'undefined':set()}
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II',data,pos)
        if cmd == 0x32:
            platform, minimum, sdk, _ = struct.unpack_from('<IIII',data,pos+8)
            result['platforms'].append((PLATFORMS.get(platform,str(platform)),version(minimum),version(sdk)))
        elif cmd in [0x24,0x25,0x2f,0x30]:
            minimum, sdk = struct.unpack_from('<II',data,pos+8)
            result['platforms'].append(({0x24:'macOS legacy',0x25:'iOS legacy',0x2f:'tvOS legacy',0x30:'watchOS legacy'}[cmd],version(minimum),version(sdk)))
        elif cmd == 2:
            symoff,nsyms,stroff,strsize=struct.unpack_from('<IIII',data,pos+8)
            strings=data[stroff:stroff+strsize]
            for i in range(nsyms):
                strx,typ,sect,desc,value=struct.unpack_from('<IBBHQ' if is64 else '<IBBHI',data,symoff+i*(16 if is64 else 12))
                if typ & 0xe0 or not typ & 1 or strx >= len(strings): continue
                name=strings[strx:strings.find(b'\0',strx)].decode('utf-8',errors='replace')
                result['undefined' if typ & 0x0e == 0 and value == 0 else 'defined'].add(name)
        pos += size
    return result

def members(data):
    assert data[:8] == b'!<arch>\n'
    pos=8
    while pos+60 <= len(data):
        header=data[pos:pos+60]
        size=int(header[48:58])
        name=header[:16].decode().strip()
        body=data[pos+60:pos+60+size]
        if name.startswith('#1/'):
            n=int(name[3:]); name=body[:n].rstrip(b'\0').decode(errors='replace');body=body[n:]
        yield name,body
        pos += 60+size+(size%2)

def inspect(path):
    data=path.read_bytes()
    fat=[]
    if data[:4]==b'\xca\xfe\xba\xbe':
        for i in range(struct.unpack_from('>I',data,4)[0]):
            cpu,subtype,offset,size,align=struct.unpack_from('>5I',data,8+i*20)
            fat.append((ARCHES.get(cpu,str(cpu)),subtype,data[offset:offset+size]))
    else: fat=[('thin',0,data)]
    results=[]
    for arch,subtype,body in fat:
        defined=set();undefined=set();platforms=collections.Counter();objects=0;examples={}
        for name,obj in members(body):
            info=macho(obj)
            if info:
                objects+=1;defined.update(info['defined']);undefined.update(info['undefined'])
                for p in info['platforms']: platforms[p]+=1;examples.setdefault(str(p),name)
        unresolved=sorted(undefined-defined)
        results.append({'arch':arch,'subtype':subtype,'archiveBytes':len(body),'objects':objects,
                        'platforms':[{'platform':p[0],'minOS':p[1],'sdk':p[2],'objects':n} for p,n in platforms.items()],
                        'examples':examples,'requiredMissing':sorted(REQUIRED-defined),
                        'unresolvedSymbols':unresolved})
    return {'path':str(path),'sha256':hashlib.sha256(data).hexdigest(),'slices':results}

if __name__=='__main__':
    report=[inspect(p) for p in (CACHE/'sdk').rglob('*.a')]
    (CACHE/'sdk-mach-o.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    for library in report:
        for slice in library['slices']:
            print(json.dumps({'path':library['path'],**{k:v for k,v in slice.items() if k!='unresolvedSymbols'}},indent=2))
            print('Unresolved external symbols:',len(slice['unresolvedSymbols']))
    print('Complete symbol report:',CACHE/'sdk-mach-o.json')
