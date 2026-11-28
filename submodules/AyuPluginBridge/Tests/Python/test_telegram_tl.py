"""TL object model: generated table, Android field semantics and binary TL, without a host."""
import base64
import hashlib
from pathlib import Path
import sys
import unittest
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Python"))

import _ayu_javalib
import ayu_bridge as bridge
from _ayu_javalib import _telegram_tl_schema as schema
from _ayu_javalib import telegram_tl as tl

R = tl.TLRPC
SCHEMA_FILE = Path(schema.__file__)


def peer_user(user_id=5, access_hash=7):
    peer = R.TL_inputPeerUser()
    peer.user_id, peer.access_hash = user_id, access_hash
    return peer


class SchemaTests(unittest.TestCase):
    def test_table_is_bounded_and_matches_its_recorded_digest(self):
        table = zlib.decompress(base64.b85decode(schema.TABLE))
        self.assertEqual(hashlib.sha256(table).hexdigest(), schema.TABLE_SHA256)
        self.assertEqual((len(table), table.count(b"\n")), (schema.TABLE_BYTES, schema.CLASS_COUNT))
        self.assertEqual(schema.LAYER, R.LAYER)
        self.assertLess(SCHEMA_FILE.stat().st_size, 200_000)
        self.assertLess(schema.TABLE_BYTES, 500_000)
        self.assertLess(schema.CLASS_COUNT, 4000)

    def test_classes_are_registered_under_android_names(self):
        local = _ayu_javalib.local_classes()
        self.assertIs(local["org.telegram.tgnet.TLRPC"], R)
        self.assertIs(local["org.telegram.tgnet.TLRPC$TL_message"], R.TL_message)
        update = local["org.telegram.tgnet.tl.TL_account$updateProfile"]
        self.assertIs(local["org.telegram.tgnet.tl.TL_account"].updateProfile, update)
        self.assertEqual(tl.simple_name(update), "updateProfile")
        self.assertEqual(tl.simple_name(R.TL_messages_sendMessage), "TL_messages_sendMessage")
        self.assertEqual(_ayu_javalib.local_name(R.TL_message()), "org.telegram.tgnet.TLRPC$TL_message")
        self.assertTrue(_ayu_javalib.overrides_host(R.User) and _ayu_javalib.overrides_host(R.Chat))
        self.assertFalse(_ayu_javalib.overrides_host(R.TL_user))
        self.assertEqual(_ayu_javalib.requirements(R.TL_message), ())

    def test_hierarchy_defaults_and_constants_follow_java(self):
        message = R.TL_message()
        self.assertIsInstance(message, R.Message)
        self.assertIsInstance(message, tl.TLObject)
        self.assertNotIsInstance(message, R.TL_messageService)
        self.assertEqual((message.id, message.message, message.attachPath, message.stickerVerified, message.out),
                         (0, None, "", 1, False))
        self.assertEqual(message.entities, [])
        self.assertIsNot(message.entities, R.TL_message().entities)
        self.assertEqual(message.entities.size(), 0)
        self.assertIsNone(message.media)
        self.assertIsInstance(R.Poll().question, R.TL_textWithEntities)
        self.assertEqual(R.TL_inputPeerSelf.constructor & 0xFFFFFFFF, 0x7DA07EC9)
        self.assertLess(R.TL_inputPeerUser.constructor, 0)
        self.assertEqual((R.MESSAGE_FLAG_FWD, R.MESSAGE_FLAG_REPLY), (4, 8))

    def test_unknown_members_fail_explicitly(self):
        message = R.TL_message()
        with self.assertRaises(AttributeError):
            message.not_a_field = 1
        with self.assertRaises(bridge.UnsupportedAPI):
            message.not_a_field
        self.assertFalse(hasattr(message, "not_a_field"))
        self.assertFalse(hasattr(R, "TL_not_a_registered_type"))
        with self.assertRaises(bridge.UnsupportedAPI):
            tl.encode(R.Message())


