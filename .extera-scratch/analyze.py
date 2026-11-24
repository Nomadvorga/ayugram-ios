import re, collections
paths = open('.extera-scratch/paths.txt', encoding='utf-8').read().splitlines()
custom = [p for p in paths if re.search(r'neko|extera', p, re.I) and not p.endswith('.png')]
dirs = collections.Counter()
for p in custom:
    d = re.sub(r'/[^/]*\.(java|kt)$', '/', p)
    dirs[d] += 1
for d, n in dirs.most_common(60):
    print(n, d)
