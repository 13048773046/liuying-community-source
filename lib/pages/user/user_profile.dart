/// 用户主页 · 夜航档案（重设计版）
///
/// 结构：全幅身份封面 → 头像/认证/头衔/会员/管理员身份 → 签名与档案元信息
/// → 关注/粉丝/等级统计 → 他人主页关注/私信/分享，自己主页编辑资料/分享
/// → 帖子/短视频/应用三段档案。
///
/// 数据：只展示访问者可见字段；email 属于私密字段，不在这里读取。应用只走
/// 公开的“已上架投稿”接口，不把草稿/待审/驳回状态暴露给访问者。
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';

import '../../api/app_market_api.dart';
import '../../api/client.dart';
import '../../config.dart';
import '../../design/components.dart';
import '../../design/shared_element.dart';
import '../../models/app_market.dart';
import '../../models/feed_item.dart';
import '../../services/follow_bus.dart';
import '../apps/app_detail_page.dart';
import '../message/dm_chat_page.dart';
import '../mine/edit_profile_page.dart';
import '../mine/user_list_page.dart';
import '../post/post_detail.dart';
import '../share/share_target_sheet.dart';
import 'user_profile_chrome.dart';

const double _coverHeight = 190;

/// 今日状态沿用「流萤」代言人的表情贴纸语言：
/// 只选一个形象也能成为完整状态，文字是可选的补充。
class _StatusMood {
  final String key;
  final String label;
  final String legacyEmoji;
  const _StatusMood(this.key, this.label, this.legacyEmoji);

  String get asset => 'assets/brand/liuying/status/$key.png';
}

const _statusMoods = <_StatusMood>[
  _StatusMood('leaf', '松弛', '🌿'),
  _StatusMood('sun', '元气', '☀️'),
  _StatusMood('rain', '小雨', '🌧️'),
  _StatusMood('fire', '燃', '🔥'),
  _StatusMood('cat', '猫猫', '🐈'),
  _StatusMood('bubbles', '放空', '🫧'),
  _StatusMood('sleep', '困了', '💤'),
  _StatusMood('clover', '好运', '🍀'),
];

_StatusMood _statusMoodOf(String raw) {
  final value = raw.trim();
  for (final mood in _statusMoods) {
    if (value == mood.key || value == mood.legacyEmoji) return mood;
  }
  return _statusMoods.first;
}

class UserProfilePage extends StatefulWidget {
  final String uid;

  /// 从帖子卡片/详情进入时传入封面作者头像的 Hero tag，
  /// 让头像在「卡片 → 个人主页」之间连续飞行；直接进主页则为 null。
  final String? heroTag;

  const UserProfilePage({super.key, required this.uid, this.heroTag});

  @override
  State<UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends State<UserProfilePage> {
  Map<String, dynamic>? _user;
  bool _loading = true;
  _ProfileLoadError? _loadError;
  Map<String, dynamic>? _status;
  bool _statusVisible = false;
  bool _statusBusy = false;

  String _tab = 'text'; // text | video | app
  final Map<String, _FeedBucket> _feeds = {
    'text': _FeedBucket(),
    'video': _FeedBucket(),
  };
  final Map<String, int> _feedEpoch = {'text': 0, 'video': 0};

  final List<MarketApp> _apps = [];
  bool _appsLoaded = false;
  bool _appsLoading = false;
  String? _appsError;
  int _appsPage = 0;
  bool _appsHasMore = true;
  int _appsTotal = 0;
  int _appsEpoch = 0;

  bool _followBusy = false;
  bool _gateFollowBusy = false;
  bool _collapsed = false;

  int _profileEpoch = 0;
  late final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    FollowBus.relations.addListener(_onFollowBus);
    _load();
  }

  void _onFollowBus() {
    if (!mounted || _user == null) return;
    final next = FollowBus.relationOf(widget.uid);
    if (next != null && next != boolOf(_user!['following'])) {
      setState(() => _user!['following'] = next);
    }
  }

  @override
  void dispose() {
    FollowBus.relations.removeListener(_onFollowBus);
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    // 双阈值滞回：在临界点来回蹭时不要让顶栏反复起雾/退雾。
    final offset = _scroll.offset;
    if (!_collapsed && offset > 198) {
      setState(() => _collapsed = true);
    } else if (_collapsed && offset < 158) {
      setState(() => _collapsed = false);
    }
  }

  // ------------------------------------------------------------------ 请求
  Future<void> _load() async {
    await _loadProfile();
    if (!mounted || _user == null) return;
    await _loadStatus();
    if (!mounted || _user == null) return;
    await _loadActiveTab(refresh: true);
  }

  Future<void> _loadStatus() async {
    try {
      final j = await ApiClient.userStatus(widget.uid);
      if (!mounted) return;
      final raw = j['status'];
      setState(() {
        _statusVisible = boolOf(j['visible']);
        _status = raw is Map ? Map<String, dynamic>.from(raw) : null;
      });
    } catch (_) {
      // 状态是装饰信息，失败不拖垮主页主体。
    }
  }

  Future<void> _loadProfile({bool refresh = false}) async {
    final epoch = ++_profileEpoch;
    if (!refresh || _user == null) {
      setState(() {
        _loading = _user == null;
        _loadError = null;
      });
    } else {
      setState(() => _loadError = null);
    }
    try {
      final j = await ApiClient.userProfile(widget.uid);
      if (!mounted || epoch != _profileEpoch) return;
      final user = Map<String, dynamic>.from(j['user'] as Map);
      setState(() {
        _user = user;
        _loading = false;
        _loadError = null;
      });
      FollowBus.setRelation(widget.uid, boolOf(user['following']));
    } catch (e) {
      if (!mounted || epoch != _profileEpoch) return;
      final error = _ProfileLoadError.from(e);
      if (_user == null) {
        setState(() {
          _loading = false;
          _loadError = error;
        });
      } else {
        setState(() => _loading = false);
        showAppToast(context, '主页刷新失败：${error.message}');
      }
    }
  }

  Future<void> _refresh() async {
    await _loadProfile(refresh: true);
    if (!mounted || _user == null) return;
    await _loadStatus();
    if (!mounted || _user == null) return;
    await _loadActiveTab(refresh: true);
  }