class WireTests(unittest.TestCase):
    def test_known_constructors_serialize_to_exact_bytes(self):
        self.assertEqual(tl.encode(R.TL_inputPeerSelf()).hex(), "c97ea07d")
        self.assertEqual(tl.encode(peer_user(123456789012, -5)).hex(), "4ca5e8dd141a99be1c000000fbffffffffffffff")
        error = R.TL_error()
        error.code, error.text = 400, "PEER_ID_INVALID"
        self.assertEqual(tl.encode(error).hex(),
                         "bbf9b9c4" + "90010000" + "0f" + b"PEER_ID_INVALID".hex())
        request = R.TL_messages_getHistory()
        request.peer, request.limit, request.offset_id = R.TL_inputPeerSelf(), 20, -1
        self.assertEqual(tl.encode(request).hex(),
                         "c5e62344" + "c97ea07d" + "ffffffff" + "00000000" * 2 + "14000000" + "00000000" * 4)

    def test_strings_and_bytes_use_tl_padding(self):
        stream = tl.SerializedData()
        stream.writeString("é")
        stream.writeByteArray(b"x" * 254)
        data = stream.toByteArray()
        self.assertEqual(data[:4], b"\x02\xc3\xa9\x00")
        self.assertEqual(data[4:8], b"\xfe\xfe\x00\x00")
        self.assertEqual(len(data), 4 + 4 + 254 + 2)
        reader = tl.SerializedData(data)
        self.assertEqual((reader.readString(True), reader.readByteArray(True), reader.remaining()), ("é", b"x" * 254, 0))

    def test_flags_follow_android_rules(self):
        request = R.TL_messages_sendMessage()
        request.peer, request.message, request.random_id = peer_user(), "hi", 9
        request.silent = True
        entity = R.TL_messageEntityBold()
        entity.offset, entity.length = 0, 2
        request.entities.add(entity)
        # Android writes an optional field only when the caller set its flag bit.
        without = tl.decode(tl.encode(request))
        self.assertEqual((request.flags, without.silent, len(without.entities)), (32, True, 0))
        request.flags |= 8
        request.silent = False
        decoded = tl.decode(tl.encode(request))
        self.assertEqual((request.flags, decoded.silent, decoded.entities[0].length, decoded.peer.user_id), (8, False, 2, 5))
        self.assertIsInstance(decoded.entities[0], R.MessageEntity)
        # A flag Android derives from the value is derived here too.
        request.rich_message = None
        request.flags |= 1 << 23
        tl.encode(request)
        self.assertEqual(request.flags & (1 << 23), 0)
        self.assertEqual(request.getObjectSize(), len(tl.encode(request)))

    def test_missing_required_values_are_errors(self):
        request = R.TL_messages_sendMessage()
        request.peer = peer_user()
        with self.assertRaises(TypeError):
            tl.encode(request)
        request.message = "x"
        request.random_id = 2 ** 64
        with self.assertRaises(ValueError):
            tl.encode(request)

    def test_java_integers_are_range_checked_not_wrapped(self):
        for value in (2 ** 63, -2 ** 63 - 1):
            with self.assertRaisesRegex(ValueError, r"TL_inputPeerUser\.user_id = -?\d+ is outside the signed 64-bit range"):
                tl.encode(peer_user(value))
        edge = tl.decode(tl.encode(peer_user(-2 ** 63, 2 ** 63 - 1)))
        self.assertEqual((edge.user_id, edge.access_hash), (-2 ** 63, 2 ** 63 - 1))
        entity = R.TL_messageEntityBold()
        entity.offset = 2 ** 31
        with self.assertRaisesRegex(ValueError, r"TL_messageEntityBold\.offset"):
            tl.encode(entity)
        entity.offset = True
        with self.assertRaises(TypeError):
            tl.encode(entity)
        # A flags word is 32 unsigned bits: the top bit is kept and read back as Java's negative int.
        rights = R.TL_chatAdminRights()
        rights.flags = 0x80000000
        self.assertEqual(tl.decode(tl.encode(rights)).flags, -2 ** 31)
        stream = tl.SerializedData()
        stream.writeInt32(tl.BOOL_TRUE)
        stream.writeInt64(-1)
        self.assertEqual(stream.toByteArray().hex(), "b5757299" + "ff" * 8)
        for write, value in ((stream.writeInt64, 2 ** 63), (stream.writeInt32, 2 ** 32), (stream.writeInt32, -2 ** 31 - 1)):
            with self.assertRaises(ValueError):
                write(value)

    def test_host_snapshot_handles_are_classified_or_refused(self):
        user, chat, other = (bridge.RemoteObject(bridge.runtime, None, "h", name) for name in (
            "org.telegram.tgnet.TLRPC$User", "org.telegram.tgnet.TLRPC$Chat", "android.content.Context"))
        self.assertEqual([isinstance(user, R.User), isinstance(user, tl.TLObject), isinstance(chat, R.Chat),
                          isinstance(user, R.Chat), isinstance(chat, R.TL_user), isinstance(other, R.User),
                          isinstance(other, tl.TLObject), isinstance(R.TL_user(), R.User), isinstance(5, R.User)],
                         [True, True, True, False, False, False, False, True, False])
        # Which constructor a snapshot is cannot be known, so the question is refused instead of answered "no".
        for cls, handle in ((R.TL_channel, chat), (R.TL_chat, chat), (R.TL_userEmpty, user)):
            with self.assertRaises(bridge.UnsupportedAPI):
                isinstance(handle, cls)
        request = R.TL_users_getUsers()
        request.id.add(user)
        for value in (user, request):
            with self.assertRaisesRegex(TypeError, "local TLObject"):
                tl.encode(value)

    def test_older_request_layout_kept_by_android_is_serialized(self):
        request = R.TL_channels_getMessages()
        request.channel = R.TL_inputChannel()
        request.channel.channel_id, request.channel.access_hash = 3, 4
        request.id.add(5)
        self.assertEqual(tl.encode(request).hex(), "47b3d793" + "28ec5af3" + "03" + "00" * 7 + "04" + "00" * 7
                         + "15c4b51c" + "01000000" + "05000000")

    def test_responses_decode_objects_bools_and_vectors(self):
        request = R.TL_messages_getMessagesViews()
        self.assertTrue(tl.is_function(type(request)))
        self.assertFalse(tl.is_function(R.TL_message))
        search = R.TL_messages_deleteChatUser()
        self.assertIsInstance(tl.decode_response(search, bytes.fromhex("b5757299")), tl.TLObject)
        vector_request = next(cls for cls in tl._BY_ID.values() if cls._ayu_result == "Vi")
        data = bytes.fromhex("15c4b51c" + "02000000" + "07000000" + "ffffffff")
        vector = tl.decode_response(vector_request, data)
        self.assertIsInstance(vector, tl.Vector)
        self.assertEqual(list(vector.toIntArray()), [7, -1])
        self.assertEqual(tl.encode(vector), data)
        with self.assertRaises(tl.TLParseException):
            tl.decode_response(vector_request, bytes.fromhex("c97ea07d"))

    def test_decode_rejects_unknown_truncated_and_trailing_data(self):
        good = tl.encode(peer_user())
        for data in (b"\x01\x02\x03\x04", good[:-1], good + b"\0\0\0\0", b""):
            with self.subTest(data=data), self.assertRaises(tl.TLParseException):
                tl.decode(data)
        with self.assertRaises(tl.TLParseException):
            tl.decode(good, R.Message)
        self.assertIsInstance(tl.decode(good, R.InputPeer), R.TL_inputPeerUser)
        huge_vector = bytes.fromhex("15c4b51c" + "ffffff7f")
        with self.assertRaises(tl.TLParseException):
            tl._read_value(tl.SerializedData(huge_vector), "Vi", 0)

    def test_nesting_is_bounded(self):
        outer = current = R.TL_inputPeerUserFromMessage()
        for _ in range(tl.MAX_DEPTH + 2):
            current.peer = R.TL_inputPeerUserFromMessage()
            current = current.peer
        current.peer = R.TL_inputPeerSelf()
        with self.assertRaises(ValueError):
            tl.encode(outer)
        current = shallow = R.TL_inputPeerUserFromMessage()
        for _ in range(8):
            current.peer = R.TL_inputPeerUserFromMessage()
            current = current.peer
        current.peer = R.TL_inputPeerSelf()
        self.assertIsInstance(tl.decode(tl.encode(shallow)).peer.peer, R.TL_inputPeerUserFromMessage)

    def test_stream_api_and_android_deserializers(self):
        data = tl.encode(peer_user(11, 12))
        stream = tl.SerializedData(data)
        constructor = stream.readInt32(False)
        self.assertLess(constructor, 0)
        self.assertIsNone(R.Message.TLdeserialize(tl.SerializedData(data[4:]), constructor, False))
        with self.assertRaises(tl.TLParseException):
            R.Message.TLdeserialize(tl.SerializedData(data[4:]), constructor, True)
        peer = R.InputPeer.TLdeserialize(stream, constructor, False)
        self.assertEqual((peer.user_id, peer.access_hash, stream.remaining()), (11, 12, 0))
        buffer = tl.NativeByteBuffer(peer.getObjectSize())
        peer.serializeToStream(buffer)
        self.assertEqual((buffer.position(), buffer.remaining()), (len(data), 0))
        buffer.rewind()
        copy = R.TL_inputPeerUser()
        self.assertEqual(buffer.readInt32(True), constructor)
        copy.readParams(buffer, True)
        self.assertEqual(copy.user_id, 11)
        with self.assertRaises(IndexError):
            buffer.writeInt32(1)
        self.assertEqual(tl.SerializedData(b"").readInt32(False), 0)
        with self.assertRaises(tl.TLParseException):
            tl.SerializedData(b"").readInt32(True)

    def test_byte_fields_accept_java_style_arrays(self):
        document = R.TL_document()
        document.file_reference, document.mime_type = [-1, 0, 127], "a/b"
        decoded = tl.decode(tl.encode(document))
        self.assertEqual(decoded.file_reference, b"\xff\x00\x7f")
        document.file_reference = [300]
        with self.assertRaises(TypeError):
            tl.encode(document)

    def test_bridge_wire_form(self):
        wire = peer_user().to_bridge()
        self.assertEqual(set(wire), {"tl"})
        self.assertEqual(base64.b64decode(wire["tl"]), tl.encode(peer_user()))
        self.assertIsInstance(tl.from_bridge(wire, R.InputPeer), R.TL_inputPeerUser)
        self.assertIsNone(tl.from_bridge(None))
        for bad in ({"tl": "***"}, {"tl": 1}, {"tl": wire["tl"], "extra": 1}, "text", {"tl": base64.b64encode(b"1234").decode()}):
            with self.subTest(bad=bad), self.assertRaises(bridge.ProtocolError):
                tl.from_bridge(bad)
        with self.assertRaises(bridge.ProtocolError):
            tl.from_bridge(wire, R.Message)

    def test_hook_name_lookup(self):
        self.assertEqual(tl.classes_named("TL_messages_sendMessage"), [R.TL_messages_sendMessage])
        named = tl.classes_named("updateProfile")
        self.assertIn(_ayu_javalib.local_class("org.telegram.tgnet.tl.TL_account$updateProfile"), named)
        self.assertGreater(len(tl.classes_named("TL_messages_send", True)), 5)
        self.assertEqual(tl.classes_named("TL_messages_send"), [])
        self.assertIs(tl.class_for(R.TL_inputPeerSelf.constructor), R.TL_inputPeerSelf)


if __name__ == "__main__":
    unittest.main()
