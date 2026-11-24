/// 一起听 / 一起看 · 一对一同步房间
///
/// - 两个人都能控制播放/暂停/进度/切歌，状态以服务端 `positionMs + (now-updated)` 校准；
/// - WS 收到 room_state 立即应用，轮询只做断线兜底；
/// - 任一方退出即结束房间，媒体不可用时降级为可读提示。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:video_player/video_player.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../design/components.dart';
import '../../services/notify_bus.dart';

String _fullMediaUrl(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return s;
  if (s.startsWith('http://') || s.startsWith('https://')) return s;
  if (s.startsWith('/')) return '$kSiteBase$s';
  return mediaUrl(s);
}

class TogetherRoomPage extends StatefulWidget {
  final String roomId;
  const TogetherRoomPage({super.key, required this.roomId});

  @override
  State<TogetherRoomPage> createState() => _TogetherRoomPageState();
}

class _TogetherRoomPageState extends State<TogetherRoomPage> {
  Map<String, dynamic>? _room;
  bool _loading = true;
  String? _error;
  bool _host = false;
  String _kind = 'listen';
  String _title = '';
  String _cover = '';
  String _mediaUrl = '';
  List<Map<String, dynamic>> _queue = const [];
  int _queueIndex = 0;

  AudioPlayer? _audio;
  VideoPlayerController? _video;
  bool _playerReady = false;
  String? _playerError;
  bool _playing = false;
  int _positionMs = 0;
  int _durationMs = 0;
  bool _ended = false;
  bool _left = false;

  Timer? _poll;
  Timer? _ticker;
  Timer? _reactionTimer;
  StreamSubscription? _roomSub;
  StreamSubscription? _rxSub;

  String? _reactionEmoji;
  int _reactionSeq = 0;

  String get _myId => ApiClient.userId ?? '';

