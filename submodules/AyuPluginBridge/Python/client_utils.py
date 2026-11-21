"""Higher-level client calls; each helper requires an explicit host adapter."""
from ayu_bridge import runtime

STAGE_QUEUE = "stageQueue"
GLOBAL_QUEUE = "globalQueue"
CACHE_CLEAR_QUEUE = "cacheClearQueue"
SEARCH_QUEUE = "searchQueue"
PHONE_BOOK_QUEUE = "phoneBookQueue"
THEME_QUEUE = "themeQueue"
EXTERNAL_NETWORK_QUEUE = "externalNetworkQueue"
PLUGINS_QUEUE = "pluginsQueue"


def run_on_queue(function, queue=PLUGINS_QUEUE, delay=0):
    return runtime.schedule(function, queue=queue, delay=delay)


def run_on_ui_thread(function, delay=0):
    # Python callbacks still execute on the host's serial Python queue; native UI
    # operations produced by them are asynchronously marshalled to main.
    return runtime.schedule(function, queue="main", delay=delay)


def _call(name, *args, **kwargs):
    return runtime.call("client.call", {"name": name, "args": list(args), "kwargs": kwargs})


def get_last_fragment():
    return _call("get_last_fragment")


def get_selected_account():
    return _call("get_selected_account")


def get_messages_controller(account=None):
    return _call("get_messages_controller", account=account)


def get_user_config(account=None):
    return _call("get_user_config", account=account)


def get_connections_manager(account=None):
    return _call("get_connections_manager", account=account)


def get_send_messages_helper(account=None):
    return _call("get_send_messages_helper", account=account)


def get_media_data_controller(account=None):
    return _call("get_media_data_controller", account=account)


def get_notification_center(account=None):
    return _call("get_notification_center", account=account)


def get_account_instance(account=None):
    return _call("get_account_instance", account=account)


def send_message(*args, **kwargs):
    return _call("send_message", *args, **kwargs)


def edit_message(*args, **kwargs):
    return _call("edit_message", *args, **kwargs)


def send_request(request, fn=None, account=None):
    return _call("send_request", request, fn, account=account)


class AccountClient:
    def __init__(self, account=None):
        self._scope = runtime.require()
        self.account = account

    def _call(self, name, *args, **kwargs):
        runtime.require(self._scope)
        kwargs.setdefault("account", self.account)
        return _call(name, *args, **kwargs)

    def send_message(self, *args, **kwargs):
        return self._call("send_message", *args, **kwargs)

    def edit_message(self, *args, **kwargs):
        return self._call("edit_message", *args, **kwargs)

    def send_request(self, request, fn=None):
        return self._call("send_request", request, fn)

    def get_messages_controller(self):
        return self._call("get_messages_controller")

    def get_user_config(self):
        return self._call("get_user_config")

    def get_connections_manager(self):
        return self._call("get_connections_manager")

    def get_send_messages_helper(self):
        return self._call("get_send_messages_helper")

    def get_media_data_controller(self):
        return self._call("get_media_data_controller")

    def get_notification_center(self):
        return self._call("get_notification_center")

    def get_account_instance(self):
        return self._call("get_account_instance")
