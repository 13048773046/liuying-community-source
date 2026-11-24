import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/client.dart';
import '../design/components.dart';
import '../models/feed_item.dart';

/// 帖子轻反应条：五枚“流萤”表情，一个用户只保留一个反应。
///
/// 交互是乐观更新：点击立刻变化；请求成功以服务端全量计数为准，失败回到
/// 上一次服务端状态。快速连点时只用最后一次请求的结果，避免旧响应覆盖新状态。
class PostReactionsBar extends StatefulWidget {
  const PostReactionsBar({
    super.key,
    required this.postId,
    required this.initial,
    required this.initialMine,
    this.ensureLogin,
    this.compact = false,
  });

  final String postId;
  final List<PostReaction> initial;
  final String initialMine;

  /// 返回 false 表示用户未登录且已经跳转登录；不传则直接请求。
  final bool Function()? ensureLogin;
  final bool compact;

  @override
  State<PostReactionsBar> createState() => _PostReactionsBarState();
}

class _PostReactionsBarState extends State<PostReactionsBar> {
  late List<PostReaction> _server;
  late String _serverMine;
  late List<PostReaction> _shown;
  late String _mine;
  int _requestSeq = 0;

  static const _metas = <_ReactionMeta>[
    _ReactionMeta('same', '同感', 'assets/brand/liuying/reactions/same.png'),
    _ReactionMeta('laugh', '笑死', 'assets/brand/liuying/reactions/laugh.png'),
    _ReactionMeta('hug', '抱抱', 'assets/brand/liuying/reactions/hug.png'),
    _ReactionMeta(
      'learned',
      '学到了',
      'assets/brand/liuying/reactions/learned.png',
    ),
    _ReactionMeta(
      'waiting',
      '蹲后续',
      'assets/brand/liuying/reactions/waiting.png',
    ),
  ];

  @override
  void initState() {
    super.initState();
    _server = _normalize(widget.initial);
    _serverMine = _validType(widget.initialMine) ? widget.initialMine : '';
    _shown = _clone(_server);
    _mine = _serverMine;
  }

  @override
  void didUpdateWidget(covariant PostReactionsBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.postId == widget.postId) return;
    _server = _normalize(widget.initial);
    _serverMine = _validType(widget.initialMine) ? widget.initialMine : '';
    _shown = _clone(_server);
    _mine = _serverMine;
  }

  List<PostReaction> _normalize(List<PostReaction> list) {
    final byType = {for (final r in list) r.type: r};
    return [
      for (final m in _metas)
        PostReaction(
          type: m.type,
          count: byType[m.type]?.count ?? 0,
          mine: byType[m.type]?.mine ?? false,
        ),
    ];
  }

  List<PostReaction> _clone(List<PostReaction> list) => [
    for (final r in list)
      PostReaction(type: r.type, count: r.count, mine: r.mine),
  ];

  bool _validType(String type) =>
      _metas.any((m) => m.type == type);

  Future<void> _tap(String type) async {
    if (widget.ensureLogin != null && !widget.ensureLogin!()) return;
    HapticFeedback.lightImpact();
    final nextMine = _mine == type ? '' : type;
    final previousShown = _clone(_shown);
    final previousMine = _mine;
    setState(() {
      _shown = _applyLocal(_shown, previousMine, nextMine);
      _mine = nextMine;
    });
    final seq = ++_requestSeq;
    try {
      final result = await ApiClient.setPostReaction(
        widget.postId,
        type: nextMine.isEmpty ? null : nextMine,
      );
      if (!mounted || seq != _requestSeq) return;
      final server = _fromResponse(result);
      setState(() {
        _server = _clone(server);
        _serverMine = _typeFromResponse(result);
        _shown = _clone(server);
        _mine = _serverMine;
      });
    } catch (_) {
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _shown = previousShown;
        _mine = previousMine;
      });
      if (mounted) showAppToast(context, '反应没送达，稍后再试');
    }
  }

  List<PostReaction> _applyLocal(
    List<PostReaction> current,
    String oldType,
    String newType,
  ) {
    return [
      for (final r in current)
        PostReaction(
          type: r.type,
          count: r.type == oldType && oldType != newType
              ? (r.count > 0 ? r.count - 1 : 0)
              : r.type == newType && oldType != newType
              ? r.count + 1
              : r.count,
          mine: r.type == newType,
        ),
    ];
  }

  List<PostReaction> _fromResponse(Map<String, dynamic> result) {
    final raw = (result['reactions'] ?? const []) as List;
    return _normalize(
      raw.whereType<Map>().map((e) => PostReaction.fromJson(mapOf(e))).toList(),
    );
  }

  String _typeFromResponse(Map<String, dynamic> result) {
    final type = (result['myReaction'] ?? '').toString();
    return _validType(type) ? type : '';
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final gap = constraints.maxWidth < 330
            ? 3.0
            : (widget.compact ? 4.0 : 6.0);
        final perChip = (constraints.maxWidth - gap * 4) / 5;
        final size = perChip >= 61
            ? 26.0
            : perChip >= 49
            ? 22.0
            : 19.0;
        return Row(
          children: [
            for (final meta in _metas) ...[
              Expanded(
                child: _ReactionChip(
                  key: ValueKey('post-reaction-${widget.postId}-${meta.type}'),
                  meta: meta,
                  reaction: _shown.firstWhere(
                    (r) => r.type == meta.type,
                    orElse: () =>
                        PostReaction(type: meta.type, count: 0, mine: false),
                  ),
                  size: size,
                  onTap: () => _tap(meta.type),
                ),
              ),
              if (meta != _metas.last) SizedBox(width: gap),
            ],
          ],
        );
      },
    );
  }
}

