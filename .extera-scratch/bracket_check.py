import io
files = [
    'submodules/TelegramUI/Sources/OverlayAudioPlayerLyricsNode.swift',
    'submodules/TelegramUI/Sources/OverlayAudioPlayerControlsNode.swift',
    'submodules/TelegramUI/Sources/ChatHistoryListNode.swift',
    'Swiftgram/SGSimpleSettings/Sources/SimpleSettings.swift',
    'Swiftgram/SGSettingsUI/Sources/SGSettingsController.swift',
    'submodules/TelegramUI/Components/Chat/ChatMessageItemView/Sources/ChatMessageItemView.swift',
    'submodules/TelegramUI/Components/Chat/ChatMessageTextBubbleContentNode/Sources/ChatMessageTextBubbleContentNode.swift',
    'Swiftgram/SGTranslate/Sources/SGHttpProviders.swift',
    'Swiftgram/SGTranslate/Sources/SGTranslate.swift',
]

def strip(src):
    out = []
    i = 0
    n = len(src)
    mode = None
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ''
        if mode is None:
            if c == '/' and nxt == '/':
                mode = 'line'; i += 2; continue
            if c == '/' and nxt == '*':
                mode = 'block'; i += 2; continue
            if c == '"':
                mode = 'str'; i += 1; continue
            out.append(c); i += 1
        elif mode == 'line':
            if c == '\n':
                mode = None; out.append(c)
            i += 1
        elif mode == 'block':
            if c == '*' and nxt == '/':
                mode = None; i += 2
            else:
                i += 1
        else:
            if c == chr(92):
                i += 2; continue
            if c == '"':
                mode = None
            i += 1
    return ''.join(out)

for f in files:
    s = strip(io.open(f, encoding='utf-8').read())
    res = []
    for a, b in [('{', '}'), ('(', ')'), ('[', ']')]:
        if s.count(a) != s.count(b):
            res.append('%s%d/%s%d' % (a, s.count(a), b, s.count(b)))
    print(('OK  ' if not res else 'BAD ') + f + ' ' + ' '.join(res))
