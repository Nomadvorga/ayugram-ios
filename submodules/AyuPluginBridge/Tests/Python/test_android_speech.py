"""``android.speech.tts.TextToSpeech`` against a synthetic host: Android's object model over ``speech.*``."""
import json
import re
import unittest
from pathlib import Path

import test_bridge as harness
import ayu_bridge as bridge
import _ayu_javalib as javalib
from _ayu_javalib import android_speech as speech
from _ayu_javalib.java_util import Locale

TTS = "android.speech.tts.TextToSpeech"
OPERATIONS = list(speech.OPERATIONS)


class SpeechCase(unittest.TestCase):
    load = harness.BridgeTests.load
    tearDown = harness.BridgeTests.tearDown

    def setUp(self):
        harness.BridgeTests.setUp(self)
        self.host.capabilities["operations"] += OPERATIONS
        self.calls, self.languages, self.speaking = [], {"ru-RU": 1, "ru": 0, "en-US": 1, "en": 0}, False
        perform = self.host.perform

        def answering(request):
            operation, arguments = request["operation"], request["arguments"]
            if operation in OPERATIONS:
                self.calls.append((operation, arguments))
                if operation == "speech.language":
                    return self.languages.get(arguments["language"], -2)
                return self.speaking if operation == "speech.speaking" else None
            return perform(request)
        self.host.perform = answering

    def run_scheduled(self, scope):
        """Delivers every callback the plugin scheduled so far, as the host's main queue would."""
        pending = [(token, record) for token, record in self.host.tokens.items() if "queue" in record[1]]
        for token, (owner, arguments) in pending:
            del self.host.tokens[token]
            bridge.invoke_callback_json(json.dumps({"version": 1, "plugin_id": owner, "arguments": [],
                                                    "callback_id": arguments["callback"]["$callback"]}))
        return len(pending)


class TextToSpeechTests(SpeechCase):
    def test_the_engine_binds_after_the_constructor_and_then_speaks(self):
        scope = self.load()
        statuses = []
        with bridge.runtime.context(scope):
            cls = javalib.local_class(TTS, bridge.runtime.capabilities["operations"])
            self.assertIs(cls, speech.TextToSpeech)

            class Listener(cls.OnInitListener):
                def onInit(self, status):
                    statuses.append(status)
            tts = cls(None, Listener(), "com.google.android.tts")
            # Not bound yet: Android answers ERROR, and no host call is made.
            self.assertEqual((tts.speak("early", cls.QUEUE_FLUSH, None, "id"), tts.stop(), tts.setLanguage(Locale("ru", "RU")),
                              tts.setSpeechRate(2.0), tts.isSpeaking(), statuses), (cls.ERROR, cls.ERROR, cls.LANG_NOT_SUPPORTED,
                                                                                  cls.ERROR, False, []))
            self.assertEqual(self.calls, [])
        self.assertEqual(self.run_scheduled(scope), 1)
        self.assertEqual(statuses, [speech.TextToSpeech.SUCCESS])
        with bridge.runtime.context(scope):
            self.assertEqual(tts.speak("Привет", cls.QUEUE_FLUSH, None, "id"), cls.SUCCESS)
            self.assertEqual(tts.setLanguage(Locale("ru", "RU")), cls.LANG_COUNTRY_AVAILABLE)
            self.assertEqual(tts.setLanguage(Locale("de", "DE")), cls.LANG_NOT_SUPPORTED)
            self.assertEqual((tts.isLanguageAvailable(Locale("en")), tts.setSpeechRate(1.5), tts.setPitch(0.8)), (cls.LANG_AVAILABLE, 0, 0))
            self.assertEqual(tts.speak("ещё", cls.QUEUE_ADD, None), cls.SUCCESS)             # the HashMap overload
            self.speaking = True
            self.assertEqual((tts.isSpeaking(), tts.stop()), (True, cls.SUCCESS))
            self.assertEqual([call for call in self.calls if call[0] != "speech.language"], [
                ("speech.speak", {"text": "Привет", "flush": True, "language": None, "rate": 1.0, "pitch": 1.0}),
                ("speech.speak", {"text": "ещё", "flush": False, "language": "ru-RU", "rate": 1.5, "pitch": 0.8}),
                ("speech.speaking", {}), ("speech.stop", {})])
            self.assertEqual([call[1]["language"] for call in self.calls if call[0] == "speech.language"], ["ru-RU", "de-DE", "en"])
            self.calls.clear()
            # What Android refuses is refused without a host call.
            self.assertEqual((tts.speak(None, 0, None, None), tts.speak("x" * 4001, 0, None, None), tts.speak("x", 2, None, None),
                              tts.setSpeechRate(0), tts.setPitch(-1.0)), (cls.ERROR,) * 5)
            self.assertEqual(tts.speak("x" * 4000, 0, None, None), cls.SUCCESS)
            self.assertEqual(len(self.calls), 1)
            for call in (lambda: tts.speak("x", "0", None, None), lambda: tts.speak("x", 0, None, 5), lambda: tts.speak("x", 0, None, "a", "b"),
                         lambda: tts.setSpeechRate("fast"), lambda: tts.setLanguage("ru")):
                with self.assertRaises((TypeError, AttributeError)):
                    call()
            with self.assertRaises(speech._l.NullPointerException):
                tts.setLanguage(None)
            # A locale the host cannot read as a language tag has no voice; the host is not asked.
            self.assertEqual((tts.setLanguage(Locale("x")), tts.isLanguageAvailable(Locale("русский", "RU")), tts.setLanguage(Locale("", "US")),
                              tts.isLanguageAvailable(Locale("en", "U S"))), (cls.LANG_NOT_SUPPORTED,) * 4)
            self.assertEqual(len(self.calls), 1)
            tts.shutdown()
            self.assertEqual(self.calls[-1], ("speech.stop", {}))
            self.calls.clear()
            self.assertEqual((tts.speak("late", 0, None, None), tts.stop(), tts.isSpeaking()), (cls.ERROR, cls.ERROR, False))
            tts.shutdown()
            self.assertEqual(self.calls, [])
            self.assertEqual((cls.getMaxSpeechInputLength(), cls.SUCCESS, cls.ERROR, cls.QUEUE_FLUSH, cls.QUEUE_ADD), (4000, 0, -1, 0, 1))

    def test_a_shutdown_before_binding_never_reports_success(self):
        scope = self.load()
        statuses = []
        with bridge.runtime.context(scope):
            tts = speech.TextToSpeech(None, type("Listener", (speech.OnInitListener,), {"onInit": lambda self, status: statuses.append(status)})())
            tts.shutdown()
            silent = speech.TextToSpeech(None, None)
        self.assertEqual(self.run_scheduled(scope), 2)
        self.assertEqual(statuses, [])
        with bridge.runtime.context(scope):
            self.assertEqual((tts.speak("x", 0, None, None), silent.speak("x", 0, None, None)), (-1, 0))
            for listener in (object(), 5):
                with self.assertRaises(TypeError):
                    speech.TextToSpeech(None, listener)
            with self.assertRaises(TypeError):
                speech.TextToSpeech(None, None, 7)
            self.languages["ru-RU"] = 7
            self.run_scheduled(scope)
            with self.assertRaises(bridge.ProtocolError):
                silent.setLanguage(Locale("ru", "RU"))