  @override
  void initState() {
    super.initState();
    _roomSub = NotifyBus.shared.onRoom.stream.listen(_onRoomEvent);
    _rxSub = NotifyBus.shared.onRoomReaction.stream.listen(_onRoomReaction);
    _loadRoom();
    _poll = Timer.periodic(const Duration(seconds: 4), (_) => _refreshRoom());
    _ticker = Timer.periodic(const Duration(milliseconds: 320), (_) {
      if (!mounted || !_playing || !_playerReady || _ended) return;
      final ms = _controllerPositionMs();
      if (ms != null) setState(() => _positionMs = ms);
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _ticker?.cancel();
    _reactionTimer?.cancel();
    _roomSub?.cancel();
    _rxSub?.cancel();
    _audio?.dispose();
    _video?.dispose();
    unawaited(_leaveRoom(silent: true));
    super.dispose();
  }

  Future<void> _loadRoom() async {
    try {
      final j = await ApiClient.togetherGet(widget.roomId);
      final raw = j['room'];
      if (!mounted || raw is! Map) return;
      final room = Map<String, dynamic>.from(raw);
      final isHost = _myId == (room['hostUid'] ?? '').toString();
      if (!isHost && (room['status'] ?? '') == 'waiting') {
        final joined = await ApiClient.togetherJoin(widget.roomId);
        final jr = joined['room'];
        if (jr is Map) {
          await _applyRoom(Map<String, dynamic>.from(jr), force: true);
          return;
        }
      }
      await _applyRoom(room, force: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is ApiException ? e.message : '房间加载失败';
      });
    }
  }

  Future<void> _refreshRoom() async {
    if (_ended || _loading) return;
    try {
      final j = await ApiClient.togetherGet(widget.roomId);
      final raw = j['room'];
      if (!mounted || raw is! Map) return;
      await _applyRoom(Map<String, dynamic>.from(raw));
    } catch (_) {
      // 轮询失败保留当前画面，WS 或下一次轮询会补。
    }
  }

  void _onRoomEvent(Map<String, dynamic> room) {
    if ((room['id'] ?? '') != widget.roomId) return;
    unawaited(_applyRoom(room));
  }

  Future<void> _applyRoom(
    Map<String, dynamic> room, {
    bool force = false,
  }) async {
    final kind = (room['kind'] ?? 'listen').toString();
    final media = _fullMediaUrl((room['mediaUrl'] ?? '').toString());
    final isHost = _myId == (room['hostUid'] ?? '').toString();
    final status = (room['status'] ?? '').toString();
    final ended = status == 'ended';
    final nextPlaying = room['playing'] == true;
    final targetMs = ((room['positionMs'] ?? 0) as num).toInt();

    final rawQueue = room['queue'];
    final queue = rawQueue is List
        ? rawQueue
              .whereType<Map>()
              .map((e) {
                final m = Map<String, dynamic>.from(e);
                return <String, dynamic>{
                  'url': _fullMediaUrl((m['url'] ?? '').toString()),
                  'title': (m['title'] ?? '').toString(),
                  'cover': (m['cover'] ?? '').toString(),
                  'mediaId': (m['mediaId'] ?? '').toString(),
                };
              })
              .where((m) => (m['url'] ?? '').toString().isNotEmpty)
              .toList()
        : <Map<String, dynamic>>[];
    if (queue.isEmpty && media.isNotEmpty) {
      queue.add({
        'url': media,
        'title': (room['title'] ?? '').toString(),
        'cover': (room['cover'] ?? '').toString(),
        'mediaId': (room['mediaId'] ?? '').toString(),
      });
    }
    var qIndex = ((room['queueIndex'] ?? 0) as num).toInt();
    if (qIndex < 0 || qIndex >= queue.length) qIndex = 0;
    final playerMissing = kind == 'listen'
        ? _audio == null
        : (_video == null || !_video!.value.isInitialized);
    final mediaChanged = _mediaUrl != media || _kind != kind || playerMissing;
    setState(() {
      _room = room;
      _host = isHost;
      _kind = kind;
      _title = (room['title'] ?? '').toString();
      _cover = (room['cover'] ?? '').toString();
      _mediaUrl = media;
      _queue = queue;
      _queueIndex = qIndex;
      _ended = ended;
      if (_durationMs > 0 && targetMs > _durationMs) {
        _positionMs = _durationMs;
      } else {
        _positionMs = targetMs;
      }
      _loading = false;
      _error = null;
    });
    if (ended) {
      await _pauseLocal();
      return;
    }
    if (mediaChanged && media.isNotEmpty) {
      await _buildPlayer(kind, media, seekMs: targetMs, autoplay: nextPlaying);
    } else {
      // 只有首次加入/明确 force 时才强拉进度；4 秒轮询靠 1.4 秒漂移阈值校正，
      // 避免每次轮询都 seek 造成听歌/看片周期性卡顿。
      await _syncLocal(targetMs, nextPlaying, force: force);
    }
  }

  Future<void> _buildPlayer(
    String kind,
    String media, {
    required int seekMs,
    required bool autoplay,
  }) async {
    _playerReady = false;
    _playerError = null;
    _audio?.dispose();
    _video?.dispose();
    _audio = null;
    _video = null;
    try {
      if (kind == 'listen') {
        final p = AudioPlayer();
        _audio = p;
        final duration = await p.setUrl(media);
        _durationMs = duration?.inMilliseconds ?? 0;
        await p.seek(Duration(milliseconds: seekMs));
        _playerReady = true;
        if (autoplay && !_ended) {
          await p.play();
        }
      } else {
        final p = VideoPlayerController.networkUrl(Uri.parse(media));
        _video = p;
        await p.initialize();
        p.addListener(_onVideoTick);
        _durationMs = p.value.duration.inMilliseconds;
        await p.seekTo(Duration(milliseconds: seekMs));
        _playerReady = true;
        if (autoplay && !_ended) {
          await p.play();
        }
      }
      if (mounted) setState(() => _playing = autoplay && !_ended);
    } catch (_) {
      _playerReady = false;
      if (mounted) {
        setState(() => _playerError = '这个内容暂时播不了，换一个再试');
      }
    }
  }

  void _onVideoTick() {
    final v = _video;
    if (!mounted || v == null || !v.value.isInitialized) return;
    final ms = v.value.position.inMilliseconds;
    if ((ms - _positionMs).abs() > 180 || v.value.isPlaying != _playing) {
      setState(() {
        _positionMs = ms;
        _playing = v.value.isPlaying && !_ended;
      });
    }
  }

  int? _controllerPositionMs() {
    if (_kind == 'listen') {
      return _audio?.position.inMilliseconds;
    }
    final v = _video;
    if (v != null && v.value.isInitialized) {
      return v.value.position.inMilliseconds;
    }
    return null;
  }

  Future<void> _syncLocal(
    int targetMs,
    bool playing, {
    required bool force,
  }) async {
    if (!_playerReady) return;
    final current = _controllerPositionMs() ?? _positionMs;
    if (force || (current - targetMs).abs() > 1400) {
      await _seekLocal(targetMs);
    }
    if (playing && !_playing) {
      await _playLocal();
    } else if (!playing && _playing) {
      await _pauseLocal();
    }
  }

  Future<void> _seekLocal(int ms) async {
    _positionMs = ms;
    try {
      if (_kind == 'listen') {
        await _audio?.seek(Duration(milliseconds: ms));
      } else {
        await _video?.seekTo(Duration(milliseconds: ms));
      }
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _playLocal() async {
    if (!_playerReady || _ended) return;
    try {
      if (_kind == 'listen') {
        await _audio?.play();
      } else {
        await _video?.play();
      }
      if (mounted) setState(() => _playing = true);
    } catch (_) {}
  }

  Future<void> _pauseLocal() async {
    try {
      if (_kind == 'listen') {
        await _audio?.pause();
      } else {
        await _video?.pause();
      }
    } catch (_) {}
    if (mounted) setState(() => _playing = false);
  }

  Future<void> _togglePlay() async {
    if (_ended) return;
    final next = !_playing;
    final target = _controllerPositionMs() ?? _positionMs;
    HapticFeedback.selectionClick();
    try {
      final j = await ApiClient.togetherSync(
        widget.roomId,
        positionMs: target,
        playing: next,
      );
      if (!mounted) return;
      final raw = j['room'];
      if (raw is Map) {
        await _applyRoom(Map<String, dynamic>.from(raw), force: true);
      }
    } catch (e) {
      if (!mounted) return;
      showAppToast(context, e is ApiException ? e.message : '同步失败，请稍后再试');
      return;
    }
    setState(() => _positionMs = target);
  }

  Future<void> _seekTo(int ms) async {
    if (_ended || _durationMs <= 0) return;
    final bounded = ms.clamp(0, _durationMs);
    await _seekLocal(bounded);
    try {
      await ApiClient.togetherSync(
        widget.roomId,
        positionMs: bounded,
        playing: _playing,
      );
    } catch (_) {
      if (mounted) showAppToast(context, '进度同步失败，对方可能停在旧位置');
    }
  }

  Future<void> _skipTrack(int direction) async {
    if (_ended) return;
    if (_queue.length <= 1) {
      showAppToast(
        context,
        _kind == 'listen' ? '这个房间只有一首，回私信换一个列表吧' : '这个房间只有一段，回私信换一个列表吧',
      );
      return;
    }
    HapticFeedback.selectionClick();
    try {
      final j = await ApiClient.togetherSync(
        widget.roomId,
        positionMs: 0,
        playing: _playing,
        direction: direction > 0 ? 'next' : 'prev',
      );
      if (!mounted) return;
      final raw = j['room'];
      if (raw is Map) {
        await _applyRoom(Map<String, dynamic>.from(raw), force: true);
      }
    } catch (e) {
      if (!mounted) return;
      showAppToast(context, e is ApiException ? e.message : '切歌失败，请稍后再试');
    }
  }

  Future<void> _sendReaction(String emoji) async {
    try {
      await ApiClient.togetherReaction(widget.roomId, emoji: emoji);
      _showReaction(emoji);
    } catch (e) {
      if (!mounted) return;
      showAppToast(context, e is ApiException ? e.message : '反应没送出去');
    }
  }

  void _onRoomReaction(Map<String, dynamic> rx) {
    if ((rx['roomId'] ?? '') != widget.roomId) return;
    _showReaction((rx['emoji'] ?? '').toString());
  }

  void _showReaction(String emoji) {
    if (emoji.isEmpty) return;
    _reactionTimer?.cancel();
    setState(() {
      _reactionEmoji = emoji;
      _reactionSeq++;
    });
    _reactionTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _reactionEmoji = null);
    });
  }

