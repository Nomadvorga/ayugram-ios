"""Asset files of an Elyx plugin.

Content accessors are plain file reads. The drawable and image-location
converters compose the host's Android graphics classes and raise
``UNSUPPORTED_API`` while the host does not declare them.
"""
from __future__ import annotations

import json
import os
import string
from pathlib import Path
from zipfile import ZipFile, ZipInfo

import _ayu_yaml
from ayu_bridge import runtime

MAX_DATA_BYTES = 1_048_576
_NAME_CHARACTERS = frozenset(string.ascii_letters + string.digits)


def load_data_file(path, plzip=None):
    """Parse a ``.json``/``.yaml``/``.yml`` file given as bytes, a path, or an archive member."""
    if isinstance(path, bytes):
        content, suffix = path.decode(), ""
    elif isinstance(path, Path):
        if path.stat().st_size > MAX_DATA_BYTES:
            raise ValueError("Data file exceeds its size limit")
        content, suffix = path.read_text(encoding="utf-8"), path.suffix[1:]
    else:
        if not isinstance(plzip, ZipFile):
            raise TypeError("An archive member needs its archive")
        name = path.filename if isinstance(path, ZipInfo) else path
        if plzip.getinfo(name).file_size > MAX_DATA_BYTES:
            raise ValueError("Data file exceeds its size limit")
        content, suffix = plzip.read(name).decode(), name.split("/")[-1].split(".")[-1]
    if suffix == "json":
        return json.loads(content)
    if suffix in ("yaml", "yml"):
        return _ayu_yaml.safe_load(content)
    return {}


def normalize_name(name):
    return "".join(char if char in _NAME_CHARACTERS else "_" for char in name)


class AssetNotFoundException(Exception):
    def __init__(self, name, dir_path=None):
        super().__init__(f"Asset \"{name}\" not found in directory {dir_path}")


class AssetsDirNotFoundException(Exception):
    def __init__(self, dir_path=None):
        super().__init__(f"Directory {dir_path} does not exist")


def _file_path(value):
    """A ``java.io.File`` argument as its absolute path."""
    return str(value.getAbsolutePath()) if hasattr(value, "getAbsolutePath") else value


