"""String tables of an Elyx plugin, selected by the device language."""
from __future__ import annotations

from ayu_bridge import runtime
from elyxcore.utils import LazyDict


class Strings(LazyDict):
    def __init__(self, all_strings):
        super().__init__()
        self.all_strings = all_strings

    @staticmethod
    def get_current_language():
        """Android also honours ElyxCore's own ``language`` override; that setting lives outside a plugin here."""
        return runtime.jclass("java.util.Locale").getDefault().getLanguage()

    def _table(self, locale=None):
        return self.all_strings.get(locale or self.get_current_language(),
                                    self.all_strings.get("en", self.all_strings))

    def __getitem__(self, key):
        if key == "all_strings":
            return super().__getitem__(key)
        res = self._table().get(key, None)
        if res is None:
            res = self.all_strings.get("en", self.all_strings).get(key, None)
        return key if res is None else res

    def __setitem__(self, key, value):
        if key != "all_strings":
            raise RuntimeError("Strings are read-only")
        super().__setitem__(key, value)

    def get(self, key, default=None):
        return self.get_with_locale(key, default)

    def get_with_locale(self, key, default=None, locale=None):
        res = self._table(locale).get(key, default)
        if res is None:
            if default is not None:
                return default
            res = self.all_strings.get("en", self.all_strings).get(key, default)
        return key if res is None else res

    def __call__(self, key, *args, default=None, locale=None, **kwargs):
        result = self.get_with_locale(key, default, locale)
        if isinstance(result, str) and (args or kwargs):
            result = result.format(*args, **kwargs)
        return result

    @staticmethod
    def pluralization_string(number, words):
        if number % 10 == 1 and number % 100 != 11:
            return f"{number} {words[0]}"
        if 2 <= number % 10 <= 4 and (number % 100 < 10 or number % 100 >= 20):
            return f"{number} {words[1]}"
        return f"{number} {words[2]}"

    def pluralize(self, number, key):
        return self.pluralization_string(number, self(key))
