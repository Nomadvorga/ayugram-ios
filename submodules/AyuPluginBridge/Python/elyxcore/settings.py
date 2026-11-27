"""Settings of an Elyx plugin; always the calling plugin's own namespace."""
import plugin_settings


class SettingsController:
    def __init__(self, plugin_id):
        self.plugin_id = plugin_id

    def get_settings(self):
        return plugin_settings.get_all_settings(self.plugin_id)

    def get_setting(self, key, default=None):
        return plugin_settings.get_setting(self.plugin_id, key, default)

    def get(self, key, default=None):
        return self.get_setting(key, default)

    def set_setting(self, key, value, reload_settings=False):
        plugin_settings.set_setting(self.plugin_id, key, value, reload_settings=bool(reload_settings))

    def set(self, key, value, reload_settings=False):
        self.set_setting(key, value, reload_settings)

    def __getitem__(self, item):
        return self.get_setting(item)

    def __setitem__(self, key, value):
        self.set_setting(key, value)

    def clear_settings(self):
        plugin_settings.clear_settings(self.plugin_id)

    def __call__(self, key, default=None):
        return self.get_setting(key, default)
