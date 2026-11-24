# -*- coding: utf-8 -*-
"""流萤社区 · 轻互动域。

覆盖：
- 今日状态：GET/PUT /status
- 戳一戳/抱抱/加油：POST /poke/<uid>、GET /pokes/unread
- 一起听/一起看：/together/room...

写接口统一登录、限流、敏感词与归属校验；房间只允许发起人与受邀人访问。
"""
from __future__ import annotations

import json
import time
import urllib.parse
import uuid

from common import (
    rate_limit,
    resolve_token,
    row_dict,
    user_mini,
    check_sensitive,
)

POKE_KINDS = ("poke", "hug", "cheer")
POKE_LABEL = {"poke": "戳了戳你", "hug": "抱了抱你", "cheer": "给你加油"}
ROOM_KINDS = ("listen", "watch")
ROOM_REACTIONS = ("same", "laugh", "hug", "learned", "waiting")
MAX_STATUS_TEXT = 12
MAX_POKE_PER_DAY = 3
MAX_ROOM_QUEUE = 30


def _uid(c, handler):
    return resolve_token(c, handler.headers.get("Authorization", ""))


def _body(handler):
    return handler._json_body() or {}


def _conv_id(a, b):
    a, b = str(a), str(b)
    return "%s_%s" % (min(a, b), max(a, b))


def _mutual_follow(c, a, b):
    if not a or not b or str(a) == str(b):
        return False
    return bool(
        c.execute("SELECT 1 FROM follows WHERE follower_id=? AND following_id=?",
                  (a, b)).fetchone()
        and c.execute("SELECT 1 FROM follows WHERE follower_id=? AND following_id=?",
                      (b, a)).fetchone()
    )


def _daily_start():
    lt = time.localtime()
    return time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 0, 0, 0, 0, 0, -1))


def _status_payload(c, target, viewer):
    row = c.execute("SELECT * FROM community_user_status WHERE user_id=?",
                    (target,)).fetchone()
    if not row:
        return None
    d = row_dict(row)
    updated = d.get("updated") or 0
    # 「今日状态」只在设置当天有效，跨天自动从读接口消失，避免旧心情误导访客。
    try:
        today = time.localtime()
        start = time.mktime((today.tm_year, today.tm_mon, today.tm_mday,
                             0, 0, 0, 0, 0, -1))
        if float(updated) < start:
            return None
    except Exception:
        pass
    return {
        "mood": (d.get("mood") or "")[:8],
        "text": (d.get("text") or "")[:MAX_STATUS_TEXT],
        "updated": updated,
    }


def _status_visible(c, target, viewer):
    if viewer and str(viewer) == str(target):
        return True
    prefs = c.execute("SELECT profile_visible FROM community_user_prefs WHERE user_id=?",
                      (target,)).fetchone()
    if prefs and prefs[0] == 1:
        if not viewer:
            return False
        return bool(c.execute(
            "SELECT 1 FROM follows WHERE follower_id=? AND following_id=?",
            (viewer, target)).fetchone())
    return True


def _clean_status_text(raw):
    text = str(raw or "").replace("\r", " ").replace("\n", " ").strip()
    text = " ".join(text.split())
    return text[:MAX_STATUS_TEXT]


