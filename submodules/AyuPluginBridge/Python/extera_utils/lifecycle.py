"""Lifecycle decorators for extera-style plugins (no-op markers on iOS)."""
from extera_utils import lifecycle

on_plugin_load = lifecycle.on_plugin_load
on_plugin_unload = lifecycle.on_plugin_unload