  Future<void> _loadActiveTab({bool refresh = false}) {
    if (_tab == 'app') return _loadApps(refresh: refresh);
    return _loadFeed(_tab, refresh: refresh);
  }

  Future<void> _loadFeed(String type, {bool refresh = false}) async {
    final bucket = _feeds[type]!;
    if (bucket.loading) return;
    if (!refresh && !bucket.hasMore) return;
    final epoch = (_feedEpoch[type] ?? 0) + 1;
    _feedEpoch[type] = epoch;
    setState(() {
      bucket.loading = true;
      bucket.error = null;
    });
    try {
      final j = await ApiClient.get(
        '/user/${widget.uid}/posts',
        query: {
          'type': type,
          'page': '${refresh ? 1 : bucket.page + 1}',
          'size': '10',
          'personalized': '1',
        },
      );
      if (!mounted || epoch != _feedEpoch[type]) return;
      final list = ((j['list'] ?? []) as List)
          .whereType<Map<String, dynamic>>()
          .map(FeedItem.fromJson)
          .toList();
      setState(() {
        if (refresh) {
          bucket.items
            ..clear()
            ..addAll(list);
          bucket.page = 1;
        } else {
          bucket.items.addAll(list);
          bucket.page++;
        }
        bucket.hasMore = boolOf(j['hasMore']);
        bucket.loaded = true;
        bucket.loading = false;
        bucket.error = null;
      });
    } catch (e) {
      if (!mounted || epoch != _feedEpoch[type]) return;
      setState(() {
        bucket.loading = false;
        bucket.error = e.toString();
        bucket.loaded = true;
      });
    }
  }

  Future<void> _loadApps({bool refresh = false}) async {
    if (_appsLoading) return;
    if (!refresh && !_appsHasMore) return;
    final epoch = ++_appsEpoch;
    setState(() {
      _appsLoading = true;
      _appsError = null;
    });
    try {
      final result = await AppMarketApi.byUser(
        widget.uid,
        page: refresh ? 1 : _appsPage + 1,
        pageSize: 12,
      );
      if (!mounted || epoch != _appsEpoch) return;
      setState(() {
        if (refresh) {
          _apps
            ..clear()
            ..addAll(result.list);
          _appsPage = 1;
        } else {
          _apps.addAll(result.list);
          _appsPage++;
        }
        _appsTotal = result.total;
        _appsHasMore = result.hasMore;
        _appsLoaded = true;
        _appsLoading = false;
        _appsError = null;
      });
    } catch (e) {
      if (!mounted || epoch != _appsEpoch) return;
      setState(() {
        _appsLoading = false;
        _appsLoaded = true;
        _appsError = e.toString();
      });
    }
  }

  void _loadMoreActive() {
    if (_tab == 'app') {
      if (_appsLoaded) _loadApps();
    } else {
      final bucket = _feeds[_tab]!;
      if (bucket.loaded) _loadFeed(_tab);
    }
  }

  void _switchTab(int index) {
    final next = index == 0
        ? 'text'
        : index == 1
        ? 'video'
        : 'app';
    if (_tab == next) return;
    setState(() => _tab = next);
    if (next == 'app') {
      if (!_appsLoaded) _loadApps(refresh: true);
    } else {
      final bucket = _feeds[next]!;
      if (!bucket.loaded) _loadFeed(next, refresh: true);
    }
  }

  // ------------------------------------------------------------------ 动作
  Future<void> _toggleFollow() async {
    if (_followBusy || _user == null) return;
    // 自己的主页不存在“关注自己”，即使从旧入口进来也直接拦住。
    if (ApiClient.userId == widget.uid) return;
    setState(() => _followBusy = true);
    try {
      final following = await FollowBus.toggle(widget.uid);
      if (!mounted) return;
      setState(() {
        _user!['following'] = following;
        final oldFollowers = intOf(_user!['followers']);
        _user!['followers'] = following
            ? (oldFollowers == 0 ? 1 : oldFollowers + 1)
            : (oldFollowers > 0 ? oldFollowers - 1 : 0);
      });
    } catch (e) {
      if (!mounted) return;
      showAppToast(context, '操作失败：$e');
    } finally {
      if (mounted) setState(() => _followBusy = false);
    }
  }

  Future<void> _followFromGate() async {
    if (_gateFollowBusy) return;
    setState(() => _gateFollowBusy = true);
    try {
      await FollowBus.toggle(widget.uid);
      if (!mounted) return;
      await _loadProfile(refresh: true);
      if (!mounted || _user == null) return;
      await _loadActiveTab(refresh: true);
    } catch (e) {
      if (!mounted) return;
      showAppToast(context, '关注失败：$e');
    } finally {
      if (mounted) setState(() => _gateFollowBusy = false);
    }
  }

