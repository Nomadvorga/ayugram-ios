"""Python-local ``com.exteragram.messenger.plugins`` classes.

``PluginsConstants`` mirrors the Android constants. ``PluginsController`` reads the installed
plugin list and asks the host to reload or open a plugin's settings; managing other plugins
(enabling, deleting, installing, engines) is the host manager's job and is not exposed.
"""
from __future__ import annotations

from . import telegram_messenger as messenger
from . import telegram_tl as tl

PACKAGE = "com.exteragram.messenger.plugins."
_unsupported = tl._unsupported
_Java = messenger._Java
MAX_PLUGINS = 1024


def _runtime():
    from ayu_bridge import runtime
    return runtime


def _protocol(message):
    from ayu_bridge import ProtocolError
    return ProtocolError(message)


class PluginsConstants:
    PYTHON = "python"
    SEND_MESSAGE_HOOK = "send_message_hook"
    STRATEGY, PARAMS, UPDATE, UPDATES, REQUEST, RESPONSE, ERROR = (
        "strategy", "params", "update", "updates", "request", "response", "error")
    PLUGINS, PLUGINS_EXT, PLUGINS_SDK = "plugins", ".plugin", "plugins-sdk"
    CREATE_SETTINGS = "create_settings"
    APP_START, APP_STOP, APP_PAUSE, APP_RESUME = "app_start", "app_stop", "app_pause", "app_resume"
    ON_APP_EVENT, ON_PLUGIN_LOAD, ON_PLUGIN_UNLOAD = "on_app_event", "on_plugin_load", "on_plugin_unload"

    class Settings:
        TYPE, KEY, TEXT, SUBTEXT, ICON, ACCENT, RED = "type", "key", "text", "subtext", "icon", "accent", "red"
        ON_CLICK, DEFAULT, ITEMS, HINT, MULTILINE = "on_click", "default", "items", "hint", "multiline"
        MAX_LENGTH, MASK, ON_CHANGE = "max_length", "mask", "on_change"
        TYPE_SWITCH, TYPE_INPUT, TYPE_SELECTOR, TYPE_HEADER = "switch", "input", "selector", "header"
        TYPE_DIVIDER, TYPE_TEXT, TYPE_EDIT_TEXT, TYPE_CUSTOM = "divider", "text", "edit_text", "custom"
        VIEW, ITEM, FACTORY, FACTORY_ARGS = "view", "item", "factory", "factory_args"
        CREATE_SUB_FRAGMENT, ON_LONG_CLICK, LINK_ALIAS = "create_sub_fragment", "on_long_click", "link_alias"

    class Strategy:
        MODIFY, CANCEL, DEFAULT, MODIFY_FINAL = "MODIFY", "CANCEL", "DEFAULT", "MODIFY_FINAL"

    class Xposed:
        REPLACE_HOOKED_METHOD = "replace_hooked_method"
        BEFORE_HOOKED_METHOD = "before_hooked_method"
        AFTER_HOOKED_METHOD = "after_hooked_method"
        HOOK_FILTERS = "__hook_filters__"

    class DevServer:
        MODULE, CLASS, START_SERVER, STOP_SERVER = "dev_server", "DevServer", "start_server", "stop_server"

    class MenuItemTypes:
        MESSAGE_CONTEXT_MENU, DRAWER_MENU, MAIN_MENU = "message_context_menu", "drawer_menu", "main_menu"
        CHAT_ACTION_MENU, PROFILE_ACTION_MENU = "chat_action_menu", "profile_action_menu"

    class MenuItemProperties:
        MENU_TYPE, ITEM_ID, TEXT, SUBTEXT, ICON = "menu_type", "item_id", "text", "subtext", "icon"
        ON_CLICK, ON_LONG_CLICK, CONDITION, PRIORITY = "on_click", "on_long_click", "condition", "priority"

    class HookFilterTypes:
        RESULT_IS_NULL, RESULT_IS_TRUE, RESULT_IS_FALSE = "result_is_null", "result_is_true", "result_is_false"
        RESULT_NOT_NULL, RESULT_IS_INSTANCE_OF = "result_not_null", "result_is_instance_of"
        RESULT_EQUAL, RESULT_NOT_EQUAL = "result_equal", "result_not_equal"
        ARGUMENT_IS_NULL, ARGUMENT_IS_TRUE, ARGUMENT_IS_FALSE = "argument_is_null", "argument_is_true", "argument_is_false"
        ARGUMENT_NOT_NULL, ARGUMENT_IS_INSTANCE_OF = "argument_not_null", "argument_is_instance_of"
        ARGUMENT_EQUAL, ARGUMENT_NOT_EQUAL, CONDITION, OR = "argument_equal", "argument_not_equal", "condition", "or"