class SpeechPreflightTests(unittest.TestCase):
    setUp = harness.BridgeTests.setUp
    tearDown = harness.BridgeTests.tearDown

    SOURCE = ("from java import dynamic_proxy\nfrom hook_utils import find_class\nfrom android_utils import run_on_ui_thread\n"
              "TextToSpeech = find_class('android.speech.tts.TextToSpeech')\nLocale = find_class('java.util.Locale')\n")
    BODY = ("    def on_plugin_load(self):\n"
            "        OnInitListener = find_class('android.speech.tts.TextToSpeech$OnInitListener')\n"
            "        class Listener(dynamic_proxy(OnInitListener)):\n"
            "            def onInit(self, status):\n                self.ok = status == TextToSpeech.SUCCESS\n"
            "        self.tts = TextToSpeech(None, Listener(), 'com.google.android.tts')\n"
            "        self.tts.setLanguage(Locale.getDefault())\n"
            "        self.tts.speak('text', TextToSpeech.QUEUE_FLUSH, None, 'id')\n"
            "        self.tts.stop()\n        self.tts.shutdown()\n")

    def blockers(self):
        report = json.loads(bridge.preflight_plugin_json(harness.source("speech", self.BODY, self.SOURCE)))
        return sorted((item["code"], item["detail"]) for item in report["blockers"])

    def test_the_classes_exist_only_with_every_speech_operation(self):
        # The listener interface is plain Python; the engine class is what needs the host.
        self.assertEqual(self.blockers(), [("CLASS", TTS)])
        self.host.capabilities["operations"] += OPERATIONS[:-1]
        self.assertEqual(self.blockers(), [("CLASS", TTS)])
        self.host.capabilities["operations"] += OPERATIONS[-1:]
        self.assertEqual(self.blockers(), [])
        self.assertEqual(javalib.missing_operations(TTS, ["scheduler.schedule"]), tuple(OPERATIONS))


class SpeechWiringTests(unittest.TestCase):
    """The Swift side serves exactly the operations the class needs, on every layer a call passes."""

    def test_the_host_declares_routes_and_releases_the_speech_operations(self):
        root = Path(__file__).resolve().parents[2]
        names = ", ".join(f'"{name}"' for name in OPERATIONS)
        provider = (root / "Integration/AyuPluginSpeech.swift").read_text(encoding="utf-8")
        self.assertIn(f"public static let operations = [{names}]", provider)
        # The native host forwards only the operations it names; anything else is UNSUPPORTED_API.
        host = (root / "Sources/AyuPluginNativeHost.swift").read_text(encoding="utf-8")
        self.assertIn(f"             {names},\n", host)
        composite = (root / "Integration/AyuPluginMenuBridge.swift").read_text(encoding="utf-8")
        composite = composite[composite.index("public final class AyuPluginMenuHostProvider"):]
        self.assertIn("+ self.speech.capabilities }", composite)
        self.assertIn('if operation.hasPrefix("speech.") { return try self.speech.prepareCall(', composite)
        self.assertIn("self.speech.detach(pluginID: pluginID)", composite)
        self.assertEqual(speech._MAX_INPUT, int(re.search(r"static let maximumTextUnits = (\d+)", provider).group(1)))


if __name__ == "__main__":
    unittest.main()