  /// 自己的公开主页：点“编辑资料”复用「我的」页同一套编辑页，
  /// 先走 `/user/me` 拿完整私密资料（邮箱、手机号掩码等），返回后整页刷新。
  Future<void> _openEditProfile() async {
    try {
      final j = await ApiClient.myProfile();
      final raw = j['user'];
      if (!mounted || raw is! Map) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => EditProfilePage(user: Map<String, dynamic>.from(raw)),
        ),
      );
      if (!mounted) return;
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      showAppToast(context, e is ApiException ? e.message : '资料加载失败，请稍后再试');
    }
  }

  Future<void> _openDm() async {
    final u = _user;
    if (u == null) return;
    // 自己的主页不出现“私信自己”。
    if (ApiClient.userId == widget.uid) return;
    final peerName = (u['name'] ?? '') as String;
    final peerAvatar = (u['avatar'] ?? '') as String;
    final peerFrame = (u['frameId'] ?? '') as String;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DmChatPage(
          peerId: widget.uid,
          peerName: peerName,
          peerAvatar: peerAvatar,
          peerFrameId: peerFrame,
          peerVerified:
              verifiedOf(u['verified']) ||
              (u['verifiedLabel'] ?? '').toString().trim().isNotEmpty,
          peerVerifiedLabel: (u['verifiedLabel'] ?? '').toString(),
          peerIsAi:
              boolOf(u['isAi']) ||
              (u['verifiedLabel'] ?? '').toString().trim().toUpperCase() ==
                  'AI',
        ),
      ),
    );
  }

  void _shareProfile() {
    final u = _user;
    if (u == null) return;
    showProfileShareSheet(
      context,
      uid: widget.uid,
      name: (u['name'] ?? '').toString(),
      avatar: (u['avatar'] ?? '').toString(),
    );
  }

  void _openPost(FeedItem item) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => PostDetailPage(postId: item.id)),
    );
  }

  void _openApp(MarketApp app) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => AppDetailPage(appId: app.id)),
    );
  }

  // ------------------------------------------------------------------ 页面
  @override
  Widget build(BuildContext context) {
    final opaqueTop = _user == null || _collapsed;
    return ImmersivePage(
      child: Stack(
        children: [
          _body(),
          _ProfileTopBar(
            opaque: opaqueTop,
            forceTitle: _user == null,
            showShare: _user != null,
            onShare: _shareProfile,
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading && _user == null) {
      return const ShimmerScope(child: ProfileArchiveSkeleton());
    }
    if (_user == null) {
      return _ProfileGate(
        error: _loadError,
        followBusy: _gateFollowBusy,
        onRetry: _loadProfile,
        onFollow: _followFromGate,
      );
    }
    return RefreshIndicator(
      color: const Color(AppColors.accent),
      backgroundColor: const Color(AppColors.elevated),
      onRefresh: _refresh,
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.axis == Axis.vertical &&
              n.metrics.extentAfter < n.metrics.viewportDimension * 1.2) {
            _loadMoreActive();
          }
          return false;
        },
        child: CustomScrollView(
          controller: _scroll,
          scrollCacheExtent: const ScrollCacheExtent.pixels(320),
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          slivers: [
            SliverToBoxAdapter(child: _identitySection()),
            SliverToBoxAdapter(child: _tabSection()),
            ..._contentSlivers(),
          ],
        ),
      ),
    );
  }

  /// 今日状态条：自己可编辑，好友可送抱抱/加油；不可见时不占位。
  Widget _statusStrip() {
    final isMine = ApiClient.userId == widget.uid;
    final status = _status;
    if (status == null && !isMine) return const SizedBox.shrink();
    final mood = _statusMoodOf((status?['mood'] ?? '').toString());
    final text = (status?['text'] ?? '').toString().trim();
    final active =
        text.isNotEmpty || (status?['mood'] ?? '').toString().isNotEmpty;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.x3, vertical: 9),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            const Color(AppColors.accent).withValues(alpha: 0.12),
            const Color(AppColors.card),
            const Color(AppColors.card),
          ],
        ),
        borderRadius: AppRadius.rMd,
        border: Border.all(
          color: active
              ? const Color(AppColors.accent).withValues(alpha: 0.28)
              : const Color(AppColors.border),
        ),
        boxShadow: active
            ? [
                BoxShadow(
                  color: const Color(AppColors.accent).withValues(alpha: 0.07),
                  blurRadius: 22,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black.withValues(alpha: 0.35),
              border: Border.all(
                color: const Color(AppColors.accent).withValues(alpha: 0.24),
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(AppColors.accent).withValues(alpha: 0.1),
                  blurRadius: 14,
                ),
              ],
            ),
            child: ClipOval(
              child: Opacity(
                opacity: active ? 1 : .55,
                child: Image.asset(
                  mood.asset,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Center(
                    child: Text(
                      mood.legacyEmoji,
                      style: const TextStyle(fontSize: 18),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      active ? '今日' : '今日状态',
                      style: AppType.micro.copyWith(
                        color: const Color(AppColors.accent),
                        fontSize: 9.5,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.4,
                      ),
                    ),
                    if (active) ...[
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          mood.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.micro.copyWith(
                            color: const Color(AppColors.textSecondary),
                            fontSize: 9.5,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  text.isEmpty ? (active ? '和流萤一起，慢慢过今天' : '今天想留下点什么？') : text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.caption.copyWith(
                    color: text.isEmpty
                        ? const Color(AppColors.textTertiary)
                        : const Color(AppColors.textPrimary),
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
          if (isMine)
            PressableScale(
              onTap: _statusBusy ? null : _editStatus,
              scale: 0.92,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Text(
                  active ? '编辑' : '设置',
                  style: AppType.micro.copyWith(
                    color: const Color(AppColors.accent),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            )
          else ...[
            _statusAction('抱抱', 'hug'),
            const SizedBox(width: 8),
            _statusAction('加油', 'cheer'),
          ],
        ],
      ),
    );
  }

  Widget _statusAction(String label, String kind) {
    return PressableScale(
      onTap: () => _sendStatusPoke(kind, label),
      scale: 0.9,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: const Color(AppColors.accent).withValues(alpha: 0.1),
          borderRadius: AppRadius.rPill,
          border: Border.all(
            color: const Color(AppColors.accent).withValues(alpha: 0.18),
          ),
        ),
        child: Text(
          label,
          style: AppType.micro.copyWith(
            color: const Color(AppColors.accent),
            fontSize: 10.5,
          ),
        ),
      ),
    );
  }

  /// 键盘弹起后用紧凑的 4×2 形象格替代大网格：8 个选择全部保留，
  /// 同时把文字输入和保存按钮留在首屏，不需要先收键盘。
  Widget _statusKeyboardMoodPicker({
    required String mood,
    required bool saving,
    required ValueChanged<String> onPick,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cell = (constraints.maxWidth - 24) / 4;
        return Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final m in _statusMoods)
              PressableScale(
                onTap: saving ? null : () => onPick(m.key),
                scale: 0.92,
                child: AnimatedContainer(
                  duration: AppMotion.fast,
                  width: cell,
                  height: 39,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 2,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: mood == m.key
                        ? const Color(AppColors.accent).withValues(alpha: 0.14)
                        : const Color(AppColors.card),
                    borderRadius: AppRadius.rSm,
                    border: Border.all(
                      color: mood == m.key
                          ? const Color(AppColors.accent)
                          : const Color(AppColors.border),
                      width: mood == m.key ? 1.2 : 1,
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ClipOval(
                        child: Image.asset(
                          m.asset,
                          width: 28,
                          height: 28,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => SizedBox(
                            width: 28,
                            height: 28,
                            child: Center(
                              child: Text(
                                m.legacyEmoji,
                                style: const TextStyle(fontSize: 14),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 3),
                      Flexible(
                        child: Text(
                          m.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.micro.copyWith(
                            fontSize: 9.5,
                            color: mood == m.key
                                ? const Color(AppColors.accent)
                                : const Color(AppColors.textSecondary),
                            fontWeight: mood == m.key
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _sendStatusPoke(String kind, String label) async {
    try {
      await ApiClient.sendPoke(widget.uid, kind: kind);
      if (!mounted) return;
      showAppToast(context, '$label 已送到');
    } catch (e) {
      if (!mounted) return;
      showAppToast(context, e is ApiException ? e.message : '$label 没送到，稍后再试');
    }
  }

  Future<void> _editStatus() async {
    if (_statusBusy) return;
    setState(() => _statusBusy = true);
    final initialText = (_status?['text'] ?? '').toString();
    final initialMood = _statusMoodOf((_status?['mood'] ?? '').toString()).key;
    final hasStatus =
        initialText.isNotEmpty ||
        (_status?['mood'] ?? '').toString().isNotEmpty;
    var textValue = initialText;
    var mood = initialMood;
    var saving = false;
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      useSafeArea: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.zero,
          child: SheetShell(
            title: '今日状态',
            subtitle: '选一个流萤的样子，再留 12 个字，好友在主页/私信能看到',
            child: SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.only(bottom: 2),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (MediaQuery.viewInsetsOf(ctx).bottom > 0)
                    _statusKeyboardMoodPicker(
                      mood: mood,
                      saving: saving,
                      onPick: (key) => setSheet(() => mood = key),
                    )
                  else
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final cell = (constraints.maxWidth - 24) / 4;
                        return Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final m in _statusMoods)
                              PressableScale(
                                onTap: saving
                                    ? null
                                    : () {
                                        FocusScope.of(ctx).unfocus();
                                        setSheet(() => mood = m.key);
                                      },
                                scale: 0.92,
                                child: AnimatedContainer(
                                  duration: AppMotion.fast,
                                  width: cell,
                                  height: 96,
                                  padding: const EdgeInsets.fromLTRB(
                                    4,
                                    7,
                                    4,
                                    6,
                                  ),
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: mood == m.key
                                          ? [
                                              const Color(AppColors.accent)
                                                  .withValues(alpha: 0.2),
                                              const Color(AppColors.card),
                                            ]
                                          : [
                                              const Color(AppColors.elevated),
                                              const Color(AppColors.card),
                                            ],
                                    ),
                                    borderRadius: AppRadius.rSm,
                                    border: Border.all(
                                      color: mood == m.key
                                          ? const Color(AppColors.accent)
                                          : const Color(AppColors.border),
                                      width: mood == m.key ? 1.2 : 1,
                                    ),
                                    boxShadow: mood == m.key
                                        ? [
                                            BoxShadow(
                                              color: const Color(
                                                AppColors.accent,
                                              ).withValues(alpha: 0.14),
                                              blurRadius: 16,
                                              spreadRadius: 1,
                                            ),
                                          ]
                                        : null,
                                  ),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Container(
                                        width: 56,
                                        height: 56,
                                        padding: const EdgeInsets.all(1.5),
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color: mood == m.key
                                                ? const Color(AppColors.accent)
                                                      .withValues(alpha: 0.55)
                                                : Colors.white.withValues(
                                                    alpha: 0.06,
                                                  ),
                                          ),
                                        ),
                                        child: ClipOval(
                                          child: Image.asset(
                                            m.asset,
                                            fit: BoxFit.cover,
                                            errorBuilder: (_, _, _) => Center(
                                              child: Text(
                                                m.legacyEmoji,
                                                style: const TextStyle(
                                                  fontSize: 20,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        m.label,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.center,
                                        style: AppType.micro.copyWith(
                                          fontSize: 10,
                                          color: mood == m.key
                                              ? const Color(AppColors.accent)
                                              : const Color(
                                                  AppColors.textSecondary,
                                                ),
                                          fontWeight: mood == m.key
                                              ? FontWeight.w600
                                              : FontWeight.w400,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  const SizedBox(height: AppSpace.x3),
                  TextFormField(
                    initialValue: initialText,
                    // 不自动聚焦：先让用户看到 8 个流萤形象，键盘不能把选择区顶掉。
                    autofocus: false,
                    maxLength: 12,
                    inputFormatters: [LengthLimitingTextInputFormatter(12)],
                    textInputAction: TextInputAction.done,
                    onTapOutside: (_) => FocusScope.of(ctx).unfocus(),
                    onFieldSubmitted: (_) => FocusScope.of(ctx).unfocus(),
                    onChanged: (v) => textValue = v,
                    style: AppType.bodySm,
                    decoration: InputDecoration(
                      hintText: '此刻想说什么',
                      counterText: '',
                      filled: true,
                      fillColor: const Color(AppColors.card),
                      border: OutlineInputBorder(
                        borderRadius: AppRadius.rMd,
                        borderSide: const BorderSide(
                          color: Color(AppColors.border),
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: AppRadius.rMd,
                        borderSide: const BorderSide(
                          color: Color(AppColors.border),
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: AppRadius.rMd,
                        borderSide: const BorderSide(
                          color: Color(AppColors.accent),
                        ),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: AppSpace.x3,
                        vertical: AppSpace.x2 + 2,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpace.x3),
                  PillButton(
                    label: saving ? '保存中…' : '保存状态',
                    variant: PillVariant.primary,
                    size: PillSize.lg,
                    expand: true,
                    loading: saving,
                    onTap: saving
                        ? null
                        : () async {
                            final text = textValue.trim();
                            setSheet(() => saving = true);
                            try {
                              final r = await ApiClient.setMyStatus(
                                mood: mood,
                                text: text,
                              );
                              if (!ctx.mounted) return;
                              final raw = r['status'];
                              setState(() {
                                _status = raw is Map
                                    ? Map<String, dynamic>.from(raw)
                                    : null;
                                _statusVisible = true;
                                _statusBusy = false;
                              });
                              Navigator.of(ctx).pop(true);
                            } catch (e) {
                              if (!ctx.mounted) return;
                              setSheet(() => saving = false);
                              showAppToast(
                                ctx,
                                e is ApiException ? e.message : '保存失败，请重试',
                              );
                            }
                          },
                  ),
                  if (hasStatus) ...[
                    const SizedBox(height: AppSpace.x2),
                    Center(
                      child: PressableScale(
                        onTap: saving
                            ? null
                            : () async {
                                setSheet(() => saving = true);
                                try {
                                  await ApiClient.setMyStatus(
                                    mood: '',
                                    text: '',
                                  );
                                  if (!ctx.mounted) return;
                                  setState(() {
                                    _status = null;
                                    _statusBusy = false;
                                  });
                                  Navigator.of(ctx).pop(true);
                                } catch (e) {
                                  if (!ctx.mounted) return;
                                  setSheet(() => saving = false);
                                  showAppToast(ctx, '清除失败，请重试');
                                }
                              },
                        child: Text(
                          '清除今日状态',
                          style: AppType.micro.copyWith(
                            color: const Color(AppColors.textTertiary),
                          ),
                        ),
                      ),
                    ),
                  ],
                  SizedBox(height: MediaQuery.paddingOf(ctx).bottom + 4),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _statusBusy = false);
  }

  // ------------------------------------------------------------------ 身份区
  Widget _identitySection() {
    final u = _user!;
    final name = _str(u['name'], '用户');
    final avatar = _str(u['avatar']);
    final title = _str(u['title']);
    final frameId = _str(u['frameId']);
    final level = intOf(u['level']);
    final exp = intOf(u['exp']);
    final followers = intOf(u['followers']);
    final followings = intOf(u['followings']);
    final following = boolOf(u['following']);
    final gender = _str(u['gender']);
    final age = intOf(u['age']);
    final city = _str(u['city']);
    final signature = _str(u['signature']);
    final background = _str(u['background']);
    final created = intOf(u['created']);
    final adminLevel = intOf(u['adminLevel']);
    final adminName = _str(u['adminName']);
    final cMember = _str(u['cMember']);
    final cMemberExpire = intOf(u['cMemberExpire']);
    final verified = verifiedOf(u['verified']);

    final isMine = ApiClient.userId == widget.uid;
    final isAdmin = adminLevel > 0;
    final isMember = cMember.isNotEmpty;
    final memberLabel = cMember == 'svip' ? 'SVIP' : 'VIP';
    final memberDays = _daysUntil(cMemberExpire);
    final memberText = isMember
        ? memberDays > 0
              ? '$memberLabel · 剩余 $memberDays 天'
              : memberLabel
        : '';

    final ringColor = isAdmin
        ? const Color(AppColors.warning)
        : isMember
        ? const Color(AppColors.lilac)
        : const Color(AppColors.accent);

    return Column(
      children: [
        ProfileCover(
          imageUrl: background.isEmpty ? '' : backgroundUrlOf(widget.uid),
          watermark: name,
          height: _coverHeight,
        ),
        // 头像下移到档案身份区，和昵称/身份标签同一行：头像在左，信息在右。
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.gutter,
            16,
            AppSpace.gutter,
            0,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                key: const ValueKey('profile-avatar'),
                width: 110,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: AppHero(
                    tag: widget.heroTag ?? '',
                    enabled: widget.heroTag != null,
                    child: AppAvatar(
                      url: avatar.isEmpty ? null : avatarUrl(avatar),
                      size: 94,
                      name: name,
                      ring: true,
                      ringColor: ringColor,
                      frameUrl: frameUrlOf(frameId),
                      verified: verified,
                      isAi:
                          boolOf(u['isAi']) ||
                          (u['verifiedLabel'] ?? '')
                                  .toString()
                                  .trim()
                                  .toUpperCase() ==
                              'AI',
                      badge: verified
                          ? null
                          : isMember
                          ? _MemberAvatarBadge(
                              key: const ValueKey('profile-member-badge'),
                              label: memberLabel,
                            )
                          : isAdmin
                          ? const _AdminAvatarBadge(
                              key: ValueKey('profile-admin-badge'),
                            )
                          : null,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AppSpace.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      key: const ValueKey('profile-display-name'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.h1,
                    ),
                    if (isAdmin || isMember || title.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 5,
                        children: [
                          if (isAdmin)
                            _IdentityChip(
                              icon: Icons.shield_outlined,
                              label: adminName.isEmpty ? '管理员' : adminName,
                              color: const Color(AppColors.warning),
                            ),
                          if (isMember)
                            _IdentityChip(
                              icon: Icons.workspace_premium_outlined,
                              label: memberText,
                              color: const Color(AppColors.lilac),
                            ),
                          if (title.isNotEmpty)
                            _IdentityChip(
                              icon: Icons.local_fire_department_outlined,
                              label: title,
                              color: const Color(AppColors.accent),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.gutter,
            14,
            AppSpace.gutter,
            0,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SignatureBlock(text: signature),
              if (ApiClient.userId == widget.uid || _statusVisible) ...[
                const SizedBox(height: 10),
                _statusStrip(),
              ],
              const SizedBox(height: 10),
              _MetaRail(
                city: city,
                gender: gender,
                age: age,
                joinedDays: _joinedDays(created),
              ),
              const SizedBox(height: 18),
              ProfileStatBand(
                followers: followers,
                followings: followings,
                level: level,
                exp: exp,
                onFollowers: () => _openUserList('followers', '粉丝'),
                onFollowings: () => _openUserList('followings', '关注'),
              ),
              const SizedBox(height: 10),
              if (isMine)
                Row(
                  children: [
                    Expanded(
                      child: PillButton(
                        label: '编辑资料',
                        variant: PillVariant.primary,
                        size: PillSize.lg,
                        expand: true,
                        icon: Icons.edit_outlined,
                        onTap: _openEditProfile,
                      ),
                    ),
                    const SizedBox(width: AppSpace.x2),
                    IconCircleButton(
                      icon: Icons.ios_share_rounded,
                      size: 48,
                      iconSize: 19,
                      background: const Color(AppColors.card),
                      tooltip: '分享主页',
                      onTap: _shareProfile,
                    ),
                  ],
                )
              else
                Row(
                  children: [
                    Expanded(
                      child: PillButton(
                        label: following ? '已关注' : '关注',
                        variant: following
                            ? PillVariant.tonal
                            : PillVariant.primary,
                        size: PillSize.lg,
                        expand: true,
                        glow: !following,
                        loading: _followBusy,
                        icon: following
                            ? Icons.check_rounded
                            : Icons.person_add_alt_1_rounded,
                        onTap: _toggleFollow,
                      ),
                    ),
                    const SizedBox(width: AppSpace.x2),
                    Expanded(
                      child: PillButton(
                        label: '私信',
                        variant: PillVariant.ghost,
                        size: PillSize.lg,
                        expand: true,
                        icon: Icons.chat_bubble_outline_rounded,
                        onTap: _openDm,
                      ),
                    ),
                    const SizedBox(width: AppSpace.x2),
                    IconCircleButton(
                      icon: Icons.ios_share_rounded,
                      size: 48,
                      iconSize: 19,
                      background: const Color(AppColors.card),
                      tooltip: '分享主页',
                      onTap: _shareProfile,
                    ),
                  ],
                ),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ],
    );
  }

  void _openUserList(String kind, String title) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => UserListPage(uid: widget.uid, kind: kind, title: title),
      ),
    );
  }

  Widget _tabSection() {
    final appTab = _tab == 'app';
    final rightLabel = appTab
        ? (_appsLoaded ? '$_appsTotal 款已上架' : '已上架应用')
        : '按最新发布';
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.gutter,
        AppSpace.x4,
        AppSpace.gutter,
        AppSpace.x2,
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 13,
                height: 13,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: const Color(AppColors.accent)
                        .withValues(alpha: 0.55),
                    width: 1,
                  ),
                ),
                child: Center(
                  child: Container(
                    width: 3,
                    height: 3,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(AppColors.accent),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                appTab ? '分享的应用' : '内容档案',
                style: AppType.label.copyWith(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Text(
                rightLabel,
                style: AppType.micro.copyWith(
                  color: const Color(AppColors.textTertiary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 1),
          ProfileTabBar(
            labels: const ['帖子', '短视频', '应用'],
            index: _tab == 'text'
                ? 0
                : _tab == 'video'
                ? 1
                : 2,
            onChanged: _switchTab,
          ),
          const Hairline(),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ 内容
  List<Widget> _contentSlivers() {
    if (_tab == 'app') return _appSlivers();
    final bucket = _feeds[_tab]!;
    if (bucket.items.isEmpty) {
      if (bucket.loading || (!bucket.loaded && bucket.error == null)) {
        return [
          SliverToBoxAdapter(
            child: ShimmerScope(child: _FeedGridSkeleton(columns: 2, count: 4)),
          ),
        ];
      }
      if (bucket.error != null) {
        return [
          SliverToBoxAdapter(
            child: _ArchiveErrorPanel(
              message: bucket.error!,
              onRetry: () => _loadFeed(_tab, refresh: true),
            ),
          ),
        ];
      }
      return [
        SliverToBoxAdapter(
          child: ProfileArchiveEmpty(
            icon: _tab == 'text'
                ? Icons.notes_rounded
                : Icons.play_circle_outline_rounded,
            title: _tab == 'text' ? '这里还没有帖子' : '这里还没有短视频',
            message: _tab == 'text' ? 'TA 还没有把想法留在这里。' : '等 TA 的第一段影像。',
          ),
        ),
        SliverToBoxAdapter(child: SizedBox(height: _bottomInset())),
      ];
    }
    return [
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.gutter),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: AppSpace.x2 + 2,
            crossAxisSpacing: AppSpace.x2 + 2,
            childAspectRatio: 0.79,
          ),
          delegate: SliverChildBuilderDelegate((context, i) {
            final item = bucket.items[i];
            return StaggerReveal(
              key: ValueKey('profile-work-$_tab-${item.id}'),
              index: i,
              child: ProfileWorkCard(
                item: item,
                index: i,
                onTap: () => _openPost(item),
              ),
            );
          }, childCount: bucket.items.length),
        ),
      ),
      SliverToBoxAdapter(child: _feedFooter(bucket)),
    ];
  }

  Widget _feedFooter(_FeedBucket bucket) {
    if (bucket.error != null) {
      return _LoadMoreError(
        onRetry: () => _loadFeed(_tab),
        label: '作品加载失败，点此重试',
      );
    }
    return Padding(
      padding: EdgeInsets.only(bottom: _bottomInset()),
      child: LoadMoreFooter(
        loading: bucket.loading,
        hasMore: bucket.hasMore,
        onTap: () => _loadFeed(_tab),
        endLabel: '— 档案到底了 —',
      ),
    );
  }

  List<Widget> _appSlivers() {
    if (_apps.isEmpty) {
      if (_appsLoading || (!_appsLoaded && _appsError == null)) {
        return [
          SliverToBoxAdapter(
            child: ShimmerScope(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.gutter,
                  AppSpace.x3,
                  AppSpace.gutter,
                  0,
                ),
                child: Column(
                  children: const [
                    SkeletonBox(height: 106, radius: AppRadius.lg),
                    SizedBox(height: AppSpace.x3),
                    SkeletonBox(height: 106, radius: AppRadius.lg),
                    SizedBox(height: AppSpace.x3),
                    SkeletonBox(height: 106, radius: AppRadius.lg),
                  ],
                ),
              ),
            ),
          ),
        ];
      }
      if (_appsError != null) {
        return [
          SliverToBoxAdapter(
            child: _ArchiveErrorPanel(
              message: _appsError!,
              onRetry: () => _loadApps(refresh: true),
            ),
          ),
        ];
      }
      return [
        SliverToBoxAdapter(
          child: ProfileArchiveEmpty(
            icon: Icons.apps_rounded,
            title: '还没有上架的应用',
            message: 'TA 还没有把应用分享到市场。',
          ),
        ),
        SliverToBoxAdapter(child: SizedBox(height: _bottomInset())),
      ];
    }
    return [
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.gutter),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate((context, i) {
            final app = _apps[i];
            return Padding(
              padding: EdgeInsets.only(
                bottom: AppSpace.x3,
                top: i == 0 ? AppSpace.x3 : 0,
              ),
              child: StaggerReveal(
                key: ValueKey('profile-app-${app.id}'),
                index: i,
                child: ProfileAppCard(app: app, onTap: () => _openApp(app)),
              ),
            );
          }, childCount: _apps.length),
        ),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.only(bottom: _bottomInset()),
          child: _appsError != null
              ? _LoadMoreError(onRetry: () => _loadApps(), label: '应用加载失败，点此重试')
              : LoadMoreFooter(
                  loading: _appsLoading,
                  hasMore: _appsHasMore,
                  onTap: () => _loadApps(),
                  endLabel: '— 应用已全部展示 —',
                ),
        ),
      ),
    ];
  }

  double _bottomInset() => MediaQuery.paddingOf(context).bottom + 28;
}

// ============================================================================
// 顶栏
// ============================================================================

class _ProfileTopBar extends StatelessWidget {
  const _ProfileTopBar({
    required this.opaque,
    required this.forceTitle,
    required this.showShare,
    required this.onShare,
  });

  final bool opaque;
  final bool forceTitle;
  final bool showShare;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    final titleVisible = opaque || forceTitle;
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: opaque ? 1 : 0),
        duration: AppMotion.base,
        curve: AppMotion.standard,
        builder: (context, t, _) {
          final sigma = 18 * t;
          final scrim = const Color(AppColors.bg).withValues(alpha: 0.86 * t);
          final iconBg = Color.lerp(
            Colors.black.withValues(alpha: 0.3),
            Colors.transparent,
            t,
          );
          final content = Container(
            padding: EdgeInsets.only(top: top),
            height: top + 52,
            decoration: BoxDecoration(
              color: scrim,
              border: Border(
                bottom: BorderSide(
                  color: const Color(AppColors.hairline).withValues(alpha: t),
                ),
              ),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: IconCircleButton(
                      icon: Icons.arrow_back_ios_new_rounded,
                      size: 36,
                      iconSize: 17,
                      background: iconBg,
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                  ),
                ),
                Opacity(
                  key: const ValueKey('profile-topbar-title-opacity'),
                  opacity: titleVisible ? 1 : t,
                  child: Text(
                    '个人主页',
                    style: AppType.title.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                if (showShare)
                  Align(
                    alignment: Alignment.centerRight,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: IconCircleButton(
                        icon: Icons.ios_share_rounded,
                        size: 36,
                        iconSize: 17,
                        tooltip: '分享主页',
                        background: iconBg,
                        onTap: onShare,
                      ),
                    ),
                  ),
              ],
            ),
          );
          return ClipRect(
            child: sigma > 0.01
                ? BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                    child: content,
                  )
                : content,
          );
        },
      ),
    );
  }
}

// ============================================================================
// 错误门
// ============================================================================

class _ProfileLoadError {
  const _ProfileLoadError({required this.code, required this.message});

  final int code;
  final String message;

  factory _ProfileLoadError.from(Object e) {
    if (e is ApiException) {
      return _ProfileLoadError(code: e.code, message: e.message);
    }
    return _ProfileLoadError(code: 0, message: e.toString());
  }

  bool get banned => code == 403 && message.contains('封禁');
  bool get private => code == 403 && !banned;
  bool get missing => code == 404;
}

class _ProfileGate extends StatelessWidget {
  const _ProfileGate({
    required this.error,
    required this.followBusy,
    required this.onRetry,
    required this.onFollow,
  });

  final _ProfileLoadError? error;
  final bool followBusy;
  final Future<void> Function({bool refresh}) onRetry;
  final Future<void> Function() onFollow;

  @override
  Widget build(BuildContext context) {
    final e = error;
    final private = e?.private ?? false;
    final banned = e?.banned ?? false;
    final missing = e?.missing ?? false;
    final icon = banned
        ? Icons.block_rounded
        : private
        ? Icons.lock_outline_rounded
        : missing
        ? Icons.person_off_outlined
        : Icons.cloud_off_rounded;
    final title = banned
        ? '这个账号已不可访问'
        : private
        ? '这是一份仅关注者可见的档案'
        : missing
        ? '这份档案不存在'
        : '档案暂时没有连上';
    final message = banned
        ? '该用户已被封禁，主页暂不开放。'
        : private
        ? '关注 TA 后，就能看到完整资料、作品和应用投稿。'
        : missing
        ? '用户可能已注销，或者链接有误。'
        : (e?.message.isNotEmpty == true ? e!.message : '检查网络后再试一次。');

    return RefreshIndicator(
      color: const Color(AppColors.accent),
      backgroundColor: const Color(AppColors.elevated),
      onRefresh: () => onRetry(refresh: true),
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                AppSpace.x7,
                MediaQuery.paddingOf(context).top + 132,
                AppSpace.x7,
                56,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 86,
                    height: 86,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(AppColors.card),
                      border: Border.all(color: const Color(AppColors.border)),
                      boxShadow: private
                          ? AppEffects.accentGlow(opacity: 0.18)
                          : null,
                    ),
                    child: Icon(
                      icon,
                      size: 34,
                      color: private
                          ? const Color(AppColors.accent)
                          : const Color(AppColors.textTertiary),
                    ),
                  ),
                  const SizedBox(height: AppSpace.x5),
                  Text(
                    'PROFILE / 档案',
                    style: AppType.micro.copyWith(
                      letterSpacing: 2,
                      color: const Color(AppColors.textDisabled),
                    ),
                  ),
                  const SizedBox(height: AppSpace.x2),
                  Text(title, textAlign: TextAlign.center, style: AppType.h2),
                  const SizedBox(height: AppSpace.x2),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: AppType.caption.copyWith(height: 1.55),
                  ),
                  const SizedBox(height: AppSpace.x6),
                  if (private)
                    PillButton(
                      label: '关注后查看',
                      icon: Icons.person_add_alt_1_rounded,
                      size: PillSize.md,
                      loading: followBusy,
                      glow: true,
                      onTap: onFollow,
                    )
                  else if (!banned && !missing)
                    PillButton(
                      label: '重新加载',
                      icon: Icons.refresh_rounded,
                      size: PillSize.md,
                      variant: PillVariant.ghost,
                      onTap: () => onRetry(),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// 身份小件
// ============================================================================

class _IdentityChip extends StatelessWidget {
  const _IdentityChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 23,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.micro.copyWith(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MemberAvatarBadge extends StatelessWidget {
  const _MemberAvatarBadge({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 5),
      decoration: BoxDecoration(
        color: const Color(AppColors.lilac),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(AppColors.bg), width: 2),
      ),
      child: Center(
        child: Text(
          label,
          style: AppType.micro.copyWith(
            fontSize: 8,
            fontWeight: FontWeight.w800,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

class _AdminAvatarBadge extends StatelessWidget {
  const _AdminAvatarBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: const Color(AppColors.warning),
        shape: BoxShape.circle,
        border: Border.all(color: const Color(AppColors.bg), width: 2),
      ),
      child: const Icon(
        Icons.shield_rounded,
        size: 11,
        color: Color(AppColors.bg),
      ),
    );
  }
}

class _SignatureBlock extends StatelessWidget {
  const _SignatureBlock({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final empty = text.trim().isEmpty;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 2,
          height: 34,
          decoration: BoxDecoration(
            color: empty
                ? const Color(AppColors.border)
                : const Color(AppColors.accent).withValues(alpha: 0.62),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: AppSpace.x2 + 2),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              empty ? '这个人的档案里还没有签名。' : text.trim(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: empty
                  ? AppType.bodySm.copyWith(
                      color: const Color(AppColors.textDisabled),
                    )
                  : AppType.body.copyWith(
                      color: const Color(AppColors.textSecondary),
                      height: 1.52,
                    ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MetaRail extends StatelessWidget {
  const _MetaRail({
    required this.city,
    required this.gender,
    required this.age,
    required this.joinedDays,
  });

  final String city;
  final String gender;
  final int age;
  final int joinedDays;

  @override
  Widget build(BuildContext context) {
    final genderText = gender.isEmpty || gender == '保密'
        ? ''
        : age > 0
        ? '$gender · $age 岁'
        : gender;
    final items = <Widget>[
      if (city.isNotEmpty) _MetaItem(icon: Icons.place_outlined, text: city),
      if (genderText.isNotEmpty)
        _MetaItem(icon: Icons.person_outline_rounded, text: genderText),
      if (joinedDays >= 0)
        _MetaItem(
          icon: Icons.auto_awesome_outlined,
          text: _joinedText(joinedDays),
        ),
    ];
    if (items.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: AppSpace.x4,
      runSpacing: AppSpace.x2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: items,
    );
  }
}

class _MetaItem extends StatelessWidget {
  const _MetaItem({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: const Color(AppColors.textTertiary)),
        const SizedBox(width: 4),
        Text(
          text,
          style: AppType.micro.copyWith(
            fontSize: 11.5,
            color: const Color(AppColors.textSecondary),
          ),
        ),
      ],
    );
  }
}

// ============================================================================
// 内容错误 / 骨架 / 数据小件
// ============================================================================

class _ArchiveErrorPanel extends StatelessWidget {
  const _ArchiveErrorPanel({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.gutter,
        AppSpace.x3,
        AppSpace.gutter,
        AppSpace.x4,
      ),
      child: Container(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.x4,
          AppSpace.x5,
          AppSpace.x4,
          AppSpace.x4,
        ),
        decoration: BoxDecoration(
          color: const Color(AppColors.card).withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: const Color(AppColors.hairline)),
        ),
        child: Column(
          children: [
            const Icon(
              Icons.cloud_off_rounded,
              size: 24,
              color: Color(AppColors.textTertiary),
            ),
            const SizedBox(height: AppSpace.x2),
            Text(
              '这段档案没加载出来',
              style: AppType.title.copyWith(
                color: const Color(AppColors.textSecondary),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: AppType.caption,
            ),
            const SizedBox(height: AppSpace.x3),
            PillButton(
              label: '重新加载',
              size: PillSize.sm,
              variant: PillVariant.ghost,
              icon: Icons.refresh_rounded,
              onTap: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadMoreError extends StatelessWidget {
  const _LoadMoreError({required this.onRetry, required this.label});

  final VoidCallback onRetry;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.x4),
      child: Center(
        child: PressableScale(
          onTap: onRetry,
          child: Text(
            label,
            style: AppType.caption.copyWith(
              color: const Color(AppColors.accent),
            ),
          ),
        ),
      ),
    );
  }
}

/// 首屏内容墙占位：与真实两列卡保持同一节奏。
class _FeedGridSkeleton extends StatelessWidget {
  const _FeedGridSkeleton({required this.columns, required this.count});

  final int columns;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.gutter,
        AppSpace.x3,
        AppSpace.gutter,
        0,
      ),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisSpacing: AppSpace.x2 + 2,
          crossAxisSpacing: AppSpace.x2 + 2,
          childAspectRatio: 0.79,
        ),
        itemCount: count,
        itemBuilder: (_, _) => const SkeletonBox(radius: AppRadius.lg),
      ),
    );
  }
}

class _FeedBucket {
  List<FeedItem> items = [];
  int page = 0;
  bool hasMore = true;
  bool loaded = false;
  bool loading = false;
  String? error;
}

String _str(Object? v, [String fallback = '']) {
  if (v == null) return fallback;
  final s = v.toString().trim();
  return s.isEmpty ? fallback : s;
}

int _daysUntil(int timestamp) {
  if (timestamp <= 0) return 0;
  final diff = timestamp - DateTime.now().millisecondsSinceEpoch ~/ 1000;
  if (diff <= 0) return 0;
  return (diff / 86400).ceil();
}

int _joinedDays(int created) {
  if (created <= 0) return -1;
  final diff = DateTime.now().millisecondsSinceEpoch ~/ 1000 - created;
  if (diff <= 0) return 0;
  return diff ~/ 86400;
}

String _joinedText(int days) {
  if (days <= 0) return '今天加入';
  if (days < 365) return '加入 $days 天';
  final years = days ~/ 365;
  final rest = days % 365;
  if (rest >= 30) return '加入 $years 年 $rest 天';
  return '加入 $years 年';
}
