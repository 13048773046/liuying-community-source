#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""app-download-gateway：独立下载网关。

客户端只拿到 /community/dl/<ticket>，网关校验 ticket 后向主服务取内部 manifest，
再调用 app-resolver 取短时直链，按 Range 转发；不访问数据库、不暴露原始网盘地址。
"""
import os
import re
import json
import time
import hmac
import base64
import hashlib
import ipaddress
import socket
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError

PORT = int(os.environ.get("APP_DELIVERY_PORT", "8792"))
ALLOW_PRIVATE = os.environ.get("APP_ALLOW_PRIVATE", "0") == "1"
HOST = os.environ.get("APP_DELIVERY_HOST", "127.0.0.1")
MANIFEST_URL = os.environ.get(
    "APP_MANIFEST_URL", "http://127.0.0.1:8790/community/api/internal/app-download/manifest")
RESOLVER_URL = os.environ.get("APP_RESOLVER_URL", "http://127.0.0.1:8793/resolve")
INTERNAL_TOKEN = (os.environ.get("APP_INTERNAL_TOKEN") or "").strip()
_ticket_secret = (os.environ.get("APP_TICKET_SECRET") or "").strip()
if not INTERNAL_TOKEN or len(_ticket_secret) < 32:
    raise RuntimeError("APP_INTERNAL_TOKEN / APP_TICKET_SECRET 未配置或长度不足")
TICKET_SECRET = _ticket_secret.encode()
UA = "LiuyingAppDownload/1.0"
_cache = {}
_cache_lock = __import__("threading").Lock()
CACHE_TTL = 300


class DeliveryError(Exception):
    pass


def verify_ticket(ticket):
    try:
        data, sig = (ticket or "").split(".", 1)
        expect = hmac.new(TICKET_SECRET, data.encode("ascii"), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(expect, sig):
            return None
        payload = json.loads(base64.urlsafe_b64decode(data + "=" * (-len(data) % 4)).decode())
        if int(payload.get("exp") or 0) < int(time.time()):
            return None
        return payload if payload.get("v") and payload.get("a") else None
    except Exception:
        return None


def _valid_url(url):
    if ALLOW_PRIVATE:
        try:
            p = urllib.parse.urlparse(url)
            return p.scheme in ("http", "https") and bool(p.hostname) and not p.username and not p.password
        except Exception:
            return False
    try:
        p = urllib.parse.urlparse(url)
    except Exception:
        return False
    if p.scheme not in ("http", "https") or not p.hostname or p.username or p.password:
        return False
    try:
        for info in socket.getaddrinfo(p.hostname, None):
            a = ipaddress.ip_address(info[4][0])
            if a.is_private or a.is_loopback or a.is_link_local or a.is_reserved or a.is_multicast:
                return False
    except Exception:
        return False
    return True


class SafeRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not _valid_url(newurl):
            raise DeliveryError("upstream redirect blocked")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def _opener():
    return urllib.request.build_opener(urllib.request.ProxyHandler({}), SafeRedirect)


def _manifest(app_id, version_id):
    key = (app_id, version_id)
    now = time.time()
    with _cache_lock:
        hit = _cache.get(key)
        if hit and hit[0] > now:
            return hit[1]
    url = MANIFEST_URL + "?" + urllib.parse.urlencode({"appId": app_id, "versionId": version_id})
    req = urllib.request.Request(url, headers={"X-Internal-Token": INTERNAL_TOKEN})
    try:
        r = _opener().open(req, timeout=10)
        j = json.loads(r.read().decode("utf-8"))
    except Exception as e:
        raise DeliveryError("manifest unavailable: %s" % e)
    if not j.get("ok") or not j.get("manifest"):
        raise DeliveryError("manifest rejected")
    manifest = j["manifest"]
    with _cache_lock:
        _cache[key] = (now + CACHE_TTL, manifest)
    return manifest


def _safe_headers(headers):
    """Only forward the small allowlist resolver uses for netdisk hotlink protection."""
    if not isinstance(headers, dict):
        return {}
    allowed = {"referer", "user-agent", "cookie", "origin", "accept", "authorization"}
    out = {}
    for k, v in headers.items():
        key = str(k or "").strip().lower()
        if key not in allowed or not isinstance(v, str):
            continue
        value = v.strip()
        if not value or "\r" in value or "\n" in value:
            continue
        out[key] = value[:1024]
    return out


def _resolve(manifest):
    key = ("resolved", manifest.get("versionId"), manifest.get("downloadUrl"))
    now = time.time()
    with _cache_lock:
        hit = _cache.get(key)
        if hit and hit[0] > now:
            return hit[1]
    body = json.dumps({"url": manifest.get("downloadUrl"), "provider": manifest.get("provider") or "auto",
                       "shareCode": manifest.get("shareCode") or "",
                       "packageType": manifest.get("packageType") or "",
                       "fileName": manifest.get("fileName") or "",
                       "appName": manifest.get("appName") or ""}).encode()
    req = urllib.request.Request(RESOLVER_URL, data=body, method="POST",
                                 headers={"Content-Type": "application/json"})
    try:
        r = _opener().open(req, timeout=20)
        j = json.loads(r.read().decode("utf-8"))
    except Exception as e:
        raise DeliveryError("resolver unavailable: %s" % e)
    if not j.get("ok") or not j.get("directUrl"):
        raise DeliveryError(j.get("error") or "resolver rejected")
    resolved = {
        "directUrl": j["directUrl"], "fileName": manifest.get("fileName") or j.get("fileName") or "download.bin",
        "fileSize": int(j.get("fileSize") or manifest.get("fileSize") or 0),
        "contentType": j.get("contentType") or manifest.get("contentType") or "application/octet-stream",
        "supportsRange": bool(j.get("supportsRange") or manifest.get("supportsRange")),
        "headers": _safe_headers(j.get("headers")),
    }
    with _cache_lock:
        _cache[key] = (now + min(CACHE_TTL, max(60, int(300))), resolved)
    return resolved


def _range_header(value):
    if not value:
        return None
    m = re.match(r"^bytes=(\d*)-(\d*)$", value.strip(), re.I)
    if not m or (m.group(1) == "" and m.group(2) == ""):
        return "bad"
    return (int(m.group(1)) if m.group(1) else None,
            int(m.group(2)) if m.group(2) else None)


def _content_disposition(name):
    name = re.sub(r"[\\/:*?\"<>|\r\n]", "_", name or "download.bin")[:180]
    quoted = urllib.parse.quote(name)
    return 'attachment; filename="%s"; filename*=UTF-8\'\'%s' % (quoted, quoted)


def _send_headers(self, code, headers):
    self.send_response(code)
    for k, v in headers.items():
        if v:
            self.send_header(k, str(v))
    self.send_header("Access-Control-Allow-Origin", "*")
    self.send_header("Cache-Control", "private, no-store")
    self.end_headers()


def _proxy(self, ticket, method):
    payload = verify_ticket(ticket)
    if not payload:
        self._json(403, {"ok": False, "error": "下载链接已过期，请回到应用详情重新点击下载"})
        return
    try:
        manifest = _manifest(payload["a"], payload["v"])
        resolved = _resolve(manifest)
        if not _valid_url(resolved["directUrl"]):
            raise DeliveryError("direct url blocked")
        range_value = self.headers.get("Range")
        if range_value:
            parsed = _range_header(range_value)
            if parsed == "bad":
                _send_headers(self, 416, {"Content-Range": "bytes */*", "Content-Length": "0"})
                return
            start, end = parsed
            size = int(manifest.get("fileSize") or resolved.get("fileSize") or 0)
            if start is not None and size and start >= size:
                _send_headers(self, 416, {"Content-Range": "bytes */%d" % size, "Content-Length": "0"})
                return
            if start is None and (end is None or not size):
                _send_headers(self, 416, {"Content-Range": "bytes */%d" % size if size else "bytes */*",
                                          "Content-Length": "0"})
                return
        upstream_headers = {"User-Agent": UA, "Accept": "*/*"}
        upstream_headers.update(resolved.get("headers") or {})
        if range_value:
            upstream_headers["Range"] = range_value
        req = urllib.request.Request(resolved["directUrl"], headers=upstream_headers, method=method)
        try:
            upstream = _opener().open(req, timeout=20)
        except HTTPError as e:
            if e.code == 416:
                cr = e.headers.get("Content-Range", "")
                _send_headers(self, 416, {"Content-Range": cr, "Content-Length": "0"})
                return
            self._json(502, {"ok": False, "error": "源文件请求失败：%s" % e.code})
            return
        except Exception as e:
            self._json(502, {"ok": False, "error": "源文件请求失败：%s" % e})
            return
        code = getattr(upstream, "status", 200)
        h = upstream.headers
        size = int(h.get("Content-Length") or resolved.get("fileSize") or 0)
        out = {
            "Content-Type": h.get("Content-Type") or resolved.get("contentType"),
            "Accept-Ranges": "bytes" if (code == 206 or resolved.get("supportsRange")) else "",
            "ETag": h.get("ETag") or '"app-%s-%s"' % (payload["v"], size),
            "Content-Disposition": _content_disposition(resolved.get("fileName")),
        }
        if h.get("Content-Range"):
            out["Content-Range"] = h.get("Content-Range")
        if code == 206:
            out["Content-Length"] = str(size)
        elif range_value and code == 200:
            # 上游忽略 Range：如实返回 200 全量，不伪造 206
            out["Content-Length"] = str(size) if size else ""
        else:
            out["Content-Length"] = str(size) if size else ""
        _send_headers(self, code, out)
        if method == "HEAD":
            upstream.close()
            return
        try:
            while True:
                chunk = upstream.read(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
        except Exception:
            pass
        finally:
            upstream.close()
    except DeliveryError as e:
        self._json(502, {"ok": False, "error": str(e)})
    except Exception as e:
        self._json(502, {"ok": False, "error": "下载失败：%s" % e})


class Handler(BaseHTTPRequestHandler):
    server_version = "LiuyingAppDelivery/1.0"
    protocol_version = "HTTP/1.1"

    def _json(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(body)
        except Exception:
            pass

    def do_GET(self):
        p = urllib.parse.urlparse(self.path)
        if p.path == "/health":
            self._json(200, {"ok": True, "service": "app-delivery", "ts": time.time()})
            return
        m = re.match(r"^/(?:community/)?dl/([^/]+)$", p.path)
        if not m:
            self._json(404, {"ok": False, "error": "not found"})
            return
        _proxy(self, m.group(1), "GET")

    def do_HEAD(self):
        p = urllib.parse.urlparse(self.path)
        if p.path == "/health":
            self._json(200, {"ok": True, "service": "app-delivery"})
            return
        m = re.match(r"^/(?:community/)?dl/([^/]+)$", p.path)
        if not m:
            self._json(404, {"ok": False, "error": "not found"})
            return
        _proxy(self, m.group(1), "HEAD")

    def log_message(self, fmt, *args):
        pass


def main():
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    srv.daemon_threads = True
    print("app-delivery on %s:%d" % (HOST, PORT), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