  Future<void> _leaveRoom({bool silent = false}) async {
    if (_left) return;
    _left = true;
    try {
      await ApiClient.togetherLeave(widget.roomId);
    } catch (_) {}
    if (!silent && mounted) Navigator.of(context).maybePop();
  }

  Future<void> _close() => _leaveRoom();

  String get _sceneAsset =>
      'assets/brand/liuying/scenes/together_${_kind == 'watch' ? 'watch' : 'listen'}.jpg';

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return ImmersivePage(
      child: Stack(
        children: [
          Positioned.fill(child: _ambientBackdrop()),
          Column(
            children: [
              _topBar(top),
              Expanded(
                child: _loading
                    ? const Center(
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(AppColors.accent),
                        ),
                      )
                    : _error != null
                    ? _errorView()
                    : _ended
                    ? _endedView()
                    : _roomBody(),
              ),
            ],
          ),
          if (_reactionEmoji != null) _reactionOverlay(),
        ],
      ),
    );
  }

  /// 整页铺满场景，不再用一张张卡片切断画面。
  Widget _ambientBackdrop() {
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Color(AppColors.bg)),
          Image.asset(
            _sceneAsset,
            fit: BoxFit.cover,
            alignment: Alignment.centerRight,
            color: Colors.black.withValues(alpha: 0.18),
            colorBlendMode: BlendMode.darken,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.54),
                  Colors.black.withValues(alpha: 0.16),
                  Colors.black.withValues(alpha: 0.42),
                  const Color(AppColors.bg).withValues(alpha: 0.94),
                ],
                stops: const [0, 0.3, 0.68, 1],
              ),
            ),
          ),
          Positioned(
            top: -70,
            right: -40,
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    const Color(AppColors.accent).withValues(alpha: 0.16),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _topBar(double top) {
    final peer = _room == null
        ? '一起${_kind == 'listen' ? '听' : '看'}'
        : _host
        ? '和 ${(_room!['guest'] as Map?)?['name'] ?? '好友'} 一起${_kind == 'listen' ? '听' : '看'}'
        : '和 ${(_room!['host'] as Map?)?['name'] ?? '房主'} 一起${_kind == 'listen' ? '听' : '看'}';
    return Container(
      height: top + 54,
      padding: EdgeInsets.only(top: top, left: AppSpace.x2, right: AppSpace.x3),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.5),
            Colors.black.withValues(alpha: 0.08),
          ],
        ),
      ),
      child: Row(
        children: [
          IconCircleButton(
            icon: Icons.arrow_back_ios_new_rounded,
            size: 36,
            iconSize: 17,
            onTap: _close,
          ),
          const SizedBox(width: AppSpace.x1),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  peer,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.title.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  _ended
                      ? '房间已结束'
                      : _room?['status'] == 'waiting'
                      ? '邀请已发到私信 · 等好友加入'
                      : _queue.isEmpty
                      ? '选一个内容，两个人就能一起${_kind == 'listen' ? '听' : '看'}'
                      : '两个人都能${_kind == 'listen' ? '切歌' : '切视频'}与暂停 · 实时同步',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.micro,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.cloud_off_rounded,
            size: 44,
            color: Color(AppColors.textTertiary),
          ),
          const SizedBox(height: AppSpace.x3),
          Text(_error!, style: AppType.bodySm),
          const SizedBox(height: AppSpace.x4),
          PillButton(label: '重试', variant: PillVariant.ghost, onTap: _loadRoom),
        ],
      ),
    );
  }

  Widget _endedView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipOval(
            child: Image.asset(
              'assets/brand/liuying/reactions/waiting.png',
              width: 84,
              height: 84,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(height: AppSpace.x3),
          Text('房间已经结束', style: AppType.title),
          const SizedBox(height: 6),
          Text('下次再一起听一首，或看一段吧', style: AppType.caption),
          const SizedBox(height: AppSpace.x4),
          PillButton(
            label: '回到聊天',
            variant: PillVariant.primary,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }

  Widget _roomBody() {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Column(
      children: [
        Expanded(child: _stage()),
        _controlDeck(bottom),
      ],
    );
  }

  Widget _stage() => _kind == 'listen' ? _listenStage() : _watchStage();

  Widget _listenStage() {
    final compact = MediaQuery.sizeOf(context).width < 360;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (_cover.isNotEmpty)
          Positioned(
            left: AppSpace.gutter,
            top: AppSpace.x2,
            child: ClipRRect(
              borderRadius: AppRadius.rMd,
              child: Image.network(
                _fullMediaUrl(_cover),
                width: compact ? 46 : 54,
                height: compact ? 46 : 54,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ),
        Positioned(
          left: AppSpace.gutter,
          right: AppSpace.gutter,
          bottom: AppSpace.x5,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _equalizer(),
                  const SizedBox(width: 8),
                  Text(
                    _playing ? '正在一起听' : '等一方按下播放',
                    style: AppType.micro.copyWith(
                      color: const Color(AppColors.accent),
                      letterSpacing: .6,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.x2),
              Text(
                _title.isEmpty ? '一首正在流的歌' : _title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppType.h1.copyWith(height: 1.18),
              ),
              const SizedBox(height: 8),
              Text(
                _queue.length > 1
                    ? '${_queueIndex + 1} / ${_queue.length} · 你们都能切上一首、下一首'
                    : '同一段旋律 · 同一段进度',
                style: AppType.caption.copyWith(
                  color: const Color(AppColors.textSecondary),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _watchStage() {
    final v = _video;
    final ready = _playerReady && v != null && v.value.isInitialized;
    return Column(
      children: [
        Expanded(
          child: ready
              ? LayoutBuilder(
                  builder: (context, c) {
                    final maxW = c.maxWidth - 32;
                    final maxH = c.maxHeight - 18;
                    final ratio = v.value.aspectRatio <= 0
                        ? 16 / 9
                        : v.value.aspectRatio;
                    var w = maxW;
                    var h = w / ratio;
                    if (h > maxH) {
                      h = maxH;
                      w = h * ratio;
                    }
                    return Center(
                      child: GestureDetector(
                        onTap: _togglePlay,
                        child: Container(
                          width: w,
                          height: h,
                          decoration: BoxDecoration(
                            borderRadius: AppRadius.rLg,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: .38),
                                blurRadius: 26,
                                offset: const Offset(0, 12),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: AppRadius.rLg,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                VideoPlayer(v),
                                if (!_playing)
                                  Container(
                                    color: Colors.black.withValues(alpha: .2),
                                    child: const Center(
                                      child: Icon(
                                        Icons.play_circle_fill_rounded,
                                        size: 52,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                )
              : _videoWaitingStage(),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
          child: _watchCaption(),
        ),
      ],
    );
  }

  Widget _watchCaption() {
    if (_title.isEmpty) return const SizedBox.shrink();
    return Row(
      children: [
        const Icon(
          Icons.movie_creation_outlined,
          size: 14,
          color: Color(AppColors.accent),
        ),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            _title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.caption,
          ),
        ),
        if (_queue.length > 1)
          Text(
            '${_queueIndex + 1} / ${_queue.length}',
            style: AppType.micro.copyWith(
              color: const Color(AppColors.textSecondary),
            ),
          ),
      ],
    );
  }

  Widget _videoWaitingStage() {
    final message = _playerError != null
        ? _playerError!
        : _mediaUrl.isEmpty
        ? '这条视频还没有准备好'
        : null;
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.asset(
          _sceneAsset,
          fit: BoxFit.cover,
          alignment: Alignment.centerRight,
          errorBuilder: (_, _, _) =>
              const ColoredBox(color: Color(AppColors.card)),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: .16),
                Colors.black.withValues(alpha: .48),
              ],
            ),
          ),
        ),
        Align(
          alignment: const Alignment(0, .58),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.play_circle_outline_rounded,
                size: 34,
                color: Colors.white.withValues(alpha: .72),
              ),
              const SizedBox(height: 10),
              Text(
                message ?? '正在点亮投影…',
                textAlign: TextAlign.center,
                style: AppType.caption.copyWith(
                  color: message == null
                      ? const Color(AppColors.textSecondary)
                      : const Color(AppColors.textPrimary),
                ),
              ),
              if (message == null) ...[
                const SizedBox(height: 10),
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    color: Color(AppColors.accent),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _equalizer() {
    return SizedBox(
      width: 18,
      height: 14,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < 3; i++)
            Container(
              width: 3,
              height: _playing ? 14 - i * 2 : 5,
              margin: const EdgeInsets.only(right: 2),
              decoration: BoxDecoration(
                color: const Color(AppColors.accent),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
        ],
      ),
    );
  }

  Widget _controlDeck(double bottom) {
    return Container(
      padding: EdgeInsets.fromLTRB(12, 2, 12, bottom + 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            const Color(AppColors.bg).withValues(alpha: .82),
            const Color(AppColors.bg),
          ],
          stops: const [0, .22, 1],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _progress(),
          const SizedBox(height: 2),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _skipButton(
                icon: Icons.skip_previous_rounded,
                label: _kind == 'listen' ? '上一首' : '上一段',
                onTap: () => _skipTrack(-1),
              ),
              const SizedBox(width: 26),
              PressableScale(
                onTap: _togglePlay,
                scale: .92,
                child: Container(
                  width: 58,
                  height: 58,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        const Color(AppColors.accent),
                        const Color(AppColors.accent).withValues(alpha: .7),
                      ],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(AppColors.accent)
                            .withValues(alpha: .3),
                        blurRadius: 22,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                  child: Icon(
                    _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    size: 30,
                    color: const Color(AppColors.onAccent),
                  ),
                ),
              ),
              const SizedBox(width: 26),
              _skipButton(
                icon: Icons.skip_next_rounded,
                label: _kind == 'listen' ? '下一首' : '下一段',
                onTap: () => _skipTrack(1),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _reactionRow(),
          const SizedBox(height: 9),
          _syncLine(),
        ],
      ),
    );
  }

  Widget _skipButton({
    required IconData icon,
    required String label,
    required Future<void> Function() onTap,
  }) {
    return IconButton(
      tooltip: label,
      onPressed: _ended
          ? null
          : () {
              HapticFeedback.selectionClick();
              onTap();
            },
      icon: Icon(icon, size: 28),
      color: const Color(AppColors.textSecondary),
      disabledColor: const Color(AppColors.textTertiary),
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      padding: EdgeInsets.zero,
    );
  }

  Widget _progress() {
    final max = _durationMs > 0 ? _durationMs.toDouble() : 1.0;
    final value = _durationMs > 0
        ? _positionMs.clamp(0, _durationMs).toDouble()
        : 0.0;
    final canSeek = !_ended && _durationMs > 0;
    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 2.5,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5.5),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            activeTrackColor: const Color(AppColors.accent),
            inactiveTrackColor: Colors.white.withValues(alpha: .14),
            thumbColor: const Color(AppColors.accent),
            disabledActiveTrackColor: const Color(AppColors.textTertiary),
            disabledInactiveTrackColor: Colors.white.withValues(alpha: .08),
          ),
          child: Slider(
            value: value,
            max: max,
            onChanged: canSeek
                ? (v) => setState(() => _positionMs = v.toInt())
                : null,
            onChangeEnd: canSeek ? (v) => _seekTo(v.toInt()) : null,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              Text(_fmt(_positionMs), style: AppType.micro),
              const Spacer(),
              Text(
                _durationMs > 0 ? _fmt(_durationMs) : '--:--',
                style: AppType.micro,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _reactionRow() {
    const stickers = [
      ('same', '同感'),
      ('laugh', '笑死'),
      ('hug', '抱抱'),
      ('learned', '学到了'),
      ('waiting', '蹲后续'),
    ];
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        for (final (code, label) in stickers)
          PressableScale(
            onTap: () => _sendReaction(code),
            scale: .9,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipOval(
                    child: Image.asset(
                      'assets/brand/liuying/reactions/$code.png',
                      width: 34,
                      height: 34,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    style: AppType.micro.copyWith(
                      fontSize: 9,
                      color: const Color(AppColors.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _syncLine() {
    final host = (_room?['host'] as Map?) ?? const {};
    final guest = (_room?['guest'] as Map?) ?? const {};
    final hostName = (host['name'] ?? '房主').toString();
    final guestName = (guest['name'] ?? '好友').toString();
    final hostAvatar = (host['avatar'] ?? '').toString();
    final guestAvatar = (guest['avatar'] ?? '').toString();
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        AppAvatar(
          url: hostAvatar.isEmpty
              ? avatarUrlOf((host['id'] ?? '').toString())
              : avatarUrl(hostAvatar),
          name: hostName,
          size: 18,
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            hostName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.micro.copyWith(fontSize: 9),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 7),
          child: Text(
            '实时同步',
            style: TextStyle(
              fontSize: 9,
              color: Color(AppColors.accent),
              letterSpacing: .4,
            ),
          ),
        ),
        Flexible(
          child: Text(
            guestName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.micro.copyWith(fontSize: 9),
          ),
        ),
        const SizedBox(width: 4),
        AppAvatar(
          url: guestAvatar.isEmpty
              ? avatarUrlOf((guest['id'] ?? '').toString())
              : avatarUrl(guestAvatar),
          name: guestName,
          size: 18,
        ),
      ],
    );
  }

  Widget _reactionOverlay() {
    return Positioned.fill(
      key: const ValueKey('room_reaction_overlay'),
      child: IgnorePointer(
        child: Align(
          alignment: const Alignment(0.72, -0.22),
          child: TweenAnimationBuilder<double>(
            key: ValueKey(_reactionSeq),
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 760),
            curve: Curves.elasticOut,
            builder: (context, t, child) => Transform.translate(
              offset: Offset(22 * (1 - t), 0),
              child: Transform.scale(
                scale: 0.6 + t * 0.4,
                child: Opacity(opacity: t.clamp(0, 1), child: child),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.75),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(AppColors.accent)
                          .withValues(alpha: 0.45),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(AppColors.accent)
                            .withValues(alpha: 0.22),
                        blurRadius: 20,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                  child: ClipOval(
                    child: Image.asset(
                      'assets/brand/liuying/reactions/${_reactionEmoji ?? 'same'}.png',
                      width: 64,
                      height: 64,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
                const SizedBox(height: 5),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(AppColors.accent)
                        .withValues(alpha: 0.14),
                    borderRadius: AppRadius.rPill,
                    border: Border.all(
                      color: const Color(AppColors.accent)
                          .withValues(alpha: 0.24),
                    ),
                  ),
                  child: Text(
                    _reactionLabel(_reactionEmoji),
                    style: AppType.micro.copyWith(
                      color: const Color(AppColors.accent),
                      fontSize: 9.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _reactionLabel(String? code) => switch (code) {
    'laugh' => '笑死',
    'hug' => '抱抱',
    'learned' => '学到了',
    'waiting' => '蹲后续',
    _ => '同感',
  };

  String _fmt(int ms) {
    final s = (ms / 1000).clamp(0, 86400).toInt();
    final m = s ~/ 60;
    final sec = s % 60;
    return '$m:${sec.toString().padLeft(2, '0')}';
  }
}
