"""Static Android-to-iOS plugin compatibility inspection, using only stdlib."""
from .inspector import (
    ManifestError,
    inspect_file,
    inspect_source,
    load_manifest,
    render_markdown,
    validate_manifest,
)

__all__ = [
    "ManifestError", "inspect_file", "inspect_source", "load_manifest",
    "render_markdown", "validate_manifest",
]
