/// 一起看的内容选择器：只列已通过审核的短视频，选中后返回可播放地址。
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../config.dart';
import '../../design/components.dart';
import '../../models/feed_item.dart';

/// 返回 {url,title,cover,mediaId}；取消返回 null
Future<Map<String, dynamic>?> showTogetherWatchPicker(BuildContext context) {
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    builder: (_) => const _TogetherWatchPicker(),
  );
}

class _TogetherWatchPicker extends StatefulWidget {
  const _TogetherWatchPicker();

  @override
  State<_TogetherWatchPicker> createState() => _TogetherWatchPickerState();
}

String _absMedia(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return '';
  if (s.startsWith('http://') || s.startsWith('https://')) return s;
  if (s.startsWith('/')) return '$kSiteBase$s';
  return mediaUrl(s);
}

class _TogetherWatchPickerState extends State<_TogetherWatchPicker> {
  List<FeedItem> _items = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final page = await ApiClient.feed(type: 'video', size: 12);
      if (!mounted) return;
      setState(() {
        _items = page.list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is ApiException ? e.message : '视频加载失败';
      });
    }
  }

  Map<String, dynamic> _pickPayload(int selected) {
    final items = <Map<String, dynamic>>[];
    var index = 0;
    for (var i = 0; i < _items.length; i++) {
      final item = _items[i];
      final video = _absMedia(item.video);
      if (video.isEmpty) continue;
      final title = item.content.replaceAll('\n', ' ').trim();
      if (i == selected) index = items.length;
      items.add({
        'url': video,
        'title': title.isEmpty ? '流萤短视频' : title,
        'cover': _absMedia(item.cover),
        'mediaId': item.id,
      });
    }
    final current = index < items.length ? items[index] : <String, dynamic>{};
    return {
      'url': (current['url'] ?? '').toString(),
      'title': (current['title'] ?? '').toString(),
      'cover': (current['cover'] ?? '').toString(),
      'mediaId': (current['mediaId'] ?? '').toString(),
      'queue': items,
      'queueIndex': index,
    };
  }

  @override
  Widget build(BuildContext context) {
    return SheetShell(
      title: '选一个一起看',
      subtitle: '房间只对你们两个人可见，两个人都能切上一段/下一段',
      child: SizedBox(
        height: 430,
        child: _loading
            ? const Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(AppColors.accent),
                ),
              )
            : _error != null
            ? Center(child: Text(_error!, style: AppType.bodySm))
            : _items.isEmpty
            ? const Center(child: Text('暂时没有可一起看的视频', style: AppType.bodySm))
            : ListView.separated(
                itemCount: _items.length,
                separatorBuilder: (_, _) => const Hairline(),
                itemBuilder: (context, i) {
                  final item = _items[i];
                  final cover = _absMedia(item.cover);
                  final title = item.content.replaceAll('\n', ' ').trim();
                  return PressableScale(
                    onTap: () {
                      Navigator.of(context).pop(_pickPayload(i));
                    },
                    scale: 0.98,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpace.x3,
                        vertical: AppSpace.x2,
                      ),
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius: AppRadius.rSm,
                            child: cover.isEmpty
                                ? Container(
                                    width: 64,
                                    height: 64,
                                    color: const Color(AppColors.card),
                                    child: const Icon(
                                      Icons.movie_outlined,
                                      color: Color(AppColors.textTertiary),
                                    ),
                                  )
                                : Image.network(
                                    cover,
                                    width: 64,
                                    height: 64,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) => Container(
                                      width: 64,
                                      height: 64,
                                      color: const Color(AppColors.card),
                                      child: const Icon(
                                        Icons.movie_outlined,
                                        color: Color(AppColors.textTertiary),
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
                                  title.isEmpty ? '流萤短视频' : title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppType.bodySm,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${item.author.name} · ${item.duration.toStringAsFixed(0)}s',
                                  style: AppType.micro,
                                ),
                              ],
                            ),
                          ),
                          const Icon(
                            Icons.chevron_right_rounded,
                            color: Color(AppColors.textTertiary),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