class _ReactionMeta {
  const _ReactionMeta(this.type, this.label, this.asset);
  final String type;
  final String label;
  final String asset;
}

class _ReactionChip extends StatefulWidget {
  const _ReactionChip({
    super.key,
    required this.meta,
    required this.reaction,
    required this.size,
    required this.onTap,
  });

  final _ReactionMeta meta;
  final PostReaction reaction;
  final double size;
  final VoidCallback onTap;

  @override
  State<_ReactionChip> createState() => _ReactionChipState();
}

class _ReactionChipState extends State<_ReactionChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _bounce = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: 1.0, end: 1.12).chain(
        CurveTween(curve: Curves.easeOutCubic),
      ),
      weight: 45,
    ),
    TweenSequenceItem(
      tween: Tween(begin: 1.12, end: 1.0).chain(
        CurveTween(curve: Curves.easeOutCubic),
      ),
      weight: 55,
    ),
  ]).animate(_bounce);

  @override
  void initState() {
    super.initState();
    if (widget.reaction.mine) _bounce.value = 1;
  }

  @override
  void didUpdateWidget(covariant _ReactionChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.reaction.mine && !oldWidget.reaction.mine) {
      _bounce.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _bounce.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.reaction.mine;
    final meta = widget.meta;
    final size = widget.size;
    return Semantics(
      button: true,
      selected: active,
      label: '${meta.label}，${widget.reaction.count} 个反应',
      child: PressableScale(
        onTap: widget.onTap,
        scale: 0.9,
        haptic: false,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          curve: AppMotion.standard,
          height: size + 8,
          padding: EdgeInsets.symmetric(
            horizontal: size >= 24
                ? 4
                : size >= 21
                ? 1.5
                : 1,
          ),
          decoration: BoxDecoration(
            color: active
                ? const Color(AppColors.accent).withValues(alpha: 0.09)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(99),
            border: Border.all(
              color: active
                  ? const Color(AppColors.accent).withValues(alpha: 0.42)
                  : Colors.white.withValues(alpha: 0.055),
              width: 0.8,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ScaleTransition(
                scale: _scale,
                child: ClipOval(
                  child: Image.asset(
                    meta.asset,
                    width: size,
                    height: size,
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.medium,
                    semanticLabel: meta.label,
                  ),
                ),
              ),
              if (widget.reaction.count > 0) ...[
                SizedBox(
                  width: size >= 24
                      ? 4
                      : size >= 21
                      ? 2.5
                      : 2,
                ),
                SizedBox(
                  width: size >= 24
                      ? 18
                      : size >= 21
                      ? 13
                      : 11,
                  child: RollingText(
                    text: formatCount(widget.reaction.count),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: size >= 24 ? 10.5 : 9.5,
                      height: 1,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                      color: active
                          ? const Color(AppColors.accent)
                          : const Color(AppColors.textTertiary),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
