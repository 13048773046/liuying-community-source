# 前端工业化分层

## 现状

- `lib/pages/*` 是同名功能页，页面内部直接持有 `setState`、请求、分页和重试。
- `lib/api/client.dart` 同时承担 HTTP、鉴权、错误映射和业务方法，是全局耦合点。
- `lib/services/*` 是跨页能力（登录态、发布、通知、下载），但边界与页面请求混在一起。
- 消息域已开始试点：`lib/features/message/data/message_repository.dart` 接管通知/私信 API，消息相关页面不再直接调用 `ApiClient` 的对应方法。

## 目标结构

```
lib/
  core/                 # 跨域基础设施：网络结果、错误、日志、请求资格
  features/
    message/
      data/             # Repository：唯一数据入口
      state/            # Controller：异步状态、分页、已读乐观更新
      widgets/          # 域内复用组件
      pages/            # 页面装配
    home/
    publish/
    mine/
    app_market/
  design/               # tokens + 通用组件（保持现状）
  services/             # 仅保留跨域能力，不承载页面业务
```

## 分层规则

1. 页面不直接调用 `ApiClient`；只通过所属 feature 的 Repository。
2. Repository 负责请求参数、错误映射、缓存/重试/去重；页面只消费结果。
3. Controller 负责异步状态归属：请求发出时消费资格，完成/失败/取消只更新当前上下文；旧请求不得覆盖新页面状态。
4. 跨域能力（登录态、WS、发布任务、下载）留在 `services/`，feature 通过接口调用，不复制实现。
5. `design/` 只放视觉令牌与无业务组件；不把页面状态塞进通用组件。
6. 先做“可运行的同行为迁移”，再抽 Controller；不要为了目录好看一次性重写大页面。

## 迁移顺序与验收

| 阶段 | 范围 | 验收 |
|---|---|---|
| 1 | 消息域 Repository（已完成） | 定向 analyze 无问题；消息 E2E 4/4 |
| 2 | 消息域 Controller/分页/已读状态 | 通知/私信渲染、已读、WS 回执回归 |
| 3 | 首页/发现域 | 首页混合流、搜索、榜单现有 golden/冒烟 |
| 4 | 发布域 | 发布流程、草稿、媒体上传测试 |
| 5 | 我的/资料域 | 资料、会员、应用投稿入口回归 |
| 6 | 应用市场域 | 列表/详情/下载/投稿回归 |

每阶段必须保留旧行为；发现共享组件默认值变化时，先确认影响面再改。

## 我的页状态刷新（0.9.18）

- `AuthSession.revision`：登录、切换账号、退出后自增；`MinePage` 监听后清空旧资料/列表并重新拉取，避免切换账号后残留上一账号。
- `UserDataBus.revision`：资料保存、头像上传、会员开通/续费/兑换、签到/任务领奖、头像框更换后自增；`MinePage` 监听后刷新资料、会员状态、等级/头像框与投稿数据。
- 头像 URL 带版本参数，换头像后不会命中 `CachedNetworkImage` 旧缓存。
- 我的页请求带 token/uid 快照与请求序号；账号切换时旧请求结果直接丢弃，不覆盖新账号状态。
- `PublishBus.completed` 发布成功后刷新「作品」列表和统计数。

## 帖子详情重构（0.9.19）

- 详情页从「媒体 + 直线堆叠 + 单行底栏」改成「封面 / 署名 / 正文 / 互动 / 讨论」五段式版面：媒体或文字封面独立成块，作者条与正文分离，正文使用 `NOTE / 日期` 版面标签和更大的标题字级。
- 互动数据改为带图标与说明的三段 rail；评论从纯文本行改为对话卡，评论入口改为可点击的编辑器卡。
- 纯文字帖生成专用文字封面，不再出现无媒体的空白首屏；图文帖仍保留 4:5 封面与图集指示，视频帖使用 16:9 封面。
- 页面保持沉浸黑、薄荷绿与 `AppMotion` 既有产品语言；390 宽度 golden 与 320 窄屏冒烟均纳入回归。

