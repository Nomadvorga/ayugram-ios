"""TL access resolves only explicitly registered, host-owned native classes.

No fabricated Python TL objects or unimplemented request callbacks are accepted.
The iOS application must supply each constructor and the actual request service.
"""
from ayu_bridge import runtime
from client_utils import get_connections_manager, send_request


class _TLNamespace:
    def __getattr__(self, name):
        if name.startswith("_"):
            raise AttributeError(name)
        return runtime.jclass("org.telegram.tgnet.TLRPC$" + name)

    def __getitem__(self, name):
        if not isinstance(name, str) or not name.startswith("TL_"):
            raise KeyError(name)
        return self.__getattr__(name)


class _TLRoot(_TLNamespace):
    @property
    def TL(self):
        runtime.require()
        return self


TLRPC = _TLRoot()
tlrpc = TLRPC
tlrpc_module = TLRPC


class ConnectionsManager:
    @staticmethod
    def getInstance(account=None):
        return get_connections_manager(account)

    @staticmethod
    def sendRequest(request, on_result=None, on_error=None, **kwargs):
        from ayu_bridge import UnsupportedAPI
        runtime.require()
        if on_error is not None or kwargs:
            raise UnsupportedAPI("Separate TL error callbacks and request flags require a native adapter")
        return send_request(request, on_result)