# ---------------- 私信系统气泡 ----------------
def _store_dm(c, sender, receiver, content, msg_type="poke", preview=""):
    """写一条私信并更新会话；返回 (id, created, unread)。与 dm.py 的落库口径一致。"""
    mid = uuid.uuid4().hex
    created = time.time()
    conv = _conv_id(sender, receiver)
    a, b = str(sender), str(receiver)
    ua, ub = (a, b) if a <= b else (b, a)
    c.execute(
        "INSERT INTO community_dm_messages"
        "(id,conv_id,sender_id,receiver_id,content,created,is_read,msg_type)"
        " VALUES(?,?,?,?,?,?,0,?)",
        (mid, conv, sender, receiver, content, created, msg_type))
    text = (preview or content or "")[:120]
    if str(sender) == ua:
        c.execute(
            "INSERT INTO community_conversations"
            "(id,user_a,user_b,last_msg,last_type,last_time,unread_a,unread_b,created)"
            " VALUES(?,?,?,?,?,?,0,1,?)"
            " ON CONFLICT(id) DO UPDATE SET last_msg=excluded.last_msg,"
            " last_type=excluded.last_type, last_time=excluded.last_time,"
            " unread_b=unread_b+1",
            (conv, ua, ub, text, msg_type, created, created))
    else:
        c.execute(
            "INSERT INTO community_conversations"
            "(id,user_a,user_b,last_msg,last_type,last_time,unread_a,unread_b,created)"
            " VALUES(?,?,?,?,?,?,1,0,?)"
            " ON CONFLICT(id) DO UPDATE SET last_msg=excluded.last_msg,"
            " last_type=excluded.last_type, last_time=excluded.last_time,"
            " unread_a=unread_a+1",
            (conv, ua, ub, text, msg_type, created, created))
    unread = c.execute(
        "SELECT COUNT(*) FROM community_dm_messages WHERE receiver_id=? AND is_read=0",
        (receiver,)).fetchone()[0]
    return mid, created, unread


def _push_dm(c, mid, conv, sender, receiver, content, msg_type, created, unread):
    try:
        from handlers import ws as H_WS
        info = c.execute("SELECT id,name,avatar FROM users WHERE id=?", (sender,)).fetchone()
        H_WS.ws_push(receiver, {
            "kind": "dm",
            "dm": {
                "id": mid, "convId": conv,
                "from": {
                    "id": sender,
                    "name": (info[1] if info else "") or "",
                    "avatar": (info[2] if info else "") or "",
                },
                "content": content,
                "msgType": msg_type,
                "created": created,
                "preview": POKE_LABEL.get((json.loads(content or "{}") or {}).get("action"), "互动"),
                "convUnread": 1,
            },
            "unread": unread,
        })
    except Exception:
        pass


# ---------------- 状态 ----------------
def _handle_status(self, c, u, api, method):
    if api != "/status":
        return False
    if method == "GET":
        q = urllib.parse.parse_qs(u.query)
        target = (q.get("uid") or [""])[0].strip()
        viewer = _uid(c, self)
        if not target:
            target = viewer
        if not target:
            self._err(401, "未登录")
            return True
        if not c.execute("SELECT 1 FROM users WHERE id=?", (target,)).fetchone():
            self._err(404, "用户不存在")
            return True
        visible = _status_visible(c, target, viewer)
        status = _status_payload(c, target, viewer) if visible else None
        c.commit()
        self._ok({"status": status, "visible": visible})
        return True

    if method == "PUT":
        uid = _uid(c, self)
        if not uid:
            self._err(401, "未登录")
            return True
        if not rate_limit(self, "status"):
            self._err(429, "设置太频繁，请稍后再试")
            return True
        body = _body(self)
        mood = " ".join(str(body.get("mood") or "").replace("\r", " ").replace("\n", " ").split())[:8]
        raw_text = " ".join(str(body.get("text") or "").replace("\r", " ").replace("\n", " ").split())
        if len(raw_text) > MAX_STATUS_TEXT:
            self._err(400, "今日状态最多 %d 字" % MAX_STATUS_TEXT)
            return True
        text = _clean_status_text(raw_text)
        if mood or text:
            hits = check_sensitive(c, mood + " " + text)
            if hits:
                self._err(400, "状态包含不合适的内容")
                return True
        now = time.time()
        # 只选一个流萤状态、不写文字也是有效状态；两者都空才视为清除。
        if not text and not mood:
            c.execute("DELETE FROM community_user_status WHERE user_id=?", (uid,))
            c.commit()
            self._ok({"status": None})
            return True
        c.execute(
            "INSERT INTO community_user_status(user_id,mood,text,updated) VALUES(?,?,?,?)"
            " ON CONFLICT(user_id) DO UPDATE SET mood=excluded.mood,text=excluded.text,"
            "updated=excluded.updated",
            (uid, mood, text, now))
        c.commit()
        self._ok({"status": {"mood": mood, "text": text, "updated": now}})
        return True
    return False