## 应用下载 HEAD 兼容（0.9.19）

- 服务端 `community/server.py` 补 `do_HEAD`，下载入口与网关探测不再返回 501；HEAD 只执行路由、不写响应体。
- 客户端 `AppDownloadManager._resolveTarget` 在 HEAD 返回 405/501 时，自动退回 `GET + Range: bytes=0-0` 获取 302 地址，兼容未实现 HEAD 的旧部署。
- 回归覆盖：本地服务端 HEAD 501、GET 302 场景；生产应用市场 4 个应用的 HEAD 302、网关 HEAD 200、Range 206 均实测通过。

## 当前不做的事

- 本轮不引入新的状态管理库；先沿用现有 `setState`，用 Repository 降低页面与网络的耦合。
- 不重排页面视觉；结构迁移以行为等价为前提。
- 不在前端复制后端业务规则；权限、互关、已读回执仍以服务端为准。

## 全站动效语言（0.9.21）

四条动效提示词统一沉淀到 `lib/design/motion.dart`，页面不再各写一套；`components.dart` 统一 export，页面只 import 通用组件即可。

- 骨架：`ShimmerScope` 提供共享 1.5s 时钟，`ShimmerBox` 用同一道斜向亮带；`ShimmerScope` 按当前是否有骨架启停，空页面不常驻调度帧。`main.dart` 在 `MaterialApp.builder` 包一层根 `ShimmerScope`，未单独包 scope 的页面骨架也同步。
- 错峰：`StaggerReveal` 默认每项 60ms、320ms 淡入上移 8px；应用/商品列表使用 50ms、450ms、24px 的传送带参数；索引上限 12，避免长列表延迟累积。
- 切换：`SkeletonSwap` 用 `AnimatedSwitcher` 做骨架与内容交叉淡出，尺寸由调用方固定（`BoardFeedGrid` 已接入）。
- 触底：`LoadMoreFooter` loading 态统一为 `LoadMoreDots`（900ms 三点依次跳动）；列表滚动阈值统一改为「距底约一屏」（`viewportDimension`），避免最后一屏才请求。
- 照片墙：`BlurUpImage` 用同色调底 + 64px 缩略图 20px 高斯模糊占位，原图解码后 500ms 淡入、1.04→1.0 缩回；外层尺寸由网格/父级固定。`PostGridTile`、`WaterfallCard`、搜索 `_FeedTile` 已替换；主滚动视图统一 `scrollCacheExtent: ScrollCacheExtent.pixels(300)`，让图片在进入视口前约 300px 开始加载。
- AI 回复：`ThinkingDots` 三点呼吸；`PhraseRevealText` 按 2–4 个中文字符切段（英文/URL 整词保留），每段 38ms 出现，240ms 内从透明 + 4px 模糊 + 下移 4px 变清晰，末尾 `BlinkingCaret` 闪动；`AnimatedSize` 让气泡高度平滑增长。`AfWorkbenchPage._scrollBottom` 流式追加改为 140ms `animateTo`，仍受 `_stick`/`_touching` 约束，用户上翻不抢滚动。
- Reduced motion：`MediaQuery.disableAnimations` 下扫光、错峰、三点、光标都退化为静态状态，逐段文本直接完整展示。

验收：`test/motion_language_test.dart` 覆盖切段、可拼回、扫光/三点共存、逐段追加；`test/motion_preview_golden_test.dart` 输出 4 组 390×844 动效视觉稿（骨架、照片墙模糊/清晰、商品错峰、AI 逐段）。

## 新三条交互落地（0.9.21）

