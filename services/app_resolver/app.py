#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""app-resolver：独立网盘/官网解析服务，不访问数据库。

- 只做短时直链解析，不缓存、不镜像字节；
- 官方/GitHub 直接支持，蓝奏/123 等公开分享做实验性适配；
- 登录型网盘不匿名绕过，必须配置 APP_NFD_BASE_URL 或官方授权适配器。
"""
import os
import re
import sys
import json
import time
import socket
import ipaddress
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError

PORT = int(os.environ.get("APP_RESOLVER_PORT", "8793"))
ALLOW_PRIVATE = os.environ.get("APP_ALLOW_PRIVATE", "0") == "1"
HOST = os.environ.get("APP_RESOLVER_HOST", "127.0.0.1")
UA = "Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36 LiuyingAppMarket/1.0"
NFD_BASE = (os.environ.get("APP_NFD_BASE_URL") or "").rstrip("/")
NFD_PATH = os.environ.get("APP_NFD_PARSE_PATH", "/api/parse")
NFD_TOKEN = os.environ.get("APP_NFD_TOKEN", "")
LOGIN_PROVIDERS = {"baidu", "quark", "uc", "aliyun", "xunlei", "115", "guangya", "tianyi"}
PUBLIC_PROVIDERS = {"official", "github", "lanzou", "pan123", "cow", "feijipan", "ec", "fc", "pcx", "pgd", "pdp"}
HOSTS = [
    ("lanzou", ("lanzou", "lanzoux", "lanzouy")),
    ("pan123", ("123pan", "123684", "123865")),
    ("cow", ("cowtransfer",)),
    ("feijipan", ("feijipan",)),
    ("ec", ("yun.139", "139.com")),
    ("baidu", ("pan.baidu", "yun.baidu")),
    ("quark", ("pan.quark", "quark")),
    ("uc", ("drive.uc", "uc.cn")),
    ("aliyun", ("aliyundrive", "alipan", "aliyun")),
    ("xunlei", ("xunlei",)),
    ("115", ("115",)),
    ("guangya", ("guangya",)),
    ("tianyi", ("cloud.189", "189.cn")),
    ("github", ("github.com", "www.github.com")),
]

class ResolveError(Exception):
    def __init__(self, msg, code="RESOLVE_FAILED", login_required=False):
        super().__init__(msg)
        self.code = code
        self.login_required = login_required


def _ip_ok(host):
    if ALLOW_PRIVATE:
        return
    try:
        infos = socket.getaddrinfo(host, None)
    except Exception:
        raise ResolveError("域名无法解析", "BAD_HOST")
    for info in infos:
        ip = info[4][0]
        try:
            a = ipaddress.ip_address(ip)
            if a.is_private or a.is_loopback or a.is_link_local or a.is_reserved or a.is_multicast:
                raise ResolveError("目标地址不允许访问", "PRIVATE_ADDRESS")
        except ValueError:
            continue


def valid_url(url):
    if not url:
        raise ResolveError("缺少下载地址", "BAD_URL")
    try:
        p = urllib.parse.urlparse(url)
    except Exception:
        raise ResolveError("下载地址格式不正确", "BAD_URL")
    if p.scheme not in ("http", "https") or not p.hostname:
        raise ResolveError("只支持 http/https 下载地址", "BAD_URL")
    if p.username or p.password:
        raise ResolveError("下载地址不能包含账号密码", "BAD_URL")
    _ip_ok(p.hostname)


def detect_provider(url):
    host = (urllib.parse.urlparse(url).hostname or "").lower()
    for name, needles in HOSTS:
        if any(n in host for n in needles):
            return name
    return "official"


class SafeRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        valid_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def _opener():
    return urllib.request.build_opener(urllib.request.ProxyHandler({}), SafeRedirect)


def _request(url, method="GET", headers=None, data=None, timeout=10):
    valid_url(url)
    h = {"User-Agent": UA, "Accept": "*/*", "Accept-Language": "zh-CN,zh"}
    if headers:
        h.update(headers)
    req = urllib.request.Request(url, data=data, headers=h, method=method)
    return _opener().open(req, timeout=timeout)


def _disposition_name(headers, url):
    cd = headers.get("Content-Disposition", "") or ""
    m = re.search(r"filename\*?=\s*['\"]?(?:UTF-8''|utf-8'')?([^'\";]+)", cd, re.I)
    if m:
        name = urllib.parse.unquote(m.group(1).strip().strip('"'))
        name = re.sub(r"[\\/:*?\"<>|\r\n]", "_", name).strip()
        if name:
            return name[:180]
    path = urllib.parse.urlparse(url).path.rstrip("/")
    name = os.path.basename(path) or "download.bin"
    return re.sub(r"[\\/:*?\"<>|\r\n]", "_", name)[:180]


def _meta(url):
    """HEAD 优先，失败用 Range GET 0-0；返回探测结果。"""
    try:
        r = _request(url, "HEAD")
        h = r.headers
        size = int(h.get("Content-Length") or 0)
        ctype = h.get("Content-Type") or "application/octet-stream"
        ranges = "bytes" if h.get("Accept-Ranges", "").lower() == "bytes" else ""
        return {"finalUrl": r.geturl(), "fileName": _disposition_name(h, r.geturl()),
                "fileSize": size, "contentType": ctype, "supportsRange": bool(ranges)}
    except Exception:
        pass
    try:
        r = _request(url, "GET", headers={"Range": "bytes=0-0"})
        code = getattr(r, "status", 200)
        h = r.headers
        size = 0
        m = re.search(r"/(\d+)$", h.get("Content-Range", ""))
        if m:
            size = int(m.group(1))
        else:
            size = int(h.get("Content-Length") or 0)
        ctype = h.get("Content-Type") or "application/octet-stream"
        ranges = code == 206 or h.get("Accept-Ranges", "").lower() == "bytes"
        r.close()
        return {"finalUrl": r.geturl(), "fileName": _disposition_name(h, r.geturl()),
                "fileSize": size, "contentType": ctype, "supportsRange": bool(ranges)}
    except Exception as e:
        raise ResolveError("目标文件不可访问：%s" % e, "UPSTREAM_FAILED")


def _page(url):
    r = _request(url, "GET")
    data = r.read(2 * 1024 * 1024)
    r.close()
    return data.decode("utf-8", "ignore")


def _official_direct(url):
    """官网/GitHub 直链：若 HEAD 是 HTML 落地页，再从页面提取明确资源链接。"""
    try:
        meta = _meta(url)
        ct = (meta.get("contentType") or "").lower()
        if "text/html" in ct or "application/xhtml" in ct:
            direct = _direct_from_html(url, _page(url))
            if direct:
                return direct
            raise ResolveError("官网链接是网页而不是直接安装包，请填写安装包直链")
        return url
    except ResolveError:
        raise
    except Exception:
        return url


def _direct_from_html(url, html):
    # GitHub release 页面 / 普通官网落地页：只取明确的下载资源链接
    candidates = re.findall(r'href=["\']([^"\']+)["\']', html, re.I)
    good = []
    for href in candidates:
        h = urllib.parse.urljoin(url, href)
        if h.startswith("http") and re.search(r"\.(apk|ipa|hap|app|exe|msi|zip|dmg|pkg)(\?|$)", h, re.I):
            good.append(h)
    if not good:
        # GitHub release 资产链接
        good = [urllib.parse.urljoin(url, h) for h in candidates
                if "/releases/download/" in h]
    return good[0] if good else ""


def resolve_github(url, share_code=""):
    p = urllib.parse.urlparse(url)
    if "/releases/download/" in p.path or "/raw/" in p.path or p.path.lower().endswith(
            (".apk", ".ipa", ".hap", ".exe", ".msi", ".zip", ".dmg", ".pkg")):
        return url
    html = _page(url)
    direct = _direct_from_html(url, html)
    if not direct:
        raise ResolveError("GitHub 页面没有找到可直接下载的 Release 资产")
    return direct


def _lanzou_js_params(html):
    """从蓝奏云分享页/iframe 中提取 ajaxm 所需参数。"""
    scripts = re.findall(r"<script[^>]*>([\s\S]*?)</script>", html, re.I)
    text = "\n".join(scripts) if scripts else html
    sign = re.search(r"sign\s*[:=]\s*['\"]([^'\"]+)['\"]", text)
    ajax = re.search(r"(?:ajaxdata|websignkey)\s*=\s*['\"]([^'\"]+)['\"]", text)
    file_id = re.search(r"(?:ajaxm\.php\?file=|file\s*=\s*)(\d+)", text)
    kd = re.search(r"(?:kdns|kd)\s*[:=]\s*(\d+)", text)
    return {
        "sign": sign.group(1) if sign else "",
        "websignkey": ajax.group(1) if ajax else "",
        "fileId": file_id.group(1) if file_id else "",
        "kd": kd.group(1) if kd else "1",
    }


def resolve_lanzou(url, share_code=""):
    """蓝奏云公开分享：主页面 -> iframe -> ajaxm.php。"""
    html = _page(url)
    iframe = re.search(r'src=["\']((?:https?:)?\/\/.*?\/fn\?[^"\']+|\/fn\?[^"\']+)', html, re.I)
    target_html, target_url = html, url
    if iframe:
        target_url = urllib.parse.urljoin(url, iframe.group(1))
        target_html = _page(target_url)
    params = _lanzou_js_params(target_html)
    if not params["sign"]:
        raise ResolveError("蓝奏云分享页未找到下载签名，可能已失效或页面改版")
    if params["fileId"]:
        ajax_url = urllib.parse.urljoin(url, "/ajaxm.php?file=%s" % params["fileId"])
    else:
        ajax_url = urllib.parse.urljoin(url, "/ajaxm.php")
    data = {
        "action": "downprocess",
        "sign": params["sign"],
        "websignkey": params["websignkey"],
        "signs": params["websignkey"],
        "websign": "",
        "kd": params["kd"],
    }
    if share_code:
        data["p"] = share_code
    else:
        data["ves"] = "1"
    try:
        r = _request(ajax_url, "POST", headers={
            "Referer": target_url, "Origin": urllib.parse.urlsplit(url).scheme + "://" + urllib.parse.urlsplit(url).netloc,
            "Content-Type": "application/x-www-form-urlencoded",
        }, data=urllib.parse.urlencode(data).encode())
        j = json.loads(r.read().decode("utf-8", "ignore"))
    except Exception as e:
        raise ResolveError("蓝奏云解析请求失败：%s" % e)
    if j.get("zt") not in (1, "1"):
        raise ResolveError(j.get("inf") or "蓝奏云解析被拒绝，可能需要提取码或分享已失效")
    dom = str(j.get("dom") or "").rstrip("/")
    path = str(j.get("url") or "").lstrip("/")
    if not dom or not path:
        raise ResolveError("蓝奏云返回缺少直链字段")
    return dom + "/file/" + path

def resolve_pan123(url, share_code=""):
    # 123 云盘公开分享页：尝试从页面/接口提取直链；失败时明确报错，不伪造
    html = _page(url)
    m = re.search(r"(https?://[^\"']+\.(?:apk|ipa|hap|exe|msi|zip)[^\"']*)", html, re.I)
    if m:
        return m.group(1).replace("&amp;", "&")
    raise ResolveError("123 云盘公开页未找到直链，需配置专用 123 适配器")


def resolve_nfd(url, share_code=""):
    if not NFD_BASE:
        raise ResolveError("登录型网盘需要配置 APP_NFD_BASE_URL 授权解析服务",
                           "PROVIDER_NOT_CONFIGURED", login_required=True)
    body = json.dumps({"url": url, "pwd": share_code or ""}).encode()
    req = urllib.request.Request(NFD_BASE + NFD_PATH, data=body, method="POST",
                                 headers={"Content-Type": "application/json",
                                          "X-Internal-Token": NFD_TOKEN})
    try:
        r = urllib.request.urlopen(req, timeout=15)
        j = json.loads(r.read().decode("utf-8", "ignore"))
    except Exception as e:
        raise ResolveError("外部解析服务失败：%s" % e, "RESOLVER_UNAVAILABLE")
    direct = j.get("directUrl") or j.get("downloadUrl") or j.get("url") or ""
    if isinstance(direct, list):
        direct = direct[0] if direct else ""
    if not direct:
        raise ResolveError("外部解析服务未返回直链")
    valid_url(direct)
    return direct


def resolve(url, provider="auto", share_code=""):
    provider = (provider or "auto").strip().lower()
    if provider == "auto":
        provider = detect_provider(url)
    if provider == "github":
        direct = resolve_github(url, share_code)
    elif provider == "lanzou":
        direct = resolve_lanzou(url, share_code)
    elif provider == "pan123":
        direct = resolve_pan123(url, share_code)
    elif provider in LOGIN_PROVIDERS:
        direct = resolve_nfd(url, share_code)
    elif provider == "official":
        direct = _official_direct(url)
    elif provider in ("cow", "feijipan", "ec", "fc", "pcx", "pgd", "pdp"):
        direct = _official_direct(url)
    else:
        direct = url
    meta = _meta(direct)
    return {
        "provider": provider,
        "directUrl": direct,
        "finalUrl": meta["finalUrl"],
        "fileName": meta["fileName"],
        "fileSize": meta["fileSize"],
        "contentType": meta["contentType"],
        "supportsRange": meta["supportsRange"],
        "expiresAt": int(time.time()) + 600,
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "LiuyingAppResolver/1.0"
    protocol_version = "HTTP/1.1"

    def _send(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(body)
        except Exception:
            pass

    def _body(self):
        try:
            n = int(self.headers.get("Content-Length", 0))
            if n <= 0 or n > 1024 * 1024:
                return {}
            return json.loads(self.rfile.read(n).decode("utf-8") or "{}")
        except Exception:
            return {}

    def do_GET(self):
        p = urllib.parse.urlparse(self.path)
        if p.path == "/health":
            self._send(200, {"ok": True, "service": "app-resolver", "ts": time.time()})
            return
        if p.path == "/providers":
            self._send(200, {"ok": True, "providers": [
                {"id": "official", "name": "官网直链", "supported": True},
                {"id": "github", "name": "GitHub Releases", "supported": True},
                {"id": "lanzou", "name": "蓝奏云", "supported": True, "experimental": True},
                {"id": "pan123", "name": "123 云盘", "supported": True, "experimental": True},
                {"id": "cow", "name": "奶牛快传", "supported": True, "experimental": True},
                {"id": "feijipan", "name": "小飞机", "supported": True, "experimental": True},
                {"id": "baidu", "name": "百度网盘", "supported": bool(NFD_BASE), "loginRequired": True},
                {"id": "quark", "name": "夸克网盘", "supported": bool(NFD_BASE), "loginRequired": True},
                {"id": "aliyun", "name": "阿里云盘", "supported": bool(NFD_BASE), "loginRequired": True},
                {"id": "115", "name": "115", "supported": bool(NFD_BASE), "loginRequired": True},
                {"id": "tianyi", "name": "天翼云盘", "supported": bool(NFD_BASE), "loginRequired": True},
            ]})
            return
        self._send(404, {"ok": False, "error": "not found"})

    def do_POST(self):
        p = urllib.parse.urlparse(self.path)
        if p.path not in ("/resolve", "/api/parse"):
            self._send(404, {"ok": False, "error": "not found"})
            return
        body = self._body()
        try:
            out = resolve(str(body.get("url") or ""), str(body.get("provider") or "auto"),
                          str(body.get("shareCode") or body.get("pwd") or ""))
            self._send(200, {"ok": True, **out})
        except ResolveError as e:
            self._send(403 if e.login_required else 502, {
                "ok": False, "error": str(e), "code": e.code,
                "loginRequired": e.login_required,
            })
        except Exception as e:
            self._send(502, {"ok": False, "error": str(e), "code": "RESOLVE_FAILED"})

    def log_message(self, fmt, *args):
        pass


def main():
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    srv.daemon_threads = True
    print("app-resolver on %s:%d nfd=%s" % (HOST, PORT, bool(NFD_BASE)), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
