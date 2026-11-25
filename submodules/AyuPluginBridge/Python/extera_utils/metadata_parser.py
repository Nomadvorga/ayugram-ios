"""Read literal SDK metadata without executing or importing plugin code."""
import ast
import io
import os
import tokenize

MAX_SOURCE_BYTES = 4 * 1024 * 1024
MAX_STATEMENT_CHARS = 64 * 1024
ALLOWED_KEYS = {"__id__", "__name__", "__description__", "__author__", "__version__",
                "__icon__", "__min_version__", "__requirements__", "__app_version__",
                "__sdk_version__", "__category__"}


def _metadata_statements(source):
    lines = source.splitlines(keepends=True)
    indent, start, line_start = 0, None, True
    for token in tokenize.generate_tokens(io.StringIO(source).readline):
        if token.type == tokenize.INDENT:
            indent += 1
            continue
        if token.type == tokenize.DEDENT:
            indent -= 1
            continue
        if token.type in (tokenize.NEWLINE, tokenize.ENDMARKER):
            if start is not None:
                (start_row, start_col), (end_row, end_col) = start, token.end
                if end_row == start_row:
                    text = lines[start_row - 1][start_col:end_col]
                else:
                    text = lines[start_row - 1][start_col:] + "".join(lines[start_row:end_row - 1])
                    if end_row <= len(lines):
                        text += lines[end_row - 1][:end_col]
                if len(text) <= MAX_STATEMENT_CHARS:
                    yield text
                start = None
            line_start = True
            continue
        if token.type in (tokenize.NL, tokenize.COMMENT):
            continue
        if line_start and indent == 0 and token.type == tokenize.NAME and token.string in ALLOWED_KEYS:
            start = token.start
        line_start = False


def get_metadata(file_path):
    if os.path.getsize(file_path) > MAX_SOURCE_BYTES:
        raise ValueError("Metadata source exceeds the SDK source limit")
    with open(file_path, "rb") as stream:
        source = stream.read(MAX_SOURCE_BYTES + 1)
    if len(source) > MAX_SOURCE_BYTES:
        raise ValueError("Metadata source exceeds the SDK source limit")
    metadata = {}
    for statement in _metadata_statements(source.decode("utf-8")):
        try:
            tree = ast.parse(statement, filename=os.fspath(file_path))
        except (SyntaxError, ValueError, MemoryError, RecursionError):
            continue
        for node in tree.body:
            if not isinstance(node, ast.Assign):
                continue
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id in ALLOWED_KEYS:
                    if isinstance(node.value, ast.Constant):
                        metadata[target.id[2:-2]] = node.value.value
                    elif isinstance(node.value, ast.List):
                        metadata[target.id[2:-2]] = ",".join(str(item.value) for item in node.value.elts if isinstance(item, ast.Constant))
    if "min_version" in metadata:
        metadata.setdefault("app_version", ">=" + str(metadata.pop("min_version")))
    return metadata