# ---------------- 戳一戳 ----------------
def _handle_poke(self, c, u, api, method):
    m = __import__("re").match(r"^/poke/([\w\-]+)$", api)
    if not m or method != "POST":
        return False
    uid = _uid(c, self)
    if not uid:
        self._err(401, "未登录")
        return True
    target = m.group(1)
    if str(target) == str(uid):
        self._err(400, "不能戳自己")
        return True
    if not rate_limit(self, "poke"):
        self._err(429, "戳得太频繁，先歇一会儿")
        return True
    body = _body(self)
    kind = str(body.get("kind") or "poke").strip().lower()
    if kind not in POKE_KINDS:
        self._err(400, "未知互动类型")
        return True
    if not _mutual_follow(c, uid, target):
        self._err(403, "只有互相关注的好友才能戳一戳")
        return True
    since = _daily_start()
    count = c.execute(
        "SELECT COUNT(*) FROM community_pokes"
        " WHERE from_uid=? AND to_uid=? AND created>=?",
        (uid, target, since)).fetchone()[0]
    if count >= MAX_POKE_PER_DAY:
        self._err(429, "今天已经戳了 3 次，先留点新鲜感")
        return True
    pid = uuid.uuid4().hex
    now = time.time()
    c.execute(
        "INSERT INTO community_pokes(id,from_uid,to_uid,kind,created,is_read)"
        " VALUES(?,?,?,?,?,0)",
        (pid, uid, target, kind, now))
    pinfo = c.execute("SELECT name,avatar FROM users WHERE id=?", (uid,)).fetchone()
    payload = json.dumps({
        "kind": "poke",
        "action": kind,
        "fromId": uid,
        "fromName": (pinfo[0] if pinfo else "") or "",
        "fromAvatar": (pinfo[1] if pinfo else "") or "",
    }, ensure_ascii=False, separators=(",", ":"))
    mid, created, unread = _store_dm(
        c, uid, target, payload, "poke",
        preview="[%s] %s" % (POKE_LABEL[kind], (pinfo[0] if pinfo else "") or ""))
    c.commit()
    _push_dm(c, mid, _conv_id(uid, target), uid, target, payload, "poke", created, unread)
    try:
        from handlers import ws as H_WS
        H_WS.ws_push(target, {
            "kind": "poke",
            "poke": {
                "id": pid, "fromUid": uid,
                "fromName": (pinfo[0] if pinfo else "") or "",
                "kind": kind, "created": now,
            },
            "unread": unread,
        })
    except Exception:
        pass
    self._ok({"poke": {"id": pid, "fromUid": uid, "kind": kind, "created": now},
              "message": {"id": mid, "created": created},
              "remaining": MAX_POKE_PER_DAY - count - 1})
    return True


def _handle_pokes_unread(self, c, u, api, method):
    if api != "/pokes/unread" or method != "GET":
        return False
    uid = _uid(c, self)
    if not uid:
        self._err(401, "未登录")
        return True
    q = urllib.parse.parse_qs(u.query)
    from_uid = (q.get("from") or [""])[0].strip()
    if from_uid:
        rows = c.execute(
            "SELECT * FROM community_pokes WHERE to_uid=? AND from_uid=?"
            " AND is_read=0 ORDER BY created ASC LIMIT 20",
            (uid, from_uid)).fetchall()
    else:
        rows = c.execute(
            "SELECT * FROM community_pokes WHERE to_uid=? AND is_read=0"
            " ORDER BY created ASC LIMIT 20", (uid,)).fetchall()
    out = []
    for r in rows:
        d = row_dict(r)
        info = c.execute("SELECT name,avatar FROM users WHERE id=?",
                         (d["from_uid"],)).fetchone()
        out.append({
            "id": d["id"], "fromUid": d["from_uid"],
            "fromName": (info[0] if info else "") or "",
            "fromAvatar": (info[1] if info else "") or "",
            "kind": d["kind"] or "poke", "created": d["created"] or 0,
        })
    if from_uid:
        c.execute(
            "UPDATE community_pokes SET is_read=1 WHERE to_uid=? AND from_uid=?"
            " AND is_read=0", (uid, from_uid))
    else:
        c.execute(
            "UPDATE community_pokes SET is_read=1 WHERE to_uid=? AND is_read=0",
            (uid,))
    c.commit()
    self._ok({"list": out})
    return True