- 分段标签：`lib/design/segmented_tabs.dart` 承载「关注 / 推荐」及后续多段场景。下划线位置与手指拖动连续绑定；拖动时用 `sin(pi * frac)` 做先伸长后收尾的毛毛虫形变；松手按距离（是否过半）与速度用 `SpringSimulation` 吸附；文字颜色、字号、字重随进度插值。首页标题区已替换为 `SegmentedTabs(large: true)`，右侧 LIVE 胶囊保留。
- 欢迎引导：`lib/pages/onboarding/welcome_guide_page.dart` 三页绘本式引导。插画、标题、正文使用不同位移/缩放系数形成前后层次；底部指示器连续伸缩，末页「开始使用」从下方滑入，前两页可跳过；小屏页面内容可纵向滚动，不压标题与按钮。`main.dart` 的 `WelcomeGate` 读取 `welcome_v1_seen`，首次启动展示一次，完成后写入标记；`CommunityApp(showWelcome:)` 默认 false，测试与已读用户直接进主界面。
- 吸顶大标题：`AppDetailPage` 用 `_heroCollapse` / `_heroPull` 两个 `ValueNotifier` 把滚动偏移映射为 0–1。上滑头图轻微上移缩至 0.965、压暗 0.20；下拉 overscroll 放大至 1.06；顶部导航标题随进度浮出，并加 `ClipRRect + BackdropFilter` 毛玻璃。`ScrollEndNotification` 在 40–240 区间按最近端吸附到 0 或 260，避免停在半路。
- Reduced motion 同样覆盖新交互：分段下划线不做毛毛虫伸长，欢迎引导关闭视差与滑入，吸顶只保留状态切换。

验收：`test/segmented_tabs_test.dart` 验证跟手、方向与吸附；`test/welcome_guide_shot_test.dart` 输出 3 张 390 宽视觉稿；`test/welcome_gate_test.dart` 验证首启门与已读标记；`test/welcome_narrow_test.dart` 覆盖 320×568 不溢出；`test/app_market_widget_test.dart` 覆盖详情展开/收起两态。

## 0.9.22：验证码翻牌与聚光灯引导

- 验证码按钮：`lib/design/flip_countdown_button.dart`。把发送中的 spinner、60s 冷却、每秒翻牌、结束回弹收敛到一个组件；`onSend` 返回 `Future<bool>`，只有服务端真正发送成功才进入冷却，失败不白锁 60 秒。数字按位拆成 `_FlipDigit`，旧数字向上滑出、新数字从下沿滑入（280ms / easeOutCubic）；冷却文案为「60s 后重发」，结束后恢复主色并做一次 420ms 轻弹。登录页只保留邮箱校验这一条业务判断，删除页面级 Timer。
- 聚光灯引导：`lib/design/spotlight_coach.dart`。70% 遮罩上挖圆角洞，洞边缘用主色柔光 + 白色呼吸描边；白色气泡带 1/3 进度、标题、一句说明与「下一步」，最后一步变「知道了」，右上角保留「跳过」。跨步骤时洞用 400ms `Rect.lerp` 滑到下一个 `GlobalKey`，气泡跟随目标平滑换位，不先消失再出现。无目标或尺寸变化时以目标 `RenderBox` 实时测量，不使用固定坐标。
- 首启接入：`main.dart` 读取 `post_actions_guide_v1_seen`，未读时置 `SpotlightFlags.postActions = true`；帖子详情把评论输入条、点赞、分享三个底部动作作为引导目标，完成/跳过后写回标记并关闭开关。测试默认关闭，避免 widget 测试被一次性引导污染。
- 验收：`flip_countdown_button_test.dart` 验证发送成功后 3s 冷却与恢复；`flip_countdown_golden_test.dart` 覆盖 108 宽按钮的 idle/60s 两态及 320 宽登录页不溢出；`spotlight_coach_test.dart` 覆盖三步切换与跳过；`post_detail_redesign_golden_test.dart` 输出 390 宽三步视觉稿并覆盖 320 窄屏不溢出。
- Reduced motion：聚光灯的呼吸描边与气泡弹出在 `MediaQuery.disableAnimations` 下退化为静态；翻牌按钮仍保留文字状态切换，但不做长距离滑动。
