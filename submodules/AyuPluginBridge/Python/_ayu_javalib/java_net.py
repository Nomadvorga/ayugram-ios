"""``java.net`` URL value classes, form encoding and HTTPS connections.

``URL``/``URI`` parsing and ``URLEncoder``/``URLDecoder`` are pure logic. A connection
is carried by the SDK's ``requests`` module and obeys its policy unchanged: the host
must declare ``requests`` in ``capabilities.modules``, only ``https`` without embedded
credentials is allowed, TLS verification cannot be disabled, bodies are fully buffered
within the module's size limits and the call blocks the plugin thread, never main.
"""
from __future__ import annotations

from urllib import parse as _parse

from . import java_io as _io
from . import java_lang as _l
from .java_lang import Comparable, IllegalArgumentException, IllegalStateException, NullPointerException, Object

MalformedURLException = _l._throwable("MalformedURLException", _io.IOException)
UnknownHostException = _l._throwable("UnknownHostException", _io.IOException)
SocketException = _l._throwable("SocketException", _io.IOException)
ConnectException = _l._throwable("ConnectException", SocketException)
SocketTimeoutException = _l._throwable("SocketTimeoutException", _io.InterruptedIOException)
ProtocolException = _l._throwable("ProtocolException", _io.IOException)
UnknownServiceException = _l._throwable("UnknownServiceException", _io.IOException)
SSLException = _l._throwable("SSLException", _io.IOException)


class URISyntaxException(_l.Exception_):
    def __init__(self, text, reason, index=-1):
        if text is None or reason is None:
            raise NullPointerException()
        if index < -1:
            raise IllegalArgumentException()
        _l.Exception_.__init__(self, reason + (f" at index {index}" if index > -1 else "") + ": " + text)
        self._input, self._reason, self._index = text, reason, index

    def getInput(self):
        return self._input

    def getReason(self):
        return self._reason

    def getIndex(self):
        return self._index