# ---------------- 一起听 / 一起看 ----------------
def _valid_media_url(raw):
    s = str(raw or "").strip()
    if len(s) > 2000:
        return ""
    p = urllib.parse.urlparse(s)
    if p.scheme in ("http", "https") and p.netloc:
        return s

    if s.startswith("/community/api/media/"):
        return s
    return ""


def _clean_room_queue(raw):
    """清洗客户端传入的队列；只保留可播放 URL，最多 30 条。"""
    if not isinstance(raw, list):
        return []
    out = []
    for item in raw[:MAX_ROOM_QUEUE]:
        if not isinstance(item, dict):
            continue
        url = _valid_media_url(item.get("url") or item.get("mediaUrl"))
        if not url:
            continue
        out.append({
            "url": url,
            "title": str(item.get("title") or item.get("name") or "").strip()[:80],
            "cover": str(item.get("cover") or "").strip()[:500],
            "mediaId": str(item.get("mediaId") or item.get("trackId") or "").strip()[:120],
        })
    return out


def _queue_for_row(d):
    """读取房间队列；老房间没有 queue_json 时退化成“当前这一条”。"""
    raw = d.get("queue_json") or "[]"
    try:
        queue = json.loads(raw) if isinstance(raw, str) else raw
    except Exception:
        queue = []
    if not isinstance(queue, list):
        queue = []
    clean = _clean_room_queue(queue)
    if not clean:
        clean = [{
            "url": _valid_media_url(d.get("media_url")),
            "title": (d.get("media_title") or "").strip()[:80],
            "cover": (d.get("media_cover") or "").strip()[:500],
            "mediaId": (d.get("media_id") or "").strip()[:120],
        }]
        clean = [x for x in clean if x["url"]]
    return clean


def _room_position_ms(d):
    pos = max(0, int(d.get("position_ms") or 0))
    if int(d.get("playing") or 0):
        pos += max(0, int((time.time() - float(d.get("updated") or time.time())) * 1000))
    return pos


def _room_payload(c, row, viewer=None):
    d = row_dict(row)
    host = user_mini(c, d["host_uid"], viewer)
    guest = user_mini(c, d["guest_uid"], viewer)
    queue = _queue_for_row(d)
    index = int(d.get("media_index") or 0)
    if index < 0 or index >= len(queue):
        index = 0
    return {
        "id": d["id"], "kind": d["kind"] or "listen",
        "hostUid": d["host_uid"], "guestUid": d["guest_uid"],
        "host": host, "guest": guest,
        "mediaId": d.get("media_id") or "",
        "mediaUrl": d.get("media_url") or "",
        "title": d.get("media_title") or "",
        "cover": d.get("media_cover") or "",
        "queue": queue,
        "queueIndex": index,
        "queueLength": len(queue),
        "positionMs": _room_position_ms(d),
        "playing": bool(d.get("playing")),
        "status": d.get("status") or "waiting",
        "created": d.get("created") or 0,
        "updated": d.get("updated") or 0,
        "serverNow": int(time.time() * 1000),
    }


def _room_row(c, room_id):
    return c.execute("SELECT * FROM community_together_rooms WHERE id=?",
                     (room_id,)).fetchone()


def _room_member(d, uid):
    return str(uid) in (str(d["host_uid"]), str(d["guest_uid"]))


def _push_room(c, room, kind="room_state", extra=None):
    payload = {"kind": kind, "room": _room_payload(c, room)}
    if extra:
        payload.update(extra)
    for uid in {str(room["host_uid"]), str(room["guest_uid"])}:
        try:
            from handlers import ws as H_WS
            H_WS.ws_push(uid, payload)
        except Exception:
            pass