class Plugin(_Java):
    """``Plugin``: a read-only record of an installed plugin, as the host lists it."""
    _FIELDS = ("id", "name", "version", "description", "author", "icon", "enabled", "error")

    def __init__(self, id, name):
        if not isinstance(id, str) or not isinstance(name, str):
            raise TypeError("Plugin(id, name)")
        self.__dict__["_record"] = {"id": id, "name": name, "version": "1.0", "description": None, "author": None,
                                    "icon": None, "enabled": False, "error": False}

    @staticmethod
    def _ayu_from_wire(record):
        if (not isinstance(record, dict) or not set(record) <= set(Plugin._FIELDS)
                or not isinstance(record.get("id"), str) or not isinstance(record.get("name"), str)
                or type(record.get("enabled")) is not bool):
            raise _protocol("Host returned an invalid plugin record")
        plugin = Plugin(record["id"], record["name"])
        plugin._record.update(record)
        return plugin

    def getId(self):
        return self._record["id"]

    def getName(self):
        return self._record["name"]

    def getVersion(self):
        return self._record["version"]

    def getDescription(self):
        return self._record["description"]

    def getAuthor(self):
        return self._record["author"]

    def getIcon(self):
        return self._record["icon"]

    def hasError(self):
        return bool(self._record["error"])

    def isEnabled(self):
        return not self.hasError() and self._record["enabled"]

    def getEngine(self):
        return PluginsConstants.PYTHON


class PluginsController(_Java):
    """``PluginsController``: the installed plugins and the settings screen of a plugin."""
    __ayu_requires__ = ("plugins.list", "plugins.settings")

    @staticmethod
    def getInstance():
        return PluginsController()

    @staticmethod
    def isPluginEngineAvailable():
        return True

    @staticmethod
    def isPluginEngineSupported():
        return True

    def isInitialized(self):
        # The caller is a plugin the engine has loaded.
        return True

    @staticmethod
    def runOnPluginsQueue(runnable):
        """Post a ``Runnable`` (or a callable) to the plugins queue."""
        import client_utils
        run = getattr(runnable, "run", None)
        client_utils.run_on_queue(run if callable(run) else runnable, client_utils.PLUGINS_QUEUE)

    @property
    def plugins(self):
        """A snapshot ``HashMap`` of plugin id to ``Plugin``; changing it does not manage plugins."""
        records = _runtime().call("plugins.list", {})
        if not isinstance(records, list) or len(records) > MAX_PLUGINS:
            raise _protocol("Host returned an invalid plugin list")
        from . import java_util
        result = java_util.HashMap()
        for record in records:
            plugin = Plugin._ayu_from_wire(record)
            result[plugin.getId()] = plugin
        return result

    def getPlugins(self):
        return self.plugins

    @property
    def pluginsDir(self):
        """The directory plugin files have on Android: ``plugins`` below ``ApplicationLoader.getFilesDirFixed()``."""
        import file_utils
        return messenger.File(file_utils.get_plugins_dir())

    @staticmethod
    def _id(value):
        value = value.getId() if isinstance(value, Plugin) else value
        if not isinstance(value, str) or not value:
            raise TypeError("A plugin id is required")
        return value

    def isPluginActive(self, plugin):
        found = self.plugins.get(self._id(plugin))
        return found is not None and found.isEnabled()

    def loadPluginSettings(self, pluginId=None):
        """Rebuild the settings rows of the calling plugin; the host refuses another plugin's id."""
        scope = _runtime().require()
        _runtime().call("plugins.settings", {"action": "reload",
                                             "plugin_id": scope.plugin_id if pluginId is None else self._id(pluginId)})

    @staticmethod
    def openPluginSettings(plugin, fragment=None):
        """``openPluginSettings(id | Plugin[, fragment | linkAlias])``; static on Android, so the class can call it."""
        arguments = {"action": "open", "plugin_id": PluginsController._id(plugin)}
        if isinstance(fragment, str):
            arguments["link_alias"] = fragment
        _runtime().call("plugins.settings", arguments)


class PluginSettingsActivity(_Java):
    """``PluginSettingsActivity(plugin[, targetSettingName])``: a settings screen to hand to ``presentFragment``."""
    __ayu_requires__ = ("plugins.list", "plugins.settings")

    def __init__(self, plugin, *rest):
        if not isinstance(plugin, Plugin):
            raise TypeError("PluginSettingsActivity needs a Plugin")
        if len(rest) > 1 or (rest and rest[0] is not None and not isinstance(rest[0], str)):
            raise _unsupported("PluginSettingsActivity sub-pages are not implemented")
        self.__dict__["_plugin"], self.__dict__["_target"] = plugin, rest[0] if rest else None

    def _ayu_present(self, account):
        PluginsController.openPluginSettings(self._plugin, self._target)


CLASSES = {
    PACKAGE + "PluginsConstants": PluginsConstants,
    PACKAGE + "Plugin": Plugin,
    PACKAGE + "PluginsController": PluginsController,
    PACKAGE + "ui.PluginSettingsActivity": PluginSettingsActivity,
}
CLASSES.update({PACKAGE + "PluginsConstants$" + name: value for name, value in vars(PluginsConstants).items()
                if isinstance(value, type)})
messenger._l.register(CLASSES)
