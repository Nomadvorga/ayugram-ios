"""Portable SDK utilities and explicit native compatibility boundaries."""
from base_plugin import BasePlugin, MethodHook

from .classes import (Base, java_subclass, joverride, joverload, jconstructor,
                      jfield, jgetmethod, jsetmethod, jmethod, jclassbuilder)
from . import lifecycle, text_formatting
from .lifecycle import capture_scope, bind_task
