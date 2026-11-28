"""Account-scoped ``org.telegram.messenger.NotificationCenter`` served in Python.

The host adapts the global centre only. ``NotificationCenter.getInstance(account)`` returns a
per-account centre that delivers plugin posts to plugin observers, synchronously on the posting
thread like Android.

Only ids in ``_SERVED`` exist. On Android the app's screens observe ``dialogsNeedReload`` and
``updateInterfaces`` to re-read data that is already stored; the iOS views are reactive and show
stored data without being told, so a post of these ids has no app-side effect to reproduce and
the only observers left are plugin ones. An id whose observers expect events the app originates
(``didReceiveNewMessages``, ``fileLoaded``...) has no constant here and stays a preflight blocker.
"""
from __future__ import annotations

import threading

from . import returns
from . import java_lang as _l
from .java_lang import Object

_CENTER = "org.telegram.messenger.NotificationCenter"
_MAX_ACCOUNTS = 16
# Android numbers ids at class load, so plugins cannot rely on values; these only avoid the host's ids.
_SERVED = {"updateInterfaces": 2, "dialogsNeedReload": 3}
_IDS = frozenset(_SERVED.values())
_lock = threading.Lock()
_centers = {}


def _event(value):
    try:
        event = int(value)
    except (TypeError, ValueError):
        raise TypeError("NotificationCenter id must be an int") from None
    if event not in _IDS:
        raise _l.unsupported(f"NotificationCenter id {event} is not served for an account centre")
    return event


class AccountNotificationCenter(Object):
    def __init__(self, account):
        self._account = account
        self._observers = {}

    def addObserver(self, observer, id):
        event = _event(id)
        if not callable(getattr(observer, "didReceivedNotification", None)):
            raise TypeError("addObserver needs a NotificationCenterDelegate")
        with _lock:
            observers = self._observers.setdefault(event, [])
            if not any(item is observer for item in observers):
                observers.append(observer)

    def removeObserver(self, observer, id):
        event = _event(id)
        with _lock:
            self._observers[event] = [item for item in self._observers.get(event, ()) if item is not observer]

    def hasObservers(self, id):
        event = _event(id)
        with _lock:
            return bool(self._observers.get(event))

    def postNotificationName(self, id, *args):
        event = _event(id)
        with _lock:
            observers = list(self._observers.get(event, ()))
        for observer in observers:
            dispatch = getattr(observer, "_dispatch_notification", None) or observer.didReceivedNotification
            dispatch(event, self._account, list(args))


@returns(AccountNotificationCenter)
def _get_instance(*args):
    if len(args) != 1:
        raise TypeError("NotificationCenter.getInstance takes (account)")
    try:
        account = int(args[0])
    except (TypeError, ValueError):
        raise TypeError("NotificationCenter.getInstance account must be an int") from None
    if isinstance(args[0], bool) or not 0 <= account < _MAX_ACCOUNTS:
        raise _l.ArrayIndexOutOfBoundsException(f"account {account}")
    with _lock:
        center = _centers.get(account)
        if center is None:
            center = _centers[account] = AccountNotificationCenter(account)
        return center


HOST_MEMBERS = {_CENTER: {"getInstance": _get_instance, **_SERVED}}
# Not an Android name: the preflight needs a registered class to check the members of what ``getInstance`` returns.
CLASSES = {"com.ayugram.bridge.AccountNotificationCenter": AccountNotificationCenter}
_l.register(CLASSES)