_UNRESERVED = frozenset(b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-*_")
_DEFAULT_PORTS = {"http": 80, "https": 443, "ftp": 21, "file": -1, "jar": -1}


class URLEncoder(Object):
    __ayu_overrides_host__ = True  # the Swift adapter is a subset; the host neither takes nor returns one
    def __init__(self):
        raise _l.unsupported("java.net.URLEncoder cannot be constructed")

    @staticmethod
    def encode(text, charset=None):
        data = bytes(_l.encode_text(_l._text(text), charset))[2 if _l._is_utf16(charset) else 0:]
        return "".join(chr(item) if item in _UNRESERVED else "+" if item == 32 else "%%%02X" % item for item in data)


class URLDecoder(Object):
    def __init__(self):
        raise _l.unsupported("java.net.URLDecoder cannot be constructed")

    @staticmethod
    def decode(text, charset=None):
        text = _l._text(text)
        name = _l.charset_name(charset)
        out, pending, index = [], bytearray(), 0

        def flush():
            if pending:
                out.append(bytes(pending).decode(name, "replace"))
                pending.clear()

        while index < len(text):
            char = text[index]
            if char == "%":
                digits = text[index + 1:index + 3]
                if len(digits) < 2:
                    raise IllegalArgumentException("URLDecoder: Incomplete trailing escape (%) pattern")
                try:
                    if not digits.isascii() or digits[0] in "+-":
                        raise ValueError
                    pending.append(int(digits, 16))
                except ValueError:
                    raise IllegalArgumentException(
                        'URLDecoder: Illegal hex characters in escape (%) pattern - For input string: "'
                        + digits + '"') from None
                index += 3
                continue
            flush()
            out.append(" " if char == "+" else char)
            index += 1
        flush()
        return "".join(out)


def _split_authority(authority):
    """(user info, host, port) of a URI authority; the port is -1 when absent."""
    if authority is None:
        return None, None, -1
    user, at, rest = authority.rpartition("@")
    host, port = rest, -1
    if rest.startswith("["):
        end = rest.find("]")
        if end < 0:
            raise ValueError("Malformed IPv6 address")
        host, tail = rest[:end + 1], rest[end + 1:]
        if tail:
            if not tail.startswith(":"):
                raise ValueError("Malformed authority")
            port = int(tail[1:]) if tail[1:] else -1
    elif ":" in rest:
        host, _, digits = rest.rpartition(":")
        if digits:
            if not digits.isascii() or not digits.isdigit():
                raise ValueError("Malformed port")
            port = int(digits)
    return (user if at else None), host, port


class URI(Comparable):
    """RFC 2396 URI reference. Components are parsed, not resolved against a network."""

    def __init__(self, *args):
        if len(args) == 1:
            text = args[0]
        elif len(args) == 3:
            scheme, part, fragment = args
            text = (scheme + ":" if scheme else "") + _quote(part, "/?:@&=+$,;[]!*'()-_.~") + \
                ("#" + _quote(fragment, "/?:@&=+$,;!*'()-_.~") if fragment is not None else "")
        elif len(args) == 4:
            text = _build(args[0], None, args[1], -1, args[2], None, args[3])
        elif len(args) == 5:
            scheme, authority, path, query, fragment = args
            text = _build(scheme, None, authority, -1, path, query, fragment, raw_authority=True)
        elif len(args) == 7:
            text = _build(*args)
        else:
            raise TypeError("Unsupported URI constructor")
        if text is None:
            raise NullPointerException()
        self._text = text
        self._parse(text)

    @staticmethod
    def create(text):
        try:
            return URI(text)
        except URISyntaxException as error:
            raise IllegalArgumentException(error.getMessage(), error) from error

    def _parse(self, text):
        for index, char in enumerate(text):
            if char <= " " or char in '"<>\\^`{|}' or char == "\x7f":
                raise URISyntaxException(text, "Illegal character", index)
        if not text:
            self._scheme = self._fragment = self._authority = self._query = self._user = self._host = None
            self._path, self._port, self._opaque = "", -1, None
            return
        rest, _, fragment = text.partition("#")
        self._fragment = fragment if "#" in text else None
        self._scheme = None
        colon = rest.find(":")
        if colon > 0 and "/" not in rest[:colon] and "?" not in rest[:colon]:
            scheme = rest[:colon]
            if not scheme[0].isalpha() or not scheme.isascii() or \
                    not all(char.isalnum() or char in "+-." for char in scheme):
                raise URISyntaxException(text, "Illegal character in scheme name", 0)
            self._scheme, rest = scheme, rest[colon + 1:]
            if not rest:
                raise URISyntaxException(text, "Expected scheme-specific part", len(text))
        elif colon == 0:
            raise URISyntaxException(text, "Expected scheme name", 0)
        self._opaque = rest if self._scheme is not None and not rest.startswith("/") else None
        self._authority = self._query = self._user = self._host = None
        self._path, self._port = None, -1
        if self._opaque is not None:
            return
        rest, mark, query = rest.partition("?")
        self._query = query if mark else None
        if rest.startswith("//"):
            authority, slash, path = rest[2:].partition("/")
            self._path = slash + path
            if authority:
                self._authority = authority
                try:
                    self._user, self._host, self._port = _split_authority(authority)
                except ValueError:
                    # A registry-based authority has no host or port.
                    self._user, self._host, self._port = None, None, -1
                if not self._host:
                    self._host = None
        else:
            self._path = rest

    def getScheme(self):
        return self._scheme

    def isAbsolute(self):
        return self._scheme is not None

    def isOpaque(self):
        return self._opaque is not None

    def getRawSchemeSpecificPart(self):
        text = self._text.partition("#")[0]
        return text[len(self._scheme) + 1:] if self._scheme is not None else text

    def getSchemeSpecificPart(self):
        return _unquote(self.getRawSchemeSpecificPart())

    def getRawAuthority(self):
        return self._authority

    def getAuthority(self):
        return _unquote(self._authority)

    def getRawUserInfo(self):
        return self._user

    def getUserInfo(self):
        return _unquote(self._user)

    def getHost(self):
        return self._host

    def getPort(self):
        return self._port

    def getRawPath(self):
        return self._path

    def getPath(self):
        return _unquote(self._path)

    def getRawQuery(self):
        return self._query

    def getQuery(self):
        return _unquote(self._query)

    def getRawFragment(self):
        return self._fragment

    def getFragment(self):
        return _unquote(self._fragment)

    def normalize(self):
        if self._opaque is not None or not self._path:
            return self
        segments, result = self._path.split("/"), []
        absolute = self._path.startswith("/")
        for position, segment in enumerate(segments):
            last = position == len(segments) - 1
            if segment == ".":
                if last:
                    result.append("")
                continue
            if segment == ".." and result and result[-1] not in ("..", ""):
                result.pop()
                if last:
                    result.append("")
            elif segment == ".." and absolute and result == [""]:
                result.append(segment)
            else:
                result.append(segment)
        path = "/".join(result)
        if path == self._path:
            return self
        return URI(_assemble(self._scheme, self._authority, path, self._query, self._fragment))

    def resolve(self, other):
        other = other if isinstance(other, URI) else URI.create(other)
        if other._opaque is not None or self._opaque is not None or other._scheme is not None:
            return other
        if other._authority is not None:
            return URI(_assemble(self._scheme, other._authority, other._path, other._query, other._fragment))
        if not other._path and other._query is None:
            if other._fragment is None:
                return self
            return URI(_assemble(self._scheme, self._authority, self._path, self._query, other._fragment))
        if other._path.startswith("/"):
            path = other._path
        else:
            base = self._path or ""
            path = base[:base.rfind("/") + 1] + other._path
            if self._authority is not None and not path.startswith("/"):
                path = "/" + path
        return URI(_assemble(self._scheme, self._authority, path, other._query, other._fragment)).normalize()

    def relativize(self, other):
        if other._opaque is not None or self._opaque is not None or \
                (self._scheme or "").lower() != (other._scheme or "").lower() or self._authority != other._authority:
            return other
        base = self.normalize()._path or ""
        target = other.normalize()._path or ""
        if base != target:
            if not base.endswith("/"):
                base += "/"
            if not target.startswith(base):
                return other
        return URI(_assemble(None, None, target[len(base):], other._query, other._fragment))

    def toURL(self):
        if self._scheme is None:
            raise IllegalArgumentException("URI is not absolute")
        return URL(self._text)

    def toString(self):
        return self._text

    def toASCIIString(self):
        return "".join(char if ord(char) < 128 else _parse.quote(char) for char in self._text)

    def __repr__(self):
        return self._text

    def __eq__(self, other):
        return isinstance(other, URI) and self._key() == other._key()

    def _key(self):
        return ((self._scheme or "").lower(), self._opaque, (self._host or "").lower() if self._host else self._authority,
                self._user, self._port, self._path, self._query, self._fragment)

    def __hash__(self):
        return hash(self._key())

    def hashCode(self):
        return _l.string_hash(self._text)

    def compareTo(self, other):
        return _l.String(self._text).compareTo(other._text)

    def to_bridge(self):
        return self._text


def _quote(text, safe):
    return None if text is None else _parse.quote(text, safe=safe + "%")


def _unquote(text):
    return None if text is None else _parse.unquote(text, errors="replace")


def _assemble(scheme, authority, path, query, fragment):
    return (scheme + ":" if scheme is not None else "") + ("//" + authority if authority is not None else "") + \
        (path or "") + ("?" + query if query is not None else "") + ("#" + fragment if fragment is not None else "")


def _build(scheme, user, host, port, path, query, fragment, raw_authority=False):
    if scheme is not None and path and not path.startswith("/"):
        raise URISyntaxException(path, "Relative path in absolute URI")
    authority = None
    if host is not None:
        if raw_authority:
            authority = _quote(host, "@:[]!$&'()*+,;=-_.~")
        else:
            bracketed = "[" + host + "]" if ":" in host and not host.startswith("[") else host
            authority = (_quote(user, "!$&'()*+,;=:-_.~") + "@" if user is not None else "") + bracketed + \
                (":" + str(port) if port != -1 else "")
    return _assemble(scheme, authority, _quote(path, "/!$&'()*+,;=:@-_.~"),
                     _quote(query, "/?!$&'()*+,;=:@-_.~[]"), _quote(fragment, "/?!$&'()*+,;=:@-_.~[]"))


class URL(Object):
    __ayu_overrides_host__ = True  # the Swift adapter is a subset; the host neither takes nor returns one
    def __init__(self, *args):
        if len(args) == 1:
            spec, context = args[0], None
        elif len(args) == 2:
            context, spec = args
        elif len(args) in (3, 4):
            protocol, host = args[0], args[1]
            port, path = (args[2], args[3]) if len(args) == 4 else (-1, args[2])
            if port < -1:
                raise MalformedURLException(f"Invalid port number :{port}")
            host = "[" + host + "]" if host and ":" in host and not host.startswith("[") else host
            spec, context = f"{protocol}://{host or ''}{':' + str(port) if port != -1 else ''}{path}", None
        else:
            raise TypeError("Unsupported URL constructor")
        if spec is None:
            raise MalformedURLException("null" if context is None else "no protocol: null")
        spec = _l._text(spec).strip("".join(map(chr, range(33))))
        if spec[:4].lower() == "url:":
            spec = spec[4:]
        colon = spec.find(":")
        scheme = spec[:colon] if colon > 0 and spec[0].isalpha() and all(
            char.isalnum() and char.isascii() or char in "+-." for char in spec[:colon]) else None
        if scheme is None or context is not None and scheme.lower() == context._protocol and \
                not spec[colon + 1:].startswith("/"):
            if context is None:
                raise MalformedURLException("no protocol: " + spec)
            spec = _parse.urljoin(context.toExternalForm(), spec if scheme is None else spec[colon + 1:])
            scheme = context._protocol
        self._protocol = scheme.lower()
        if self._protocol not in _DEFAULT_PORTS:
            raise MalformedURLException("unknown protocol: " + self._protocol)
        rest, mark, self._ref = spec[len(scheme) + 1:].partition("#")
        self._ref = self._ref if mark else None
        rest, mark, self._query = rest.partition("?")
        self._query = self._query if mark else None
        self._authority, self._user, self._host, self._port = None, None, "", -1
        if rest.startswith("//"):
            authority, slash, path = rest[2:].partition("/")
            self._path, self._authority = slash + path, authority
            try:
                self._user, self._host, self._port = _split_authority(authority)
            except ValueError as error:
                raise MalformedURLException(str(error)) from None
        else:
            self._path = rest

    def getProtocol(self):
        return self._protocol

    def getHost(self):
        return self._host

    def getPort(self):
        return self._port

    def getDefaultPort(self):
        return _DEFAULT_PORTS[self._protocol]

    def getAuthority(self):
        return self._authority

    def getUserInfo(self):
        return self._user

    def getPath(self):
        return self._path

    def getQuery(self):
        return self._query

    def getRef(self):
        return self._ref

    def getFile(self):
        return self._path + ("?" + self._query if self._query is not None else "")

    def toExternalForm(self):
        return self._protocol + ":" + ("//" + self._authority if self._authority is not None else "") + \
            self.getFile() + ("#" + self._ref if self._ref is not None else "")

    toString = toExternalForm

    def __repr__(self):
        return self.toExternalForm()

    def toURI(self):
        return URI(self.toExternalForm())

    def sameFile(self, other):
        return isinstance(other, URL) and (self._protocol, self._host.lower(), self._effective_port(), self.getFile()) \
            == (other._protocol, other._host.lower(), other._effective_port(), other.getFile())

    def _effective_port(self):
        return self._port if self._port != -1 else self.getDefaultPort()

    def __eq__(self, other):
        return self.sameFile(other) and self._ref == other._ref

    def __hash__(self):
        return hash((self._protocol, self._host.lower(), self._effective_port(), self.getFile(), self._ref))

    def hashCode(self):
        return _l.i32(_l.string_hash(self._protocol) + _l.string_hash(self._host.lower()) + self._effective_port()
                      + _l.string_hash(self.getFile()) + (_l.string_hash(self._ref) if self._ref else 0))

    def to_bridge(self):
        return self.toExternalForm()

    def openConnection(self, proxy=None):
        if proxy is not None:
            raise _l.unsupported("Proxied connections are not supported")
        if self._protocol not in ("http", "https"):
            raise _l.unsupported(f"URL connections are not supported for the {self._protocol} protocol")
        return (HttpsURLConnection if self._protocol == "https" else HttpURLConnection)._open(self)

    def openStream(self):
        return self.openConnection().getInputStream()

    def getContent(self, *args):
        raise _l.unsupported("URL.getContent is not supported; read openStream()")


def _requests():
    """The SDK requests module, only when the host declares it for plugins."""
    scope = _l.active_scope()
    if scope is not None:
        from ayu_bridge import runtime
        if "requests" in runtime.capabilities["modules"]:
            import requests
            return requests
    raise _l.unsupported("Network access needs the host-declared requests module")


class URLConnection(Object):
    def __init__(self, *args):
        raise _l.unsupported("Use URL.openConnection()")


class HttpURLConnection(URLConnection):
    """One buffered HTTPS exchange; the request is sent when the response is first needed."""
    HTTP_OK, HTTP_CREATED, HTTP_ACCEPTED, HTTP_NOT_AUTHORITATIVE, HTTP_NO_CONTENT, HTTP_RESET = 200, 201, 202, 203, 204, 205
    HTTP_PARTIAL, HTTP_MULT_CHOICE, HTTP_MOVED_PERM, HTTP_MOVED_TEMP, HTTP_SEE_OTHER = 206, 300, 301, 302, 303
    HTTP_NOT_MODIFIED, HTTP_USE_PROXY, HTTP_BAD_REQUEST, HTTP_UNAUTHORIZED, HTTP_PAYMENT_REQUIRED = 304, 305, 400, 401, 402
    HTTP_FORBIDDEN, HTTP_NOT_FOUND, HTTP_BAD_METHOD, HTTP_NOT_ACCEPTABLE, HTTP_PROXY_AUTH = 403, 404, 405, 406, 407
    HTTP_CLIENT_TIMEOUT, HTTP_CONFLICT, HTTP_GONE, HTTP_LENGTH_REQUIRED, HTTP_PRECON_FAILED = 408, 409, 410, 411, 412
    HTTP_ENTITY_TOO_LARGE, HTTP_REQ_TOO_LONG, HTTP_UNSUPPORTED_TYPE, HTTP_INTERNAL_ERROR = 413, 414, 415, 500
    HTTP_NOT_IMPLEMENTED, HTTP_BAD_GATEWAY, HTTP_UNAVAILABLE, HTTP_GATEWAY_TIMEOUT, HTTP_VERSION = 501, 502, 503, 504, 505
    _METHODS = ("GET", "POST", "HEAD", "OPTIONS", "PUT", "DELETE", "TRACE", "PATCH")

    @classmethod
    def _open(cls, url):
        _requests()
        connection = object.__new__(cls)
        connection._url, connection._method, connection._headers = url, "GET", []
        connection._connect_timeout = connection._read_timeout = 0
        connection._do_output, connection._redirects = False, True
        connection._body, connection._response = None, None
        return connection

    def _unsent(self):
        if self._response is not None:
            raise IllegalStateException("Already connected")

    def getURL(self):
        return self._url

    def setRequestMethod(self, method):
        self._unsent()
        if method not in HttpURLConnection._METHODS:
            raise ProtocolException("Invalid HTTP method: " + _l.jstr(method))
        self._method = method

    def getRequestMethod(self):
        return self._method

    def setRequestProperty(self, key, value):
        self._unsent()
        if key is None:
            raise NullPointerException("key is null")
        self._headers = [item for item in self._headers if item[0].lower() != key.lower()]
        if value is not None:
            self._headers.append((key, value))

    def addRequestProperty(self, key, value):
        self._unsent()
        if key is None:
            raise NullPointerException("key is null")
        self._headers.append((key, value))

    def getRequestProperty(self, key):
        return next((value for name, value in reversed(self._headers) if name.lower() == key.lower()), None)

    def setConnectTimeout(self, millis):
        if millis < 0:
            raise IllegalArgumentException("timeout can not be negative")
        self._connect_timeout = millis

    def setReadTimeout(self, millis):
        if millis < 0:
            raise IllegalArgumentException("timeout can not be negative")
        self._read_timeout = millis

    def getConnectTimeout(self):
        return self._connect_timeout

    def getReadTimeout(self):
        return self._read_timeout

    def setDoOutput(self, value):
        self._unsent()
        self._do_output = bool(value)

    def getDoOutput(self):
        return self._do_output

    def setDoInput(self, value):
        self._unsent()
        if not value:
            raise _l.unsupported("A connection without input is not supported")

    def getDoInput(self):
        return True

    def setInstanceFollowRedirects(self, value):
        self._redirects = bool(value)

    def getInstanceFollowRedirects(self):
        return self._redirects

    # Transport hints: there is no response cache and the exchange is always fully buffered.
    def setUseCaches(self, value):
        return None

    def getUseCaches(self):
        return False

    def setFixedLengthStreamingMode(self, length):
        self._unsent()

    def setChunkedStreamingMode(self, length):
        self._unsent()

    def usingProxy(self):
        return False

    def getOutputStream(self):
        self._unsent()
        if not self._do_output:
            raise ProtocolException("cannot write to a URLConnection if doOutput=false - call setDoOutput(true)")
        if self._method == "GET":
            self._method = "POST"
        if self._body is None:
            self._body = _io.ByteArrayOutputStream()
        return self._body

    def connect(self):
        self._exchange()

    def _exchange(self):
        if self._response is not None:
            return self._response
        requests = _requests()
        if self._url.getProtocol() != "https":
            raise _io.IOException(f"Cleartext HTTP traffic to {self._url.getHost()} not permitted")
        headers = {}
        for name, value in self._headers:
            headers[name] = headers[name] + ", " + value if name in headers else value
        # Java's 0 means no limit; the SDK transport never waits longer than its own maximum.
        seconds = (self._connect_timeout + self._read_timeout) / 1000.0
        timeout = min(seconds, requests.MAX_TIMEOUT) if seconds > 0 else requests.MAX_TIMEOUT
        body = bytes(self._body.toByteArray()) if self._body is not None else None
        try:
            self._response = requests.request(self._method, self._url.toExternalForm().partition("#")[0],
                                              headers=headers, data=body, timeout=timeout,
                                              allow_redirects=self._redirects)
        except requests.Timeout as error:
            raise SocketTimeoutException(str(error)) from None
        except requests.SSLError as error:
            raise SSLException(str(error)) from None
        except requests.ConnectionError as error:
            raise ConnectException(str(error)) from None
        except requests.RequestException as error:
            raise _io.IOException(str(error)) from None
        return self._response

    def getResponseCode(self):
        return self._exchange().status_code

    def getResponseMessage(self):
        from http import HTTPStatus
        try:
            return HTTPStatus(self._exchange().status_code).phrase
        except ValueError:
            return None

    def getInputStream(self):
        response = self._exchange()
        if response.status_code >= 400:
            address = self._url.toExternalForm()
            if response.status_code in (404, 410):
                raise _io.FileNotFoundException(address)
            raise _io.IOException(f"Server returned HTTP response code: {response.status_code} for URL: {address}")
        return _io.ByteArrayInputStream(response.content)

    def getErrorStream(self):
        if self._response is None or self._response.status_code < 400:
            return None
        return _io.ByteArrayInputStream(self._response.content)

    def getHeaderField(self, key):
        response = self._exchange()
        if _l.is_int(key):
            names = list(response.headers)
            if key == 0:
                return f"HTTP/1.1 {response.status_code} {self.getResponseMessage() or ''}".rstrip()
            return response.headers[names[key - 1]] if 0 < key <= len(names) else None
        return None if key is None else response.headers.get(key)

    def getHeaderFieldKey(self, index):
        names = list(self._exchange().headers)
        return names[index - 1] if 0 < index <= len(names) else None

    def getHeaderFields(self):
        from . import java_util
        fields = java_util.LinkedHashMap()
        for name in self._exchange().headers:
            fields.put(name, java_util.Collections.singletonList(self._response.headers[name]))
        return java_util.Collections.unmodifiableMap(fields)

    def getHeaderFieldInt(self, key, default):
        try:
            return _l.Integer.parseInt(self.getHeaderField(key))
        except _l.NumberFormatException:
            return default

    getHeaderFieldLong = getHeaderFieldInt

    def getContentType(self):
        return self.getHeaderField("content-type")

    def getContentEncoding(self):
        return self.getHeaderField("content-encoding")

    def getContentLength(self):
        length = self.getContentLengthLong()
        return length if length <= _l.INT_MAX else -1

    def getContentLengthLong(self):
        try:
            return _l.Long.parseLong(self.getHeaderField("content-length"))
        except _l.NumberFormatException:
            return -1

    def disconnect(self):
        return None


class HttpsURLConnection(HttpURLConnection):
    def setSSLSocketFactory(self, factory):
        raise _l.unsupported("TLS verification cannot be disabled or overridden")

    setHostnameVerifier = setSSLSocketFactory


CLASSES = _l.register({
    "java.net.URL": URL,
    "java.net.URI": URI,
    "java.net.URLEncoder": URLEncoder,
    "java.net.URLDecoder": URLDecoder,
    "java.net.URLConnection": URLConnection,
    "java.net.HttpURLConnection": HttpURLConnection,
    "javax.net.ssl.HttpsURLConnection": HttpsURLConnection,
    "java.net.MalformedURLException": MalformedURLException,
    "java.net.URISyntaxException": URISyntaxException,
    "java.net.UnknownHostException": UnknownHostException,
    "java.net.SocketException": SocketException,
    "java.net.ConnectException": ConnectException,
    "java.net.SocketTimeoutException": SocketTimeoutException,
    "java.net.ProtocolException": ProtocolException,
    "java.net.UnknownServiceException": UnknownServiceException,
    "javax.net.ssl.SSLException": SSLException,
})
