"""Source/API audit runnable on Windows; does not typecheck Swift or call Telegram."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / "submodules/TelegramCore/Sources/TelegramEngine/Messages"
schema = (ROOT / "submodules/TelegramApi/swift_scheme.tl").read_text(encoding="utf-8")
source = (CORE / "ExteraTakeoutExport.swift").read_text(encoding="utf-8")

for name, constructor in {"invokeWithTakeout": 0xACA9FD2E, "invokeWithMessagesRange": 0x365275F2, "messageRange": 0x0AE30253}.items():
    found = re.search(rf"^{name}#([0-9a-f]+)\b", schema, re.M)
    assert found and int(found[1], 16) == constructor, name
    assert f"0x{constructor:08x}" in source, name

expected = {
    "account.initTakeoutSession": ["flags", "fileMaxSize"],
    "account.finishTakeoutSession": ["flags"],
    "messages.getSplitRanges": [],
    "messages.getDialogs": ["flags", "folderId", "offsetDate", "offsetId", "offsetPeer", "limit", "hash"],
    "messages.getHistory": ["peer", "offsetId", "offsetDate", "addOffset", "limit", "maxId", "minId", "hash"],
    "channels.getLeftChannels": ["offset"],
    "upload.getFile": ["flags", "location", "offset", "limit"],
}
def camel(value):
    return re.sub(r"_([a-z])", lambda m: m[1].upper(), value)
for name, arguments in expected.items():
    line = re.search(rf"^{re.escape(name)}#[^\n]+", schema, re.M)[0]
    declared = [camel(field) for field, kind in re.findall(r"\b([a-z_]+):([^ ]+)", line) if not kind.endswith("?true")]
    assert declared == arguments, (name, declared, arguments)
    assert "Api.functions." + name + "(" in source, name

for constructor, expected_fields in {
    "inputPeerUser": ["user_id", "access_hash"],
    "inputPeerChannel": ["channel_id", "access_hash"],
    "inputPeerChat": ["chat_id"],
    "inputDocumentFileLocation": ["id", "access_hash", "file_reference", "thumb_size"],
    "inputPhotoFileLocation": ["id", "access_hash", "file_reference", "thumb_size"],
}.items():
    line = re.search(rf"^{constructor}#[^\n]+", schema, re.M)[0]
    assert re.findall(r"\b([a-z_]+):[^ ]+", line) == expected_fields, constructor

assert "payload.append(function.1.makeData())" in source
assert "appendBuffer(" not in source  # Buffer.appendBuffer does not advance size in this checkout.
assert "automaticFloodWait: false" in source
assert "self.finish(success: false" in source
assert "self.writer?.closeAndRemove()" in source
for path in (ROOT / "AyuGram/SGSettingsUI/Sources").glob("ExteraTakeout*.swift"):
    assert "import TelegramApi" not in path.read_text(encoding="utf-8")
print("PASS: 3 wrapper constructors, 7 generated request signatures, Core-only API imports, cleanup source paths")

for path in [*CORE.glob("ExteraTakeout*.swift"), * (ROOT / "AyuGram/SGSettingsUI/Sources").glob("ExteraTakeout*.swift"), *Path(__file__).parent.glob("*")]:
    if not path.is_file():
        continue
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        assert line.rstrip() == line, (path, number, "trailing whitespace")
        assert not line.startswith(("<<<<<<<", "=======", ">>>>>>>")), (path, number, "merge marker")
print("PASS: new takeout files have no trailing whitespace or conflict markers")

# If a production Swift test archive is supplied, validate using an independent ZIP reader.
import sys
if len(sys.argv) > 1:
    import zipfile
    import json
    with zipfile.ZipFile(sys.argv[1]) as archive:
        assert archive.testzip() is None
        assert set(archive.namelist()) == {"result.json", "index.html", "manifest.json", "media/1.bin"}
        assert archive.read("media/1.bin") == bytes([0, 1, 2, 3, 255])
        assert len(json.loads(archive.read("result.json"))["chats"]) == 2
    print("PASS: independent ZIP CRC, file-name, binary media and JSON verification")
