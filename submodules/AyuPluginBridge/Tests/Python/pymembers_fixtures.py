"""A scripted host for the SDK-served members of host classes: classes, members and a member table."""
from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from unittest.mock import patch

import test_bridge as fixtures
import _ayu_javalib as javalib
import ayu_bridge as bridge

CONTEXT = "android.content.Context"
LOADER = "org.telegram.messenger.ApplicationLoader"
UTILITIES = "org.telegram.messenger.AndroidUtilities"
RESOURCES = "android.content.res.Resources"
METRICS = "android.util.DisplayMetrics"


def entry(constructor=False, methods=(), fields=(), static_methods=(), static_fields=(), results=None):
    return {"constructor": constructor, "methods": list(methods), "fields": list(fields), "writable_fields": [],
            "static_methods": list(static_methods), "static_fields": list(static_fields), "results": dict(results or {})}


class HostCase(unittest.TestCase):
    """The fake host of ``test_bridge`` plus scripted classes.

    ``script[class][member]`` is a field value, or a function ``(target, args)`` for a method; the
    target is the wire target (``class_name`` for the class, ``$handle`` for an object).
    """
    load = fixtures.BridgeTests.load

    def setUp(self):
        fixtures.BridgeTests.setUp(self)
        javalib.reset()
        self.addCleanup(fixtures.BridgeTests.tearDown, self)
        self.addCleanup(self.forget_native_modules)
        home = tempfile.TemporaryDirectory()
        self.addCleanup(home.cleanup)
        self.home = os.path.realpath(home.name)
        environment = patch.dict(os.environ, {"HOME": self.home})
        environment.start()
        self.addCleanup(environment.stop)
        self.script = {}
        perform = self.host.perform

        def scripted(request):
            operation, arguments = request["operation"], request["arguments"]
            if operation in ("java.member", "java.invoke") and request["plugin_id"] in self.host.active:
                target = arguments["target"]
                members = self.script.get(target.get("class_name") or target.get("$class"), {})
                if arguments["name"] in members:
                    value = members[arguments["name"]]
                    if operation == "java.member":
                        return {"kind": "method"} if callable(value) else {"kind": "field", "value": value}
                    return value(target, arguments["args"])
            return perform(request)

        self.host.perform = scripted

    @staticmethod
    def forget_native_modules():
        for name in [name for name in sys.modules if name.split(".")[0] in ("android", "org", "com")
                     or name.startswith(("java.lang", "java.util", "java.io", "java.nio"))]:
            del sys.modules[name]

    def declare(self, name, members=None, table=None):
        """Declare a host class, optionally scripting its members and publishing its member table."""
        if name not in self.host.capabilities["classes"]:
            self.host.capabilities["classes"].append(name)
        self.script.setdefault(name, {}).update(members or {})
        if table is not None:
            self.host.capabilities.setdefault("members", {"version": 1, "classes": {}})["classes"][name] = table

    def operations(self, *names, remove=()):
        for name in names:
            if name not in self.host.capabilities["operations"]:
                self.host.capabilities["operations"].append(name)
        for name in remove:
            self.host.capabilities["operations"].remove(name)

    def reference(self, class_name, handle="object"):
        return bridge.runtime.decode({"$handle": handle, "$class": class_name})

    def host_requests(self, operation="java.member"):
        return [(item["arguments"]["target"].get("class_name") or item["arguments"]["target"].get("$class"),
                 item["arguments"]["name"]) for item in self.host.requests if item["operation"] == operation]

    def preflight(self, imports="", body="    pass\n", plugin_id="members"):
        return json.loads(bridge.preflight_plugin_json(fixtures.source(plugin_id, body, imports)))

    def blockers(self, imports="", body="    pass\n", code=None):
        found = [(item["code"], item["detail"]) for item in self.preflight(imports, body)["blockers"]]
        return [detail for kind, detail in found if kind == code] if code else found

    def declare_application(self, scale=3.0, pixels=(1206, 2622), density=1.0):
        """The application adapters of today's host that the composed members read, with their tables."""
        context = {"$handle": "context", "$class": CONTEXT}
        self.declare(LOADER, {"applicationContext": context},
                     entry(static_fields=["applicationContext"], results={"applicationContext": CONTEXT}))
        self.declare(CONTEXT, {"getResources": lambda target, args: {"$handle": "resources", "$class": RESOURCES}},
                     entry(methods=["getClass", "getResources"], results={"getResources": RESOURCES}))
        self.declare(RESOURCES, {"getDisplayMetrics": lambda target, args: {"$handle": "metrics", "$class": METRICS}},
                     entry(methods=["getDisplayMetrics"], results={"getDisplayMetrics": METRICS}))
        self.declare(METRICS, {"density": scale, "widthPixels": pixels[0], "heightPixels": pixels[1]},
                     entry(fields=["density", "densityDpi", "widthPixels", "heightPixels"]))
        self.declare(UTILITIES, {"dpf2": lambda target, args: args[0] * density},
                     entry(static_methods=["dp", "dpf2"]))
