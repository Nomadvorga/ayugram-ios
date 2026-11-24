"""Small, synchronous requests-compatible HTTPS subset using only stdlib.

This module is opt-in through host capabilities.modules. It is not the upstream
requests package, an asynchronous transport, or a network sandbox. No global
session/cookies are shared between plugins. Native main must never wait for it.
"""
from __future__ import annotations

import gzip
import io
import json as _json
import math
import re
import socket
import ssl
import sys
import time
import types
from collections.abc import Mapping, MutableMapping
from email.message import Message
from http.cookiejar import CookieJar
from urllib import error as _error
from urllib import parse as _parse
from urllib import request as _urlrequest

__version__ = "0.1.0-ayu-subset"
__path__ = []
MAX_RESPONSE_BYTES = 16 * 1024 * 1024
MAX_REQUEST_BYTES = 8 * 1024 * 1024
DEFAULT_TIMEOUT = 15.0
MAX_TIMEOUT = 60.0
_HEADER_NAME = re.compile(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$")


class RequestException(Exception):
    def __init__(self, message="HTTPS request failed", *, response=None):
        super().__init__(message)
        self.response = response


class ConnectionError(RequestException):
    pass


class Timeout(RequestException):
    pass


class SSLError(ConnectionError):
    pass


class HTTPError(RequestException):
    pass


class InvalidURL(RequestException, ValueError):
    pass


class TooManyRedirects(RequestException):
    pass


class ContentTooLarge(RequestException):
    pass


class ContentDecodingError(RequestException):
    pass


class UnsupportedOption(RequestException, ValueError):
    pass


class JSONDecodeError(_json.JSONDecodeError, RequestException):
    pass


exceptions = types.ModuleType(__name__ + ".exceptions")
for _type in (RequestException, ConnectionError, Timeout, SSLError, HTTPError,
              InvalidURL, TooManyRedirects, ContentTooLarge, ContentDecodingError,
              UnsupportedOption, JSONDecodeError):
    setattr(exceptions, _type.__name__, _type)
sys.modules[exceptions.__name__] = exceptions


class CaseInsensitiveDict(MutableMapping):
    def __init__(self, values=None):
        self._values = {}
        if values is not None:
            self.update(values)

    def __getitem__(self, key):
        return self._values[key.lower()][1]

    def __setitem__(self, key, value):
        if not isinstance(key, str):
            raise TypeError("Header names must be strings")
        self._values[key.lower()] = (key, value)

    def __delitem__(self, key):
        del self._values[key.lower()]

    def __iter__(self):
        return (item[0] for item in self._values.values())

    def __len__(self):
        return len(self._values)

    def copy(self):
        return CaseInsensitiveDict(self.items())


class Response:
    def __init__(self, status_code, content, headers, url):
        self.status_code = int(status_code)
        self.content = bytes(content)
        self.headers = CaseInsensitiveDict(headers)
        self.url = url
        message = Message()
        message["Content-Type"] = self.headers.get("Content-Type", "")
        self.encoding = message.get_content_charset() or "utf-8"

    @property
    def text(self):
        try:
            return self.content.decode(self.encoding or "utf-8", errors="replace")
        except LookupError:
            return self.content.decode("utf-8", errors="replace")

    @property
    def ok(self):
        return self.status_code < 400

    def __bool__(self):
        return self.ok

    def json(self, **kwargs):
        try:
            return _json.loads(self.content, **kwargs)
        except (ValueError, UnicodeError) as error:
            # Do not copy response text into an exception: it may contain tokens.
            raise JSONDecodeError("Invalid JSON response", "", 0) from None

    def raise_for_status(self):
        if 400 <= self.status_code < 600:
            raise HTTPError(f"HTTP request failed with status {self.status_code}", response=self)

    def close(self):
        # Responses are fully buffered and their native stream is already closed.
        return None

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()



def _normalize_url(url, params=None):
    if not isinstance(url, str) or not url or any(ord(c) < 32 or ord(c) == 127 for c in url):
        raise InvalidURL("Expected an absolute HTTPS URL")
    try:
        parts = _parse.urlsplit(url)
        if parts.scheme.lower() != "https" or not parts.hostname or parts.username is not None or parts.password is not None:
            raise ValueError
        host = parts.hostname.encode("idna").decode("ascii").lower()
        port = parts.port
        if any(c.isspace() for c in host) or any(c in host for c in "/\\?#@"):
            raise ValueError
        if ":" in host:
            # URL parser validates brackets; socket validates the IPv6 spelling.
            socket.inet_pton(socket.AF_INET6, host)
            host = "[" + host + "]"
        else:
            if not re.fullmatch(r"[a-z0-9.-]+", host) or any(not label or len(label) > 63 for label in host.rstrip(".").split(".")):
                raise ValueError
        authority = host + (":" + str(port) if port is not None else "")
        path = _parse.quote(parts.path or "/", safe="/:@-._~!$&'()*+,;=%")
        query = _parse.quote(parts.query, safe="=&?/:;+,$@-._~!()*'%")
        addition = _encode_params(params)
        if addition:
            query += ("&" if query else "") + addition
        return _parse.urlunsplit(("https", authority, path, query, ""))
    except (ValueError, UnicodeError, OSError):
        raise InvalidURL("Invalid HTTPS URL or embedded credentials") from None


def _origin(url):
    parts = _parse.urlsplit(url)
    return (parts.scheme.lower(), parts.hostname.lower(), parts.port or 443)


def _encode_params(values):
    if values is None:
        return ""
    if isinstance(values, bytes):
        try:
            values = values.decode("utf-8")
        except UnicodeError:
            raise UnsupportedOption("Encoded parameters must be UTF-8") from None
    if isinstance(values, str):
        if any(ord(c) < 32 or ord(c) == 127 for c in values):
            raise UnsupportedOption("Invalid encoded parameters")
        return _parse.quote(values, safe="=&?/:;+,$@-._~!()*'%")
    try:
        items = values.items() if isinstance(values, Mapping) else values
        filtered = []
        for key, value in items:
            if value is None:
                continue
            if isinstance(value, (list, tuple)):
                value = [item for item in value if item is not None]
            filtered.append((key, value))
        return _parse.urlencode(filtered, doseq=True)
    except (TypeError, ValueError):
        raise UnsupportedOption("Expected parameter mapping or key-value pairs") from None


def _headers(values):
    result = CaseInsensitiveDict()
    for name, value in values.items():
        if not isinstance(name, str) or not _HEADER_NAME.fullmatch(name):
            raise UnsupportedOption("Invalid HTTP header name")
        if name.lower() in ("host", "content-length", "transfer-encoding"):
            raise UnsupportedOption("Transport-controlled header cannot be overridden")
        if isinstance(value, bytes):
            value = value.decode("latin-1")
        if not isinstance(value, str) or any(ord(c) < 32 and c != "\t" or ord(c) == 127 for c in value):
            raise UnsupportedOption("Invalid HTTP header value")
        try:
            value.encode("latin-1")
        except UnicodeError:
            raise UnsupportedOption("HTTP header value must be Latin-1") from None
        result[name] = value
    return result


class _SecureRedirect(_urlrequest.HTTPRedirectHandler):
    max_redirections = 5
    max_repeats = 2

    def __init__(self, enabled=True, deadline=None):
        self.enabled, self.deadline = enabled, deadline

    def _check_deadline(self):
        if self.deadline is not None and time.monotonic() >= self.deadline:
            raise Timeout("HTTPS request elapsed deadline reached")

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        self._check_deadline()
        if not self.enabled:
            return None
        newurl = _normalize_url(newurl)
        method = req.get_method()
        if code == 303 and method != "HEAD" or code == 302 and method != "HEAD" or code == 301 and method == "POST":
            method = "GET"
        changed_method = method != req.get_method()
        other_origin = _origin(req.full_url) != _origin(newurl)
        copied = {}
        for key, value in req.header_items():
            lower = key.lower()
            if lower == "host" or changed_method and lower in ("content-length", "content-type", "transfer-encoding"):
                continue
            if other_origin and lower in ("authorization", "proxy-authorization", "cookie"):
                continue
            copied[key] = value
        return _urlrequest.Request(newurl, data=None if changed_method else req.data,
                                   headers=copied, origin_req_host=req.origin_req_host,
                                   unverifiable=True, method=method)

    def http_error_302(self, req, fp, code, msg, headers):
        self._check_deadline()
        try:
            return super().http_error_302(req, fp, code, msg, headers)
        except _error.HTTPError as error:
            if self.enabled and error.code in (301, 302, 303, 307, 308):
                raise TooManyRedirects("HTTPS redirect limit reached") from None
            raise

    http_error_301 = http_error_302
    http_error_303 = http_error_302
    http_error_307 = http_error_302
    http_error_308 = http_error_302


def _make_opener(cookies, allow_redirects, deadline=None):
    if sys.platform == "ios":
        try:
            import certifi
            context = ssl.create_default_context(cafile=certifi.where())
        except (ImportError, OSError, ValueError):
            raise SSLError("Bundled HTTPS trust store is unavailable") from None
    else:
        context = ssl.create_default_context()
    return _urlrequest.build_opener(_SecureRedirect(allow_redirects, deadline),
                                   _urlrequest.HTTPSHandler(context=context),
                                   _urlrequest.HTTPCookieProcessor(cookies))


def _read_response(stream, deadline=None):
    headers = stream.headers
    length = headers.get("Content-Length")
    if length is not None:
        try:
            if int(length) > MAX_RESPONSE_BYTES:
                raise ContentTooLarge("HTTPS response exceeds buffering limit")
        except ValueError:
            pass
    chunks, total = [], 0
    while True:
        if deadline is not None and time.monotonic() >= deadline:
            raise Timeout("HTTPS request elapsed deadline reached")
        chunk = stream.read(min(65536, MAX_RESPONSE_BYTES - total + 1))
        if deadline is not None and time.monotonic() >= deadline:
            raise Timeout("HTTPS request elapsed deadline reached")
        if not chunk:
            break
        total += len(chunk)
        if total > MAX_RESPONSE_BYTES:
            raise ContentTooLarge("HTTPS response exceeds buffering limit")
        chunks.append(chunk)
    content = b"".join(chunks)
    encoding = (headers.get("Content-Encoding") or "identity").lower().strip()
    if encoding == "gzip":
        try:
            with gzip.GzipFile(fileobj=io.BytesIO(content)) as compressed:
                content = compressed.read(MAX_RESPONSE_BYTES + 1)
        except (OSError, EOFError):
            raise ContentDecodingError("Invalid gzip HTTPS response") from None
        if len(content) > MAX_RESPONSE_BYTES:
            raise ContentTooLarge("Decoded HTTPS response exceeds buffering limit")
    elif encoding not in ("", "identity"):
        raise ContentDecodingError("Unsupported HTTPS content encoding")
    return content


class Session:
    def __init__(self):
        self.headers = CaseInsensitiveDict({"User-Agent": "AyuPluginBridge/1 requests-compat",
                                            "Accept": "*/*", "Accept-Encoding": "identity"})
        self.cookies = CookieJar()
        self._closed = False

    def request(self, method, url, *, params=None, data=None, json=None, headers=None,
                timeout=DEFAULT_TIMEOUT, stream=False, allow_redirects=True,
                verify=True, **kwargs):
        if self._closed:
            raise RequestException("HTTPS session is closed")
        if kwargs:
            raise UnsupportedOption("Unsupported requests options: " + ", ".join(sorted(kwargs)))
        if stream is not False:
            raise UnsupportedOption("Streaming responses are not implemented")
        if verify is not True:
            raise UnsupportedOption("TLS verification cannot be disabled or overridden")
        if type(allow_redirects) is not bool:
            raise UnsupportedOption("allow_redirects must be bool")
        if type(timeout) not in (int, float) or timeout <= 0 or timeout > MAX_TIMEOUT or not math.isfinite(timeout):
            raise UnsupportedOption("timeout must be a positive finite number of seconds, at most 60")
        if not isinstance(method, str) or not re.fullmatch(r"[A-Za-z]+", method):
            raise UnsupportedOption("Invalid HTTP method")
        url = _normalize_url(url, params)
        merged = self.headers.copy()
        if headers is not None:
            if not isinstance(headers, Mapping):
                raise UnsupportedOption("headers must be a mapping")
            for name, value in headers.items():
                if value is None:
                    merged.pop(name, None)
                else:
                    merged[name] = value
        merged = _headers(merged)
        if data is not None and json is not None:
            raise UnsupportedOption("Pass data or json, not both")
        if json is not None:
            try:
                payload = _json.dumps(json, allow_nan=False, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            except (ValueError, TypeError, RecursionError):
                raise UnsupportedOption("Request JSON must be finite and serializable") from None
            merged.setdefault("Content-Type", "application/json")
        elif isinstance(data, (Mapping, list, tuple)):
            payload = _encode_params(data).encode("utf-8")
            merged.setdefault("Content-Type", "application/x-www-form-urlencoded")
        elif isinstance(data, str):
            payload = data.encode("utf-8")
        elif isinstance(data, (bytes, bytearray)):
            payload = bytes(data)
        elif data is None:
            payload = None
        else:
            raise UnsupportedOption("Unsupported request body type")
        if payload is not None and len(payload) > MAX_REQUEST_BYTES:
            raise ContentTooLarge("HTTPS request body exceeds limit")
        request = _urlrequest.Request(url, data=payload, headers=dict(merged.items()), method=method.upper())
        response = None
        deadline = time.monotonic() + timeout
        try:
            opener = _make_opener(self.cookies, allow_redirects, deadline)
            try:
                response = opener.open(request, timeout=float(timeout))
            except _error.HTTPError as error:
                # requests returns responses for HTTP status errors; only
                # raise_for_status() converts 4xx/5xx into HTTPError.
                response = error
            body = b"" if request.get_method() == "HEAD" else _read_response(response, deadline)
            final_url = _normalize_url(response.geturl())
            status = response.status if getattr(response, "status", None) is not None else response.code
            return Response(status, body, response.headers, final_url)
        except RequestException:
            raise
        except (socket.timeout, TimeoutError):
            raise Timeout("HTTPS request timed out") from None
        except ssl.SSLError:
            raise SSLError("HTTPS TLS verification or negotiation failed") from None
        except _error.URLError as error:
            if isinstance(error.reason, (socket.timeout, TimeoutError)):
                raise Timeout("HTTPS request timed out") from None
            if isinstance(error.reason, ssl.SSLError):
                raise SSLError("HTTPS TLS verification or negotiation failed") from None
            raise ConnectionError("HTTPS connection failed") from None
        except (OSError, ValueError):
            raise ConnectionError("HTTPS connection or response failed") from None
        finally:
            if response is not None:
                response.close()

    def get(self, url, params=None, **kwargs):
        return self.request("GET", url, params=params, **kwargs)

    def post(self, url, data=None, json=None, **kwargs):
        return self.request("POST", url, data=data, json=json, **kwargs)

    def put(self, url, data=None, **kwargs):
        return self.request("PUT", url, data=data, **kwargs)

    def patch(self, url, data=None, **kwargs):
        return self.request("PATCH", url, data=data, **kwargs)

    def delete(self, url, **kwargs):
        return self.request("DELETE", url, **kwargs)

    def head(self, url, **kwargs):
        kwargs.setdefault("allow_redirects", False)
        return self.request("HEAD", url, **kwargs)

    def options(self, url, **kwargs):
        return self.request("OPTIONS", url, **kwargs)

    def close(self):
        self._closed = True
        self.cookies.clear()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


def request(method, url, **kwargs):
    with Session() as session:
        return session.request(method, url, **kwargs)


def get(url, params=None, **kwargs):
    return request("GET", url, params=params, **kwargs)


def post(url, data=None, json=None, **kwargs):
    return request("POST", url, data=data, json=json, **kwargs)


def put(url, data=None, **kwargs):
    return request("PUT", url, data=data, **kwargs)


def patch(url, data=None, **kwargs):
    return request("PATCH", url, data=data, **kwargs)


def delete(url, **kwargs):
    return request("DELETE", url, **kwargs)


def head(url, **kwargs):
    kwargs.setdefault("allow_redirects", False)
    return request("HEAD", url, **kwargs)


def options(url, **kwargs):
    return request("OPTIONS", url, **kwargs)
