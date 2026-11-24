# Spug 短信通道配置

流萤社区短信验证码支持三种通道：腾讯云标准短信、阿里云标准短信、Spug 共享模板短信。当前生产环境还没有填 Spug 模板编码，所以 `/auth/send-code` 对手机号仍返回 503。

## 1. Spug 侧要准备什么

1. 打开 `https://push.spug.cc/`，微信扫码登录。
2. 完成个人实名认证。Spug 的控制台只要求实名；如果实名页要求企业营业执照，说明它的政策也收紧了，先停，不要充值。
3. 在后台创建一个短信验证码模板，选择平台官方验证码模板。模板内容不能自定义，短信签名是平台预置签名，不会显示【流萤社区】。
4. 复制模板编码，或者复制完整的调用地址 `https://push.spug.cc/sms/<模板编码>`。
5. 在后台把生产服务器公网 IP 加入 IP 白名单（不要写进仓库文档）。
6. 先用新用户赠送的测试条数发一条到自己手机，确认能收到再充值。

## 2. 生产配置

在服务器写入 `/www/wwwroot/yosar-data/config/spug_sms.json`，权限 600。

官方短信验证码模板（`/sms/`，推荐）：

```json
{
  "provider": "spug",
  "spug_template_code": "你的模板编码"
}
```

也可以直接填完整地址：

```json
{
  "provider": "spug",
  "spug_url": "https://push.spug.cc/sms/你的模板编码"
}
```

如果你用的是消息模板（`/send/`），需要同时告诉后端每个变量对应什么：

```json
{
  "provider": "spug",
  "spug_url": "https://push.spug.cc/send/你的模板编码",
  "spug_name": "流萤社区",
  "spug_number": "5",
  "spug_payload": {
    "name": "{name}",
    "code": "{code}",
    "number": "{number}",
    "targets": "{phone}"
  }
}
```

`spug_payload` 里 `{name}` 会替换成 `spug_name`，`{code}` 替换成验证码，`{number}` 替换成 `spug_number`（默认 5 分钟），`{phone}` 替换成接收手机号。不写 `spug_payload` 时默认就是上面这组变量。变量名必须和 Spug 模板里的一致，否则 Spug 会报缺变量或忽略。

`spug_template_code`、`spug_url` 二选一即可。模板编码是调用凭证，不要写进 H5、Flutter 或 Git 仓库。

写入后重启社区服务：

```bash
systemctl restart community.service
curl -sS http://127.0.0.1:8790/health
```

## 3. 验证

先用一个真实手机号请求发送验证码：

```bash
curl -sS -X POST https://www.dbmt999.asia/community/api/auth/send-code \
  -H 'Content-Type: application/json' \
  -d '{"identifier":"你的手机号"}'
```

返回 `{"ok":true,...}` 只代表 Spug 受理，不代表一定送达。到 Spug 后台的发送记录里用 `request_id` 核对真实状态，同时看手机是否收到。收到后，再用同一个手机号走 `/auth/login-code` 完成登录，并在 H5 邀请页走一遍“手机号验证 → 绑定邀请 → 奖励 ¥1 进入冻结台账”。

## 4. 失败排查

- `短信通道还没配置`：`spug_sms.json` 不存在、JSON 格式错误、模板编码为空，或服务没重启。
- `sms_provider:...`：Spug 返回了业务错误，常见是余额不足、IP 不在白名单、模板编码错误。
- `sms_unreachable:...`：服务器到 `push.spug.cc` 的网络不通，或请求超时。
- 返回成功但手机没收到：先查 Spug 发送记录；`code=200` 只是受理，不是送达。

## 5. 边界

Spug 是小厂共享模板通道，只用于登录验证码，不承担提现、资金等通知；提现仍走人工审核。短信签名不是【流萤社区】，用户可能会觉得发送方陌生，H5 上要提前写明“验证码由第三方短信服务发送”。如果后续有营业执照，再切回腾讯云/阿里云标准短信和自定义签名。