class Asset:
    def __init__(self, dir_path, filename, name):
        if not dir_path or not filename or not name:
            raise ValueError("dir_path, filename and name must be provided")
        dir_path = _file_path(dir_path)
        self.dir_path = dir_path if isinstance(dir_path, Path) else Path(dir_path)
        self.name = normalize_name(name)
        self.filename = filename
        self.ext = filename.split(".")[-1]
        if not self.dir_path.is_dir():
            raise ValueError(f"Path {dir_path} is not a directory")
        if not self.path.exists():
            raise AssetNotFoundException(name, str(dir_path))

    @classmethod
    def from_path(cls, path):
        path = _file_path(path)
        if isinstance(path, str):
            path = Path(path)
        if not path.is_file():
            raise IsADirectoryError(f"Path {path} is not a file")
        return cls(path.parent, path.name, path.name.split(".")[0])

    @classmethod
    def temp_asset_from_url(cls, url, filename):
        import requests
        from file_utils import get_cache_dir
        if os.path.basename(filename) != filename or filename in ("", ".", ".."):
            raise ValueError("Asset file name must be a plain file name")
        directory = Path(get_cache_dir(), "elyx_assets")
        directory.mkdir(parents=True, exist_ok=True)
        response = requests.get(url)
        with open(directory / filename, "wb") as stream:
            stream.write(response.content)
        return cls(directory, filename, "_".join(filename.split(".")[:-1]))

    @property
    def path_str(self):
        return str(self.path)

    @property
    def path(self):
        return self.dir_path.joinpath(self.filename)

    @property
    def java_file(self):
        return runtime.jclass("java.io.File")(self.path_str)

    def _context(self):
        from client_utils import get_last_fragment
        return get_last_fragment().getContext()

    def to_image_location(self):
        return runtime.jclass("org.telegram.messenger.ImageLocation").getForPath(self.path_str)

    def to_drawable(self):
        return runtime.jclass("android.graphics.drawable.Drawable").createFromPath(self.path_str)

    def to_bitmap_drawable(self, width=32, height=32):
        bitmap = runtime.jclass("android.graphics.Bitmap").createScaledBitmap(
            self.to_drawable().mutate().getBitmap(), width, height, True)
        return runtime.jclass("android.graphics.drawable.BitmapDrawable")(self._context().getResources(), bitmap)

    def to_lottie_drawable(self, width=32, height=32):
        utilities = runtime.jclass("org.telegram.messenger.AndroidUtilities")
        return runtime.jclass("org.telegram.ui.Components.RLottieDrawable")(
            self.java_file, utilities.dp(width), utilities.dp(height), None, False, None, 0)

    def to_svg_drawable(self, width=None, height=None, *args):
        if width and height:
            return runtime.jclass("android.graphics.drawable.BitmapDrawable")(
                self._context().getResources(), self.to_svg_bitmap(width, height, *args))
        return runtime.jclass("org.telegram.messenger.SvgHelper").getDrawable(self.content_string())

    def to_svg_thumb(self, color_key, alpha):
        thumb = self.to_svg_drawable()
        if thumb is not None:
            thumb.setupGradient(color_key, alpha, False)
        return thumb

    def to_svg_bitmap(self, width=32, height=32, white=False):
        return runtime.jclass("org.telegram.messenger.SvgHelper").getBitmap(self.content_string(), width, height, white)

    def content_bytes(self):
        return self.path.read_bytes()

    def content_string(self):
        return self.path.read_text(encoding="utf-8")

    def content_json(self):
        return load_data_file(self.path)

    def content_yaml(self):
        return load_data_file(self.path)

    def content(self):
        if self.ext in ("json", "yaml", "yml"):
            return load_data_file(self.path)
        try:
            return self.content_string()
        except (OSError, UnicodeError):
            return self.content_bytes()

    def __str__(self):
        return self.__repr__()

    def __repr__(self):
        return f"<Elyx.Asset name={self.name} path={self.path_str} ext={self.ext}>"


class Assets:
    def __init__(self, dir_path):
        if isinstance(dir_path, str):
            dir_path = Path(dir_path)
        if not dir_path.is_dir():
            raise ValueError(f"Path {dir_path} is not a directory")
        if dir_path.parent.name == "ElyxPlugins" or dir_path.name in ("plugins", "ElyxPlugins") \
                or dir_path.parent.name == "plugins":
            raise ValueError(f"Path {dir_path} is a plugin directory")
        self.dir_path = dir_path
        self.files = {item.name: item for item in dir_path.iterdir()}
        self.names = {normalize_name(item.name.split(".")[0]): item.name for item in self.files.values()}

    @property
    def parent(self):
        return Assets(self.dir_path.parent)

    def get(self, name):
        if "/" in name:
            first, rest = name.split("/", 1)
            return self.get(first).get(rest)
        if name not in self.names and name not in self.files:
            raise AssetNotFoundException(name, str(self.dir_path))
        path = self.dir_path.joinpath(self.names[name] if name in self.names else name)
        if path.is_dir():
            return Assets(path)
        return Asset(self.dir_path, self.names[name] if name in self.names else name,
                     name if name in self.names else name.split(".")[0])

    def __getitem__(self, item):
        return self.get(item)

    def __getattr__(self, item):
        if item.startswith("__"):
            raise AttributeError(item)
        return self.get(item)

    def __contains__(self, item):
        return item in self.names or item in self.files

    def __iter__(self):
        return iter(self.files)

    def __len__(self):
        return len(self.files)

    def __repr__(self):
        return f"<Elyx.Assets dir_path={self.dir_path}>"

    def __str__(self):
        return self.__repr__()
