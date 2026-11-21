"""Offline tests for the deliberately small requests facade."""
from __future__ import annotations

import gzip
import importlib.util
import io
import json
from pathlib import Path
import socket
import ssl
import sys
import types
import unittest
from unittest.mock import patch
from urllib import error as urlerror
from urllib import request as urlrequest

PATH = Path(__file__).resolve().parents[2] / "Python" / "requests.py"
SPEC = importlib.util.spec_from_file_location("ayu_requests_test", PATH)
compat = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(compat)


class FakeResponse(io.BytesIO):
    def __init__(self, body=b"{}", status=200, headers=None, url="https://example.test/result"):
        super().__init__(body)
        self.status = status
        self.headers = compat.CaseInsensitiveDict(headers or {"Content-Type": "application/json"})
        self.final_url = url

    def geturl(self):
        return self.final_url


class FakeOpener:
    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []

    def open(self, request, timeout):
        self.calls.append((request, timeout))
        response = self.responses.pop(0)
        if isinstance(response, BaseException):
            raise response
        return response


class RequestsCompatibilityTests(unittest.TestCase):
    def run_request(self, response, method="GET", url="https://example.test/start", **kwargs):
        opener = FakeOpener([response])
        with patch.object(compat, "_make_opener", return_value=opener):
            result = compat.request(method, url, **kwargs)
        return result, opener

    def test_query_json_headers_and_final_url(self):
        body = '{"title":"Музыка"}'.encode()
        raw = FakeResponse(body, url="https://music.example/final?x=1")
        response, opener = self.run_request(raw, url="https://example.test/find?existing=1",
                                            params={"q": "a b", "tags": ["x", "y"], "skip": None},
                                            headers={"Authorization": "Bearer test-only"}, timeout=2.5)
        request, timeout = opener.calls[0]
        self.assertEqual(timeout, 2.5)
        self.assertEqual(request.full_url, "https://example.test/find?existing=1&q=a+b&tags=x&tags=y")
        self.assertEqual(request.get_header("Authorization"), "Bearer test-only")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.url, "https://music.example/final?x=1")
        self.assertEqual(response.json(), {"title": "Музыка"})
        self.assertIn("Музыка", response.text)
        self.assertTrue(raw.closed)

    def test_post_json_form_and_raw_bytes(self):
        result, opener = self.run_request(FakeResponse(), "POST", json={"voice": "пример"})
        request = opener.calls[0][0]
        self.assertEqual(json.loads(request.data), {"voice": "пример"})
        self.assertEqual(request.get_header("Content-type"), "application/json")
        _, opener = self.run_request(FakeResponse(), "POST", data={"x": "a b"})
        self.assertEqual(opener.calls[0][0].data, b"x=a+b")
        self.assertEqual(opener.calls[0][0].get_header("Content-type"), "application/x-www-form-urlencoded")
        _, opener = self.run_request(FakeResponse(), "POST", data=b"OggS\x00")
        self.assertEqual(opener.calls[0][0].data, b"OggS\x00")

    def test_http_error_is_response_until_raise_for_status(self):
        stream = FakeResponse(b'{"error":"unavailable"}', status=404)
        error = urlerror.HTTPError("https://example.test/private?token=secret", 404,
                                   "not found", {"Content-Type": "application/json"}, stream)
        response, _ = self.run_request(error)
        self.assertEqual(response.status_code, 404)
        self.assertFalse(response.ok)
        self.assertEqual(response.json()["error"], "unavailable")
        with self.assertRaises(compat.HTTPError) as caught:
            response.raise_for_status()
        self.assertIs(caught.exception.response, response)
        self.assertNotIn("secret", str(caught.exception))
        self.assertTrue(stream.closed)

    def test_response_json_failure_does_not_echo_payload(self):
        response = compat.Response(200, b"private-api-key-secret", {}, "https://example.test/")
        with self.assertRaises(compat.exceptions.RequestException) as caught:
            response.json()
        self.assertIsInstance(caught.exception, compat.exceptions.JSONDecodeError)
        self.assertNotIn("private-api-key-secret", str(caught.exception))

    def test_transport_error_types_are_sanitized(self):
        for original, expected in [
            (urlerror.URLError(socket.timeout("token=secret")), compat.Timeout),
            (urlerror.URLError(ssl.SSLError("token=secret")), compat.SSLError),
            (urlerror.URLError("https://user:secret@example.test/"), compat.ConnectionError),
        ]:
            with self.assertRaises(expected) as caught:
                self.run_request(original)
            self.assertNotIn("secret", str(caught.exception))

    def test_buffered_response_and_decoded_gzip_limits(self):
        for headers in ({}, {"Content-Length": "17"}):
            raw = FakeResponse(b"x" * 17, headers=headers)
            with patch.object(compat, "MAX_RESPONSE_BYTES", 16):
                with self.assertRaises(compat.ContentTooLarge):
                    self.run_request(raw)
            self.assertTrue(raw.closed)
        raw = FakeResponse(gzip.compress(b"x" * 1000), headers={"Content-Encoding": "gzip"})
        with patch.object(compat, "MAX_RESPONSE_BYTES", 64):
            with self.assertRaises(compat.ContentTooLarge):
                self.run_request(raw)
        raw = FakeResponse(gzip.compress(b"hello"), headers={"Content-Encoding": "gzip"})
        response, _ = self.run_request(raw)
        self.assertEqual(response.content, b"hello")

    def test_invalid_urls_options_and_header_injection_fail_before_network(self):
        with patch.object(compat, "_make_opener") as factory:
            for url in ("http://example.test/", "file:///private", "https://user:secret@example.test/", "https://example.test/\nHost:evil"):
                with self.assertRaises(compat.InvalidURL) as caught:
                    compat.get(url)
                self.assertNotIn("secret", str(caught.exception))
            for options in ({"stream": True}, {"verify": False}, {"timeout": None},
                            {"timeout": (1, 2)}, {"files": {"x": "unsupported"}},
                            {"headers": {"Authorization": "Bearer secret\r\nX-Evil:1"}},
                            {"headers": {"Host": "another.example"}}):
                with self.assertRaises(compat.UnsupportedOption):
                    compat.get("https://example.test/", **options)
            factory.assert_not_called()

    def test_elapsed_deadline_checks_without_live_network(self):
        raw = FakeResponse(b"hello")
        with patch.object(compat.time, "monotonic", side_effect=[0.0, 20.0]):
            with self.assertRaises(compat.Timeout):
                compat._read_response(raw, deadline=10.0)
        handler = compat._SecureRedirect(deadline=10.0)
        with patch.object(compat.time, "monotonic", return_value=11.0):
            with self.assertRaises(compat.Timeout):
                handler.redirect_request(urlrequest.Request("https://a.example/"), None, 302, "", {}, "https://b.example/")
        with patch.object(compat, "_make_opener") as factory:
            with self.assertRaises(compat.UnsupportedOption):
                compat.get("https://example.test/", timeout=61)
            factory.assert_not_called()

    def test_session_headers_are_not_shared_and_close_is_final(self):
        a, b = compat.Session(), compat.Session()
        a.headers["X-Scoped"] = "a"
        self.assertNotIn("X-Scoped", b.headers)
        a.close()
        with self.assertRaisesRegex(compat.RequestException, "closed"):
            a.get("https://example.test/")
        b.close()

    def test_redirect_strips_cross_origin_credentials_preserves_body_for_307(self):
        handler = compat._SecureRedirect()
        original = urlrequest.Request("https://a.example/path", data=b"body", method="POST", headers={
            "Authorization": "Bearer secret", "Cookie": "token=secret", "X-Keep": "yes",
            "Content-Type": "application/octet-stream"})
        redirected = handler.redirect_request(original, None, 307, "", {}, "https://b.example/new")
        self.assertEqual(redirected.get_method(), "POST")
        self.assertEqual(redirected.data, b"body")
        self.assertIsNone(redirected.get_header("Authorization"))
        self.assertIsNone(redirected.get_header("Cookie"))
        self.assertEqual(redirected.get_header("X-keep"), "yes")
        same = handler.redirect_request(original, None, 307, "", {}, "https://a.example/new")
        self.assertEqual(same.get_header("Authorization"), "Bearer secret")
        with self.assertRaises(compat.InvalidURL):
            handler.redirect_request(original, None, 302, "", {}, "http://a.example/down")
        with self.assertRaises(compat.InvalidURL):
            handler.redirect_request(original, None, 302, "", {}, "file:///private")

    def test_303_switches_post_to_get_and_relative_location_is_resolved(self):
        handler = compat._SecureRedirect()
        original = urlrequest.Request("https://a.example/a/b/start", data=b"body", method="POST",
                                      headers={"Content-Type": "application/json"})
        original.timeout = 5
        final = FakeResponse(b"ok", url="https://a.example/next?x=1")
        parent = FakeOpener([final])
        handler.parent = parent
        intermediate = FakeResponse(b"redirect")
        result = handler.http_error_302(original, intermediate, 303, "See other", compat.CaseInsensitiveDict({"Location": "../../next?x=1"}))
        request, timeout = parent.calls[0]
        self.assertIs(result, final)
        self.assertEqual(request.full_url, "https://a.example/next?x=1")
        self.assertEqual(request.get_method(), "GET")
        self.assertIsNone(request.data)
        self.assertIsNone(request.get_header("Content-type"))
        self.assertTrue(intermediate.closed)

    def test_ios_uses_packaged_verified_certifi_roots(self):
        roots = types.SimpleNamespace(where=lambda: "/bundle/python/certifi/cacert.pem")
        marker = object()
        with patch.object(compat.sys, "platform", "ios"), patch.dict(sys.modules, {"certifi": roots}), \
                patch.object(compat.ssl, "create_default_context", return_value=marker) as context, \
                patch.object(compat._urlrequest, "build_opener", return_value="opener"):
            self.assertEqual(compat._make_opener(compat.CookieJar(), True), "opener")
            context.assert_called_once_with(cafile="/bundle/python/certifi/cacert.pem")
        roots = types.SimpleNamespace(where=lambda: (_ for _ in ()).throw(OSError("missing")))
        with patch.object(compat.sys, "platform", "ios"), patch.dict(sys.modules, {"certifi": roots}):
            with self.assertRaisesRegex(compat.SSLError, "trust store"):
                compat._make_opener(compat.CookieJar(), True)


if __name__ == "__main__":
    unittest.main()
