"""Real Python file helpers; application storage and file UI need native adapters.

Python plugins are trusted application code. Paths are ordinary Python paths,
not a sandbox or a fabricated Android application directory.
"""
import os
from dataclasses import dataclass, field
from enum import Enum
from typing import Callable

from ayu_bridge import UnsupportedAPI
from android_utils import log


def _unsupported(*args, **kwargs):
    raise UnsupportedAPI("Application storage locations and file handlers need an unavailable native adapter")


get_plugins_dir = get_cache_dir = get_files_dir = get_images_dir = _unsupported
get_videos_dir = get_audios_dir = get_documents_dir = _unsupported


def _read(file_path, mode):
    try:
        with open(file_path, mode, **({"encoding": "utf-8"} if mode == "r" else {})) as file:
            return file.read()
    except (OSError, UnicodeError) as error:
        log(f"Error reading file ({type(error).__name__})")
        return None


def read_file(file_path):
    return _read(file_path, "r")


def read_file_bytes(file_path):
    return _read(file_path, "rb")


def _write(file_path, content, mode):
    try:
        with open(file_path, mode, **({"encoding": "utf-8"} if mode == "w" else {})) as file:
            file.write(content)
    except (OSError, UnicodeError) as error:
        log(f"Error writing file ({type(error).__name__})")


def write_file(file_path, content):
    return _write(file_path, content, "w")


def write_file_bytes(file_path, content):
    return _write(file_path, content, "wb")


def delete_file(file_path):
    if not os.path.exists(file_path):
        return False
    try:
        os.remove(file_path)
        return True
    except OSError as error:
        log(f"Error deleting file ({type(error).__name__})")
        return False


def ensure_dir_exists(dir_path):
    try:
        os.makedirs(dir_path, exist_ok=True)
    except OSError as error:
        log(f"Error creating directory ({type(error).__name__})")


def list_dir(path, recursive=False, include_files=True, include_dirs=False, extensions=None):
    if not os.path.isdir(path):
        log("Path is not a directory or does not exist")
        return []
    results = []
    if recursive:
        for root, dirs, files in os.walk(path):
            if include_dirs:
                results.extend(os.path.join(root, name) for name in dirs)
            if include_files:
                results.extend(os.path.join(root, name) for name in files
                               if not extensions or any(name.endswith(ext) for ext in extensions))
    else:
        for name in os.listdir(path):
            full_path = os.path.join(path, name)
            if os.path.isdir(full_path):
                if include_dirs:
                    results.append(full_path)
            elif include_files and (not extensions or any(name.endswith(ext) for ext in extensions)):
                results.append(full_path)
    return results


class FilesController:
    """Android file-handler descriptors; registration requires native support."""
    DIRECT_FILE_ICONS = False
    SUPPORT_ICONS = False

    class Place(Enum):
        UNKNOWN = 1
        ChatActivity = 2
        FilteredSearchView = 3
        SharedMediaLayout = 4
        SearchDownloadsContainer = 5
        ChannelAdminLogActivity = 6

    @dataclass
    class FileInfo:
        ext: str
        on_click: Callable = field(compare=False, repr=False)
        whitelist_places: list = field(default_factory=list, kw_only=True)
        blacklist_places: list = field(default_factory=list, kw_only=True)
        get_icon: Callable | None = field(default=None, compare=False, repr=False, kw_only=True)
        _icid: int = field(default=-1, init=False, repr=False, compare=False)

        def __post_init__(self):
            if self.whitelist_places and self.blacklist_places:
                raise ValueError("Cannot use whitelist_places with blacklist_places together")
            if self.get_icon:
                raise UnsupportedAPI("Custom file icons need an unavailable native adapter")

    @dataclass
    class OnClickArgs:
        place: "FilesController.Place"
        file: object = field(compare=False, repr=False)
        file_name: str
        message: object = field(compare=False, repr=False)
        activity: object = field(compare=False, repr=False)
        parent_fragment: object = field(default=None, compare=False, repr=False)

    class ExtensionAlreadyRegistered(Exception):
        def __init__(self, ext):
            super().__init__(f"The file extension '{ext}' is already in use.")

    class ExtensionNotRegistered(Exception):
        def __init__(self, ext):
            super().__init__(f"The file extension '{ext}' is not registered.")

    class SecretInvalid(Exception):
        def __init__(self, ext, secret):
            super().__init__(f"Provided secret for extension '{ext}' is invalid.")

    @staticmethod
    def register(file_info):
        raise UnsupportedAPI("Application file-handler registration is unavailable on iOS")

    @staticmethod
    def unregister(ext, secret):
        raise UnsupportedAPI("Application file-handler registration is unavailable on iOS")
