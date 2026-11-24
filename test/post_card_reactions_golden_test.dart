import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:community_app/api/client.dart';
import 'package:community_app/design/components.dart';
import 'package:community_app/models/feed_item.dart'
    show FeedItem, debugTimeAgoNow;
import 'package:community_app/widgets/post_card.dart';

Future<void> _loadFont(String name, String path) async {
  final f = File(path);
  if (!f.existsSync()) return;
  final bytes = await f.readAsBytes();
  final loader = FontLoader(name)
    ..addFont(Future.value(ByteData.view(bytes.buffer)));
  await loader.load();
}

Future<void> _loadAll() async {
  await _loadFont('NotoSansSC', 'assets/fonts/NotoSansSC-Regular.otf');
  await _loadFont(
    'MaterialIcons',
    '/home/user/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
}

final _fixedNow = DateTime(2026, 11, 24, 10);

FeedItem _item() => FeedItem.fromJson({
  'id': 'p_card',
  'type': 'text',
  'content': '今天把「流萤」的五种表情放进了帖子卡片。\n同感、笑死、抱抱、学到了、蹲后续，点一下就能回应。',
  'images': <String>[],
  'topic': ['流萤社区', '互动设计'],
  'prompt': '如果给这张卡片加一句结尾，你会写什么？',
  'likeCount': 42,
  'commentCount': 8,
  'shareCount': 3,
  'liked': false,
  'faved': false,
  'created': _fixedNow.subtract(const Duration(hours: 2)).millisecondsSinceEpoch ~/ 1000,
  'author': {
    'id': 'u_liuying',
    'name': '流萤',
    'avatar': '',
    'level': 8,
    'adminLevel': 0,
  },
  'reactions': [
    {'type': 'same', 'count': 12, 'mine': false},
    {'type': 'laugh', 'count': 6, 'mine': false},
    {'type': 'hug', 'count': 3, 'mine': true},
    {'type': 'learned', 'count': 9, 'mine': false},
    {'type': 'waiting', 'count': 4, 'mine': false},
  ],
  'myReaction': 'hug',
});

Future<void> _warm(WidgetTester tester) async {
  const assets = [
    'assets/brand/liuying/reactions/same.png',
    'assets/brand/liuying/reactions/laugh.png',
    'assets/brand/liuying/reactions/hug.png',
    'assets/brand/liuying/reactions/learned.png',
    'assets/brand/liuying/reactions/waiting.png',
  ];
  await tester.runAsync(() async {
    final context = tester.element(find.byType(PostCard));
    for (final asset in assets) {
      await precacheImage(AssetImage(asset), context);
    }
  });
  await tester.pump();
}

void main() {
  setUpAll(_loadAll);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiClient.token = 'tok';
    debugTimeAgoNow = _fixedNow;
    addTearDown(() => debugTimeAgoNow = null);
  });

  testWidgets('帖子卡片反应条 390 宽', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 520 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildImmersiveTheme().copyWith(
          textTheme: buildImmersiveTheme().textTheme.apply(
            fontFamily: 'NotoSansSC',
          ),
        ),
        home: Scaffold(
          backgroundColor: const Color(AppColors.bg),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              children: [PostCard(item: _item())],
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await _warm(tester);
    expect(tester.takeException(), isNull);

    await expectLater(
      find.byType(PostCard),
      matchesGoldenFile('goldens/post_card_reactions_390.png'),
    );
    // CachedNetworkImage 的缓存清理 timer 是 10 秒，让它在测试结束前跑完。
    await tester.pump(const Duration(seconds: 11));
    await tester.pump();
  });

  testWidgets('帖子卡片反应条 320 窄屏无溢出', (tester) async {
    tester.view.physicalSize = const Size(320 * 3, 560 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildImmersiveTheme().copyWith(
          textTheme: buildImmersiveTheme().textTheme.apply(
            fontFamily: 'NotoSansSC',
          ),
        ),
        home: Scaffold(
          backgroundColor: const Color(AppColors.bg),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              children: [PostCard(item: _item())],
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await _warm(tester);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 11));
    await tester.pump();
  });
}
