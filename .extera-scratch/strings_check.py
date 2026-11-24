import io
import re

s = io.open('Swiftgram/SGStrings/Strings/en.lproj/SGLocalizable.strings', encoding='utf-8').read()
bad = []
for line in s.splitlines():
    stripped = line.strip()
    if not stripped or stripped.startswith('/*') or stripped.startswith('//'):
        continue
    if not re.match(r'^"[^"]+" = ".*";$', stripped):
        bad.append(stripped)
print('strings entries checked, bad:', len(bad))
for b in bad[:5]:
    print(b)
