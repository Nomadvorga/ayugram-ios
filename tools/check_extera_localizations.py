"""Check EN/RU exteraGram key parity and explicit UI fallback coverage."""
from collections import Counter
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
PREFIXES = ("Extera.", "Player.Lyrics.", "Ayu.ReadStatus.")
failures = []
languages = {}
read_status_placeholders = {}
for language in ("en", "ru"):
    path = ROOT / f"Swiftgram/SGStrings/Strings/{language}.lproj/SGLocalizable.strings"
    source = path.read_text(encoding="utf-8")
    entries = re.findall(r'^"([^"\n]+)"\s*=\s*"((?:[^"\\\n]|\\.)*)";', source, re.M)
    counts = Counter(key for key, _ in entries if key.startswith(PREFIXES))
    failures.extend(f"{language}: duplicate {key}" for key, count in counts.items() if count > 1)
    languages[language] = set(counts)
    read_status_placeholders[language] = {
        key: set(re.findall(r'\{([A-Za-z]+)\}', value))
        for key, value in entries if key.startswith("Ayu.ReadStatus.")
    }
    for line_number, line in enumerate(source.splitlines(), 1):
        if line.startswith(tuple('"' + prefix for prefix in PREFIXES)) and not re.fullmatch(r'"[^"\n]+"\s*=\s*"(?:[^"\\\n]|\\.)*";', line):
            failures.append(f"{language}:{line_number}: invalid strings entry")

for language, other in (("en", "ru"), ("ru", "en")):
    failures.extend(f"{language}: missing {key}" for key in sorted(languages[other] - languages[language]))
for key in read_status_placeholders["en"].keys() & read_status_placeholders["ru"].keys():
    if read_status_placeholders["en"][key] != read_status_placeholders["ru"][key]:
        failures.append(f"EN/RU placeholder mismatch: {key}")

image = (ROOT / "submodules/GalleryUI/Sources/ExteraImageSearchController.swift").read_text(encoding="utf-8")
feed = (ROOT / "Swiftgram/SGSettingsUI/Sources/ExteraFeedController.swift").read_text(encoding="utf-8")
takeout = (ROOT / "Swiftgram/SGSettingsUI/Sources/ExteraTakeoutController.swift").read_text(encoding="utf-8")
required = set(re.findall(r'"(Extera\.(?:Image|Feed)[A-Za-z0-9]+)"', image + feed))
required.update("Extera.Takeout." + key for key in re.findall(r'self\.text\("([A-Za-z]+)"', takeout))
required.update("Extera.Takeout." + key for key in ("Personal", "Bots", "PrivateGroups", "PublicGroups", "PrivateChannels", "PublicChannels"))
required.update("Extera.StickerTimeMode." + str(value) for value in range(3))
required.update("Extera.StickerShape." + str(value) for value in range(3))
for path in (
    "Swiftgram/SGSettingsUI/Sources/AyuReadHistoryController.swift",
    "Swiftgram/SGSettingsUI/Sources/ExteraFeedController.swift",
    "Swiftgram/SGTelegramUIExtensions/Sources/AyuEditHistoryUI.swift",
):
    required.update(re.findall(r'"(Ayu\.ReadStatus\.[A-Za-z]+)"', (ROOT / path).read_text(encoding="utf-8")))
for language, keys in languages.items():
    failures.extend(f"{language}: missing UI key {key}" for key in sorted(required - keys))

if failures:
    raise SystemExit("\n".join(failures))
print(f"EN/RU localization parity: {len(languages['en'])} keys; {len(required)} explicit UI keys covered")
