# 消息已读端到端（E2E）交付报告

## 结论

消息已读体系已从 Mock 单测补到**真实端到端**：真实 Python 后端、真实 SQLite、真实 HTTP、真实 WebSocket，覆盖页面点击到落库回查。4 个 E2E 用例全部通过，消息相关回归 14 项全部通过。

## 覆盖链路

1. 真实后端：分类未读 → 按 like 分类已读 → 私信全部已读 → SQLite 回查。
2. 消息页：三类未读合计 9 → 点击「全部已读」→ 三类红点归零 → 后端回查为 0。
3. 互动通知：进入不自动已读 → 点击单条未读 → 落库并更新「未读/已读」文案。
4. 私信聊天：进入会话标记已读 → 己方气泡显示未读/已读 → peer 读取后经真实 WS 推送 `dm_read`，己方气泡实时变已读。

## 测试设施

- `test/message_e2e_test.dart`
- `community/tests/message_e2e_fixture.py`：每个用例独立临时 SQLite + 127.0.0.1 端口 + 真实 `community/server.py` + 种子数据。
- `flutter test --no-pub test/message_e2e_test.dart`

## 本轮修复的真实缺陷

1. `/dm/read-all`、`/official-messages/read` 等无 body 路由未消费请求体，HTTP/1.1 keep-alive 下会把 `{}` 留给下一个请求，导致下一个 GET 被解析成 `{}GET` 并返回 501。
   - 服务端：`community/server.py` 增加 `_body_remaining` 跟踪与 `_drain_body()` 兜底排空。
   - 客户端：`ApiClient.post` 在 `body == null` 时不再发送 `{}`。
2. 测试环境：Flutter test binding 默认 mock HttpClient，已用 `HttpOverrides.runZoned` 恢复真实网络；`NotifyBus` WS 地址改用 `ApiClient.baseUrl`，使测试 baseOverride 对真实 WS 生效。
3. 测试断言修正：`testWidgets` 中真实 HTTP 回查必须包在 `tester.runAsync`，否则会被 fake async 卡死；通知单条点击改用唯一副标题定位，避免误点已读行。

## 主服务器验证

- 主机：生产服务器（公网域名 `www.dbmt999.asia`）
- 服务：`community.service`，`active`
- `GET /community/api/health` → 200
- `POST /community/api/dm/read-all`（未登录）→ 401，同一 keep-alive 连接的下一个 `GET /community/api/health` → 200
- `POST /community/api/official-messages/read`（未登录）→ 401，同一连接下一个 GET → 200
- 备份：`/www/wwwroot/Yosar-community/server.py.bak-v57-keepalive`

## CI

`.github/workflows/build.yml` 新增 `message-e2e` job，push 时自动跑 `test/message_e2e_test.dart`。

## 交付

- Android：`0.9.14+85`，`build/app/outputs/flutter-apk/app-release.apk`
- E2E 测试与夹具见上。
