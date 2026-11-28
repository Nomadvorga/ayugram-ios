"""``android.speech.tts.TextToSpeech`` over the host's speech synthesizer (``speech.*`` operations).

The object model is Android's: the engine binds after the constructor returns, the listener's
``onInit`` then runs on the main queue, and until then (and after ``shutdown``) every call answers
``ERROR``. What is spoken, in which voice, how fast and at which pitch is the host's.

Deviations: there is one engine, the system's, whatever engine package the constructor names;
``Bundle`` parameters of ``speak`` (volume, pan, stream) are ignored; utterance progress
listeners, earcons, ``synthesizeToFile``, ``playSilentUtterance`` and voice objects are not
implemented, so their use stays a preflight blocker.
"""
from __future__ import annotations

import re

from . import java_lang as _l
from .java_lang import Object

OPERATIONS = ("speech.speak", "speech.stop", "speech.language", "speech.speaking")
_MAX_INPUT = 4000
# What the host reads as a language tag; any other locale has no voice.
_TAG = re.compile(r"[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})?")


def _runtime():
    from ayu_bridge import runtime
    return runtime


def _local(value, what):
    from ayu_bridge import JavaClass, RemoteObject
    if isinstance(value, (RemoteObject, JavaClass)):
        raise _l.unsupported("A host object cannot be used as a " + what + " by a Python-local class")
    return value


def _language_tag(locale):
    """``language[-COUNTRY]`` of a ``java.util.Locale``, the host's or the local one."""
    if locale is None:
        raise _l.NullPointerException("loc is null")
    language, country = locale.getLanguage(), locale.getCountry()
    if not isinstance(language, str) or not isinstance(country, str) or len(language) > 16 or len(country) > 16:
        raise TypeError("Expected a java.util.Locale")
    return language + ("-" + country if country else "") if language else ""


class OnInitListener(Object):
    def onInit(self, status):
        raise NotImplementedError("TextToSpeech.OnInitListener.onInit is abstract")


class TextToSpeech(Object):
    __ayu_requires__ = OPERATIONS + ("scheduler.schedule",)

    SUCCESS, ERROR, STOPPED = 0, -1, -2
    QUEUE_FLUSH, QUEUE_ADD = 0, 1
    LANG_COUNTRY_VAR_AVAILABLE, LANG_COUNTRY_AVAILABLE, LANG_AVAILABLE = 2, 1, 0
    LANG_MISSING_DATA, LANG_NOT_SUPPORTED = -1, -2
    ERROR_SYNTHESIS, ERROR_SERVICE, ERROR_OUTPUT, ERROR_NETWORK, ERROR_NETWORK_TIMEOUT = -3, -4, -5, -6, -7
    ERROR_INVALID_REQUEST, ERROR_NOT_INSTALLED_YET = -8, -9
    OnInitListener = OnInitListener

    def __init__(self, context, listener, engine=None):
        """``(context, listener)`` and ``(context, listener, engine)``: the engine name is not used."""
        if engine is not None and not isinstance(engine, str):
            raise TypeError("engine must be a String")
        on_init = None
        if listener is not None:
            on_init = getattr(_local(listener, "TextToSpeech.OnInitListener"), "onInit", None)
            if not callable(on_init):
                raise TypeError("Expected a TextToSpeech.OnInitListener")
        self._bound = self._closed = False
        self._language = None
        self._rate = self._pitch = 1.0

        def bind():
            if self._closed:
                return
            self._bound = True
            if on_init is not None:
                on_init(TextToSpeech.SUCCESS)
        import client_utils
        client_utils.run_on_ui_thread(bind)

    @staticmethod
    def getMaxSpeechInputLength():
        return _MAX_INPUT

    def _usable(self):
        return self._bound and not self._closed

    def setLanguage(self, loc):
        tag = _language_tag(loc)
        if not self._usable() or not _TAG.fullmatch(tag):
            return TextToSpeech.LANG_NOT_SUPPORTED
        result = self._available(tag)
        if result >= TextToSpeech.LANG_AVAILABLE:
            self._language = tag
        return result

    def isLanguageAvailable(self, loc):
        tag = _language_tag(loc)
        return self._available(tag) if self._usable() and _TAG.fullmatch(tag) else TextToSpeech.LANG_NOT_SUPPORTED

    @staticmethod
    def _available(tag):
        result = _runtime().call("speech.language", {"language": tag})
        if type(result) is not int or result not in (TextToSpeech.LANG_COUNTRY_AVAILABLE, TextToSpeech.LANG_AVAILABLE,
                                                     TextToSpeech.LANG_NOT_SUPPORTED):
            from ayu_bridge import ProtocolError
            raise ProtocolError("Host returned an invalid language availability")
        return result

    def _factor(self, value, what):
        if type(value) not in (int, float) or value != value:
            raise TypeError(what + " must be a float")
        if not self._usable():
            return None
        # Android stores any positive value; the host bounds what its synthesizer can do.
        return float(value) if value > 0 else None

    def setSpeechRate(self, speechRate):
        value = self._factor(speechRate, "speechRate")
        if value is None:
            return TextToSpeech.ERROR
        self._rate = value
        return TextToSpeech.SUCCESS

    def setPitch(self, pitch):
        value = self._factor(pitch, "pitch")
        if value is None:
            return TextToSpeech.ERROR
        self._pitch = value
        return TextToSpeech.SUCCESS

    def speak(self, text, queueMode, params, *utterance):
        """``(text, queueMode, Bundle params, utteranceId)`` and the older ``(text, queueMode, HashMap params)``."""
        if len(utterance) > 1 or utterance and utterance[0] is not None and not isinstance(utterance[0], str):
            raise TypeError("speak(text, queueMode, params, utteranceId)")
        if type(queueMode) is not int:
            raise TypeError("queueMode must be an int")
        if text is not None and not isinstance(text, str):
            text = text.toString()
        if not self._usable() or text is None or len(_l.units(text)) > _MAX_INPUT or queueMode not in (0, 1):
            return TextToSpeech.ERROR
        _runtime().call("speech.speak", {"text": text, "flush": queueMode == TextToSpeech.QUEUE_FLUSH,
                                         "language": self._language, "rate": self._rate, "pitch": self._pitch})
        return TextToSpeech.SUCCESS

    def isSpeaking(self):
        if not self._usable():
            return False
        result = _runtime().call("speech.speaking", {})
        if type(result) is not bool:
            from ayu_bridge import ProtocolError
            raise ProtocolError("Host returned an invalid speaking state")
        return result

    def stop(self):
        if not self._usable():
            return TextToSpeech.ERROR
        _runtime().call("speech.stop", {})
        return TextToSpeech.SUCCESS

    def shutdown(self):
        if self._usable():
            _runtime().call("speech.stop", {})
        self._closed = True


CLASSES = _l.register({
    "android.speech.tts.TextToSpeech": TextToSpeech,
    "android.speech.tts.TextToSpeech$OnInitListener": OnInitListener,
})