def _handle_together(self, c, u, api, method):
    if api == "/together/room" and method == "POST":
        uid = _uid(c, self)
        if not uid:
            self._err(401, "未登录")
            return True
        if not rate_limit(self, "together"):
            self._err(429, "创建太频繁，请稍后再试")
            return True
        body = _body(self)
        peer = str(body.get("peer") or "").strip()
        kind = str(body.get("kind") or "").strip().lower()
        media_url = _valid_media_url(body.get("mediaUrl"))
        title = str(body.get("title") or "").strip()[:80]
        cover = str(body.get("cover") or "").strip()[:500]
        media_id = str(body.get("mediaId") or "").strip()[:120]
        if not peer or not _mutual_follow(c, uid, peer):
            self._err(403, "只能邀请互相关注的好友")
            return True
        if kind not in ROOM_KINDS:
            self._err(400, "房间类型不正确")
            return True
        if not media_url:
            self._err(400, "请选择一个可播放的内容")
            return True
        if not title:
            title = "一起听" if kind == "listen" else "一起看"
        queue = _clean_room_queue(body.get("queue"))
        try:
            queue_index = int(body.get("queueIndex") or 0)
        except (TypeError, ValueError):
            queue_index = 0
        if queue:
            queue_index = max(0, min(queue_index, len(queue) - 1))
            selected = queue[queue_index]
            media_url = selected["url"]
            title = selected["title"] or title
            cover = selected["cover"] or cover
            media_id = selected["mediaId"] or media_id
        else:
            queue = [{
                "url": media_url, "title": title,
                "cover": cover, "mediaId": media_id,
            }]
            queue_index = 0
        now = time.time()
        # 同一对好友只保留一个进行中的房间，避免旧邀请把新房间顶掉。
        c.execute(
            "UPDATE community_together_rooms SET status='ended', updated=?"
            " WHERE status IN ('waiting','active') AND"
            " ((host_uid=? AND guest_uid=?) OR (host_uid=? AND guest_uid=?))",
            (now, uid, peer, peer, uid))
        rid = uuid.uuid4().hex
        c.execute(
            "INSERT INTO community_together_rooms"
            "(id,kind,host_uid,guest_uid,media_id,media_url,media_title,media_cover,"
            "queue_json,media_index,position_ms,playing,status,created,updated)"
            " VALUES(?,?,?,?,?,?,?,?,?,?,0,0,'waiting',?,?)",
            (rid, kind, uid, peer, media_id, media_url, title, cover,
             json.dumps(queue, ensure_ascii=False, separators=(",", ":")),
             queue_index, now, now))
        content = json.dumps({
            "kind": "together", "roomId": rid, "roomKind": kind,
            "title": title, "cover": cover, "fromName": user_mini(c, uid, peer).get("name", ""),
        }, ensure_ascii=False, separators=(",", ":"))
        mid, created, unread = _store_dm(
            c, uid, peer, content, "card",
            preview="[%s] %s" % ("一起听" if kind == "listen" else "一起看", title))
        c.commit()
        room = _room_row(c, rid)
        _push_dm(c, mid, _conv_id(uid, peer), uid, peer, content, "card", created, unread)
        _push_room(c, room, "together_invite")
        self._ok({"room": _room_payload(c, room),
                  "message": {"id": mid, "created": created}})
        return True

    m = __import__("re").match(r"^/together/room/([\w\-]+)(?:/(join|sync|leave|reaction))?$", api)
    if not m:
        return False
    rid, action = m.group(1), m.group(2)
    row = _room_row(c, rid)
    if not row:
        self._err(404, "房间不存在")
        return True
    d = row_dict(row)
    uid = _uid(c, self)
    if not uid:
        self._err(401, "未登录")
        return True
    if not _room_member(d, uid):
        self._err(403, "你不在这个房间里")
        return True
    if action is None and method == "GET":
        self._ok({"room": _room_payload(c, row, uid)})
        return True
    if action == "join" and method == "POST":
        if str(uid) != str(d["guest_uid"]):
            self._err(403, "只有受邀人可以加入")
            return True
        if d.get("status") == "ended":
            self._err(409, "房间已结束")
            return True
        c.execute("UPDATE community_together_rooms SET status='active', updated=?"
                  " WHERE id=?", (time.time(), rid))
        c.commit()
        fresh = _room_row(c, rid)
        _push_room(c, fresh)
        self._ok({"room": _room_payload(c, fresh, uid)})
        return True
    if action == "sync" and method == "POST":
        # 两个人都能控制播放/进度/切歌；服务端只认房间成员，状态统一以这里为准。
        if d.get("status") == "ended":
            self._err(409, "房间已结束")
            return True
        if not rate_limit(self, "together"):
            self._err(429, "操作太频繁")
            return True
        body = _body(self)
        direction = str(body.get("direction") or "").strip().lower()
        queue = _queue_for_row(d)
        if direction in ("next", "prev"):
            if len(queue) <= 1:
                self._err(400, "列表里只有这一个内容")
                return True
            cur = int(d.get("media_index") or 0)
            nxt = (cur + 1) % len(queue) if direction == "next" else (cur - 1) % len(queue)
            item = queue[nxt]
            playing = 1 if d.get("playing") else 0
            now = time.time()
            c.execute(
                "UPDATE community_together_rooms SET media_id=?,media_url=?,"
                "media_title=?,media_cover=?,queue_json=?,media_index=?,"
                "position_ms=0,playing=?,"
                "status=CASE WHEN status='waiting' THEN 'active' ELSE status END,updated=?"
                " WHERE id=?",
                (item.get("mediaId") or "", item["url"], item.get("title") or "",
                 item.get("cover") or "",
                 json.dumps(queue, ensure_ascii=False, separators=(",", ":")),
                 nxt, playing, now, rid))
            c.commit()
            fresh = _room_row(c, rid)
            _push_room(c, fresh)
            self._ok({"room": _room_payload(c, fresh, uid)})
            return True
        pos = body.get("positionMs")
        if pos is None:
            pos = _room_position_ms(d)
        try:
            pos = max(0, int(pos))
        except (TypeError, ValueError):
            self._err(400, "播放位置不正确")
            return True
        playing = 1 if body.get("playing") is True else 0
        now = time.time()
        c.execute(
            "UPDATE community_together_rooms SET position_ms=?,playing=?,"
            "status=CASE WHEN status='waiting' THEN 'active' ELSE status END,updated=?"
            " WHERE id=?", (pos, playing, now, rid))
        c.commit()
        fresh = _room_row(c, rid)
        _push_room(c, fresh)
        self._ok({"room": _room_payload(c, fresh, uid)})
        return True
    if action == "leave" and method == "POST":
        c.execute("UPDATE community_together_rooms SET status='ended', updated=?"
                  " WHERE id=?", (time.time(), rid))
        c.commit()
        fresh = _room_row(c, rid)
        _push_room(c, fresh, "room_ended")
        self._ok({"ended": True})
        return True
    if action == "reaction" and method == "POST":
        if d.get("status") == "ended":
            self._err(409, "房间已结束")
            return True
        body = _body(self)
        emoji = str(body.get("emoji") or "").strip()
        if emoji not in ROOM_REACTIONS:
            self._err(400, "未知反应")
            return True
        if not rate_limit(self, "together"):
            self._err(429, "慢一点")
            return True
        rxid = uuid.uuid4().hex
        now = time.time()
        c.execute(
            "INSERT INTO community_together_reactions(id,room_id,user_id,emoji,created)"
            " VALUES(?,?,?,?,?)", (rxid, rid, uid, emoji, now))
        c.commit()
        for target in {str(d["host_uid"]), str(d["guest_uid"])} - {str(uid)}:
            try:
                from handlers import ws as H_WS
                H_WS.ws_push(target, {
                    "kind": "together_reaction",
                    "reaction": {"roomId": rid, "userId": uid, "emoji": emoji,
                                 "created": now},
                })
            except Exception:
                pass
        self._ok({"reaction": {"id": rxid, "emoji": emoji, "created": now}})
        return True
    return False


def dispatch(self, c, u, api, method):
    if _handle_status(self, c, u, api, method):
        return True
    if _handle_poke(self, c, u, api, method):
        return True
    if _handle_pokes_unread(self, c, u, api, method):
        return True
    if api.startswith("/together/"):
        return _handle_together(self, c, u, api, method)
    return False
