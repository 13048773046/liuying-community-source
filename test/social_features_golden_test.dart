/// 轻互动四件套渲染验收：私信状态/戳一戳/邀请卡、小萤接话、今日状态、一起听房间。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:community_app/api/client.dart';
import 'package:community_app/design/components.dart';
import 'package:community_app/pages/message/dm_chat_page.dart';
import 'package:community_app/pages/message/together_room_page.dart';
import 'package:community_app/pages/user/user_profile.dart';
import 'package:community_app/services/notify_bus.dart';
import 'package:community_app/widgets/comment_sheet.dart';

http.Response _ok(Map<String, dynamic> body) => http.Response.bytes(
  utf8.encode(jsonEncode({'ok': true, ...body})),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

Future<void> _loadFont(String name, String path) async {
  final f = File(path);
  if (!f.existsSync()) return;
  final bytes = await f.readAsBytes();
  final loader = FontLoader(name)
    ..addFont(Future.value(ByteData.view(bytes.buffer)));
  await loader.load();
}

Future<void> _loadFonts() async {
  await _loadFont('LAT', '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf');
  await _loadFont(
    'CJK',
    '/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf',
  );
  await _loadFont(
    'NotoColorEmoji',
    '/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf',
  );
  await _loadFont(
    'MaterialIcons',
    '/home/user/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
}

ThemeData _theme() => ThemeData(
  useMaterial3: true,
  brightness: Brightness.dark,
  fontFamily: 'LAT',
  fontFamilyFallback: const ['CJK', 'NotoColorEmoji'],
  scaffoldBackgroundColor: const Color(AppColors.bg),
);

Widget _wrap(Widget child, {double width = 390, double height = 844}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: _theme(),
    home: Scaffold(
      backgroundColor: const Color(AppColors.bg),
      body: SizedBox(width: width, height: height, child: child),
    ),
  );
}

Future<void> _warmAssets(WidgetTester tester) async {
  await tester.runAsync(() async {
    final context = tester.element(find.byType(MaterialApp).first);
    for (final name in const ['waiting', 'learned', 'hug', 'same', 'laugh']) {
      await precacheImage(
        AssetImage('assets/brand/liuying/reactions/$name.png'),
        context,
      );
    }
    for (final name in const [
      'leaf',
      'sun',
      'rain',
      'fire',
      'cat',
      'bubbles',
      'sleep',
      'clover',
    ]) {
      await precacheImage(
        AssetImage('assets/brand/liuying/status/$name.png'),
        context,
      );
    }
    for (final name in const ['together_listen', 'together_watch']) {
      await precacheImage(
        AssetImage('assets/brand/liuying/scenes/$name.jpg'),
        context,
      );
    }
  });
}

final _now = DateTime.now().millisecondsSinceEpoch / 1000;

Map<String, dynamic> _togetherCard() => {
  'kind': 'together',
  'roomId': 'r1',
  'roomKind': 'listen',
  'title': '夜里两点的歌单',
  'cover': '',
  'fromName': '我',
};

Map<String, dynamic> _pokeMessage() => {
  'id': 'm3',
  'senderId': 'u1',
  'content': jsonEncode({
    'action': 'hug',
    'fromId': 'u1',
    'fromName': '夏梓璇',
    'fromAvatar': '',
  }),
  'msgType': 'poke',
  'created': _now - 5,
  'isRead': 1,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => Directory.systemTemp.path,
        );
    await _loadFonts();
  });

  setUp(() {
    NotifyBus.enabled = false;
    ApiClient.token = 'social-shot-token';
    ApiClient.userId = 'me';
  });

  tearDown(() {
    ApiClient.httpClient = http.Client();
    ApiClient.token = null;
    ApiClient.userId = null;
    NotifyBus.enabled = true;
  });

  testWidgets('私信：对方今日状态、邀请卡与双击戳一戳', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    var pokeCalls = 0;
    ApiClient.httpClient = MockClient((req) async {
      final p = req.url.path;
      if (p.endsWith('/dm/messages')) {
        return _ok({
          'list': [
            {
              'id': 'm1',
              'senderId': 'u1',
              'content': '今晚有风，适合一起听点什么。',
              'msgType': 'text',
              'created': _now - 120,
              'isRead': 1,
            },
            {
              'id': 'm2',
              'senderId': 'me',
              'content': jsonEncode(_togetherCard()),
              'msgType': 'card',
              'created': _now - 80,
              'isRead': 1,
            },
            _pokeMessage(),
          ],
        });
      }
      if (p.endsWith('/status')) {
        return _ok({
          'visible': true,
          'status': {'mood': '🌿', 'text': '在阳台晒太阳', 'updated': _now},
        });
      }
      if (p.endsWith('/pokes/unread')) return _ok({'list': <Map>[]});
      if (p.endsWith('/dm/read')) return _ok({'read': true});
      if (p.endsWith('/dm/unread')) return _ok({'unread': 0});
      if (p.endsWith('/emojis')) return _ok({'list': <Map>[]});
      if (p.endsWith('/emojis/favs')) return _ok({'list': <Map>[]});
      if (p.contains('/poke/')) {
        pokeCalls++;
        return _ok({
          'poke': {'kind': 'poke'},
        });
      }
      return _ok({});
    });

    await tester.pumpWidget(
      _wrap(const DmChatPage(peerId: 'u1', peerName: '夏梓璇')),
    );
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    await _warmAssets(tester);
    await tester.pump();

    expect(find.textContaining('在阳台晒太阳'), findsOneWidget);
    expect(find.text('一起听邀请'), findsOneWidget);
    expect(find.text('抱了抱你'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await expectLater(
      find.byType(DmChatPage),
      matchesGoldenFile('goldens/social_dm_status_390.png'),
    );

    // 双击头像 → 本地动效立即出现；API 成功后再叠加一次也只会显示同一层。
    await tester.tap(find.byType(AppAvatar).first);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.byType(AppAvatar).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 420));
    await tester.pump(const Duration(milliseconds: 180));
    expect(find.text('戳了戳你'), findsWidgets);
    expect(pokeCalls, 1);
    expect(tester.takeException(), isNull);

    await expectLater(
      find.byType(DmChatPage),
      matchesGoldenFile('goldens/social_dm_poke_390.png'),
    );

    // 全屏动效退场后，刚发出的戳一戳必须已经出现在消息列表里，无需退出重进。
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('你戳了戳 TA'), findsOneWidget);
    await expectLater(
      find.byType(DmChatPage),
      matchesGoldenFile('goldens/social_dm_poke_list_390.png'),
    );

    // 让 flutter_cache_manager 的 10s 清理定时器跑完，避免测试结束时报 pending timer。
    await tester.pump(const Duration(seconds: 12));
  });

  testWidgets('小萤接话：只生成候选，不自动发布', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    var commentPosts = 0;
    var aiCalls = 0;
    final shotKey = GlobalKey();
    ApiClient.httpClient = MockClient((req) async {
      final p = req.url.path;
      if (p.endsWith('/post/p1/comments') && req.method == 'GET') {
        return _ok({
          'list': [
            {
              'id': 'c1',
              'content': '这首歌前奏一响我就投降了。',
              'likeCount': 3,
              'created': _now - 50,
              'author': {'id': 'u2', 'name': '山栀', 'avatar': ''},
            },
          ],
          'total': 1,
          'hasMore': false,
        });
      }
      if (p.endsWith('/post/p1/comments') && req.method == 'POST') {
        commentPosts++;
        return _ok({
          'comment': {'id': 'c2', 'content': '接住了'},
        });
      }
      if (p.endsWith('/post/p1/ai-reply')) {
        aiCalls++;
        return _ok({
          'source': 'local',
          'suggestions': [
            '这段前奏像凌晨两点的风，轻轻一吹就醒了。',
            '我先收藏，等夜里再听一遍。',
            '同意，前奏一响就知道今晚睡不着了。',
          ],
        });
      }
      if (p.endsWith('/emojis/favs')) return _ok({'list': <Map>[]});
      if (p.endsWith('/emojis')) return _ok({'list': <Map>[]});
      return _ok({});
    });

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _theme(),
        home: Scaffold(
          backgroundColor: const Color(AppColors.bg),
          body: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              RepaintBoundary(
                key: shotKey,
                child: SizedBox(
                  height: 200,
                  child: CommentSheet(
                    postId: 'p1',
                    pureInput: true,
                    prompt: '你最近在循环哪首歌？',
                    aiReply: true,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 420));
    await _warmAssets(tester);
    await tester.pump();

    expect(find.text('让小萤接一句'), findsOneWidget);
    await tester.tap(find.text('让小萤接一句'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 320));

    expect(aiCalls, 1);
    expect(commentPosts, 0, reason: '生成候选绝不能自动发评论');
    expect(find.text('AI'), findsOneWidget);
    expect(find.text('已接一句，可编辑后发送'), findsOneWidget);
    expect(find.textContaining('凌晨两点的风'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await expectLater(
      find.byKey(shotKey),
      matchesGoldenFile('goldens/social_xiaoying_reply_390.png'),
    );
  });

  testWidgets('今日状态：主页状态条与编辑弹窗', (tester) async {
    ApiClient.userId = 'u1';
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    var statusPuts = 0;
    final profile = {
      'user': {
        'id': 'u1',
        'name': '夏梓璇',
        'avatar': '',
        'background': '',
        'signature': '把傍晚的风收进歌单，也把没说完的话留给下一次更新。',
        'level': 6,
        'exp': 1200,
        'followers': 1024,
        'followings': 39,
        'following': false,
        'gender': '女',
        'age': 24,
        'city': '苏州',
        'created': _now - 201 * 86400,
        'verified': true,
        'verifiedLabel': '社区认证',
        'title': '夜间听众',
        'adminLevel': 0,
        'frameId': '',
      },
    };
    ApiClient.httpClient = MockClient((req) async {
      final p = req.url.path;
      if (p.endsWith('/user/u1/profile')) return _ok(profile);
      if (p.endsWith('/user/u1/posts')) {
        return _ok({
          'list': [
            {
              'id': 'p1',
              'type': 'text',
              'content': '今天的歌单只有三首，但每一首都适合单曲循环。',
              'likeCount': 32,
              'commentCount': 4,
              'shareCount': 1,
              'created': _now - 7200,
              'author': {'id': 'u1', 'name': '夏梓璇', 'avatar': '', 'level': 6},
            },
          ],
          'page': 1,
          'hasMore': false,
        });
      }
      if (p.endsWith('/user/u1/apps') || p.endsWith('/apps/by-user/u1')) {
        return _ok({'list': <Map>[]});
      }
      if (p.endsWith('/status')) {
        if (req.method == 'PUT') {
          statusPuts++;
          return _ok({
            'status': {'mood': 'leaf', 'text': '在阳台晒太阳', 'updated': _now},
          });
        }
        return _ok({
          'visible': true,
          'status': {'mood': 'leaf', 'text': '在阳台晒太阳', 'updated': _now},
        });
      }
      return _ok({'list': <Map>[]});
    });

    await tester.pumpWidget(_wrap(const UserProfilePage(uid: 'u1')));
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    await _warmAssets(tester);
    await tester.pump();

    expect(find.text('在阳台晒太阳'), findsOneWidget);
    expect(find.text('编辑'), findsOneWidget);
    // 自己的主页不应出现关注/私信自己，改为编辑资料。
    expect(find.text('编辑资料'), findsOneWidget);
    expect(find.text('私信'), findsNothing);
    expect(tester.takeException(), isNull);

    await expectLater(
      find.byType(UserProfilePage),
      matchesGoldenFile('goldens/social_profile_status_390.png'),
    );

    await tester.tap(find.text('编辑'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 420));
    expect(find.text('今日状态'), findsOneWidget);
    expect(find.text('保存状态'), findsOneWidget);
    // 打开面板先看到 8 个形象选择，而不是只剩输入框。
    expect(find.text('元气'), findsOneWidget);
    expect(find.text('好运'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/social_profile_status_edit_390.png'),
    );

    await tester.tap(find.text('保存状态'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 420));
    expect(statusPuts, 1);
    expect(find.text('保存状态'), findsNothing);
    expect(find.text('在阳台晒太阳'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('今日状态：320 窄屏 + 键盘弹起不溢出', (tester) async {
    ApiClient.userId = 'u1';
    tester.view.physicalSize = const Size(320 * 2, 640 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final profile = {
      'user': {
        'id': 'u1',
        'name': '夏梓璇',
        'avatar': '',
        'background': '',
        'signature': '把傍晚的风收进歌单。',
        'level': 6,
        'exp': 1200,
        'followers': 1024,
        'followings': 39,
        'following': false,
        'gender': '女',
        'age': 24,
        'city': '苏州',
        'created': _now - 201 * 86400,
        'verified': true,
        'title': '夜间听众',
        'adminLevel': 0,
        'frameId': '',
      },
    };
    ApiClient.httpClient = MockClient((req) async {
      final p = req.url.path;
      if (p.endsWith('/user/u1/profile')) return _ok(profile);
      if (p.endsWith('/user/u1/posts') ||
          p.endsWith('/user/u1/apps') ||
          p.endsWith('/apps/by-user/u1')) {
        return _ok({'list': <Map>[], 'page': 1, 'hasMore': false});
      }
      if (p.endsWith('/status')) {
        return _ok({
          'visible': true,
          'status': {'mood': 'leaf', 'text': '在阳台晒太阳', 'updated': _now},
        });
      }
      return _ok({'list': <Map>[]});
    });

    await tester.pumpWidget(
      _wrap(const UserProfilePage(uid: 'u1'), width: 320, height: 640),
    );
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    await _warmAssets(tester);
    await tester.pump();

    await tester.tap(find.text('编辑'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 420));
    expect(find.text('今日状态'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 320×640 小屏 + 280 逻辑像素键盘，覆盖真机最紧的可视区。
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 360));
    expect(find.text('保存状态'), findsOneWidget);
    // 键盘弹起后 8 个形象选择仍全部保留，不再被文字输入独占。
    expect(find.text('元气'), findsOneWidget);
    expect(find.text('好运'), findsOneWidget);
    expect(find.text('保存状态').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/social_profile_status_keyboard_320.png'),
    );
  });

  testWidgets('一起听房间：390 与 320 无溢出', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    var nextCalls = 0;
    Map<String, dynamic> room({int index = 0, String title = '夜里两点的歌单'}) => {
      'id': 'r1',
      'kind': 'listen',
      'hostUid': 'me',
      'guestUid': 'u1',
      'host': {'id': 'me', 'name': '我', 'avatar': ''},
      'guest': {'id': 'u1', 'name': '夏梓璇', 'avatar': ''},
      'mediaUrl': '',
      'title': title,
      'cover': '',
      'queue': [
        {
          'url': 'https://example.com/song-1.m4a',
          'title': '夜里两点的歌单',
          'cover': '',
          'mediaId': 's1',
        },
        {
          'url': 'https://example.com/song-2.m4a',
          'title': '下一首',
          'cover': '',
          'mediaId': 's2',
        },
      ],
      'queueIndex': index,
      'positionMs': index == 0 ? 96000 : 0,
      'playing': false,
      'status': 'active',
      'created': _now - 200,
      'updated': _now - 10,
    };
    ApiClient.httpClient = MockClient((req) async {
      if (req.url.path.endsWith('/together/room/r1')) {
        return _ok({'room': room()});
      }
      if (req.url.path.endsWith('/together/room/r1/sync')) {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        if ((body['direction'] ?? '') == 'next') {
          nextCalls++;
          return _ok({'room': room(index: 1, title: '下一首')});
        }
        return _ok({'room': room()});
      }
      if (req.url.path.endsWith('/together/room/r1/reaction')) {
        return _ok({
          'reaction': {'emoji': 'same'},
        });
      }
      if (req.url.path.endsWith('/together/room/r1/leave')) {
        return _ok({'ended': true});
      }
      return _ok({});
    });

    await tester.pumpWidget(_wrap(const TogetherRoomPage(roomId: 'r1')));
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    await _warmAssets(tester);
    await tester.pump();

    expect(find.textContaining('和 夏梓璇 一起听'), findsOneWidget);
    expect(find.text('夜里两点的歌单'), findsOneWidget);
    expect(find.textContaining('1 / 2'), findsWidgets);
    expect(find.text('1:36'), findsOneWidget);
    expect(find.text('同感'), findsOneWidget);
    expect(find.byTooltip('上一首'), findsOneWidget);
    expect(find.byTooltip('下一首'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await expectLater(
      find.byType(TogetherRoomPage),
      matchesGoldenFile('goldens/social_together_room_390.png'),
    );

    await tester.tap(find.text('同感'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 420));
    await tester.pump(const Duration(milliseconds: 160));
    expect(find.byKey(const ValueKey('room_reaction_overlay')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(TogetherRoomPage),
      matchesGoldenFile('goldens/social_together_reaction_390.png'),
    );

    // 等飘反应动画完全退场，320 截图只验证布局，不叠上一帧的贴纸。
    await tester.pump(const Duration(milliseconds: 1200));

    // 房间成员也能切下一首：请求带 direction，本地立即换成服务端返回的队列项。
    await tester.tap(find.byTooltip('下一首'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    expect(nextCalls, 1);
    expect(find.text('下一首'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 320 窄屏重排验证：控件与五枚反应不被裁掉。
    tester.view.physicalSize = const Size(320 * 2, 700 * 2);
    tester.view.devicePixelRatio = 2;
    await tester.pumpWidget(
      _wrap(const TogetherRoomPage(roomId: 'r1'), width: 320, height: 700),
    );
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    await tester.pump();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(TogetherRoomPage),
      matchesGoldenFile('goldens/social_together_room_320.png'),
    );
    // CachedNetworkImage 在空头像 URL 兜底时仍会触发磁盘缓存清理定时器，
    // 截图后推进 12 秒让它自然结束，避免把测试框架的 pending timer 当成失败。
    await tester.pump(const Duration(seconds: 12));
  });

  testWidgets('一起听：受邀人打开邀请自动加入', (tester) async {
    ApiClient.userId = 'u2';
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    var joinCalls = 0;
    Map<String, dynamic> room(String status) => {
      'id': 'r1',
      'kind': 'listen',
      'hostUid': 'u1',
      'guestUid': 'u2',
      'host': {'id': 'u1', 'name': '夏梓璇', 'avatar': ''},
      'guest': {'id': 'u2', 'name': '我', 'avatar': ''},
      'mediaUrl': '',
      'title': '夜里两点的歌单',
      'cover': '',
      'positionMs': 0,
      'playing': false,
      'status': status,
      'created': _now - 200,
      'updated': _now - 10,
    };
    ApiClient.httpClient = MockClient((req) async {
      if (req.url.path.endsWith('/together/room/r1/join')) {
        joinCalls++;
        return _ok({'room': room('active')});
      }
      if (req.url.path.endsWith('/together/room/r1')) {
        return _ok({'room': room('waiting')});
      }
      if (req.url.path.endsWith('/together/room/r1/leave')) {
        return _ok({'ended': true});
      }
      return _ok({});
    });

    await tester.pumpWidget(_wrap(const TogetherRoomPage(roomId: 'r1')));
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    expect(joinCalls, 1);
    expect(find.textContaining('和 夏梓璇 一起听'), findsOneWidget);
    expect(find.textContaining('选一个内容'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('一起看：视频房间标题与等待态', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    ApiClient.httpClient = MockClient((req) async {
      if (req.url.path.endsWith('/together/room/r1')) {
        return _ok({
          'room': {
            'id': 'r1',
            'kind': 'watch',
            'hostUid': 'me',
            'guestUid': 'u1',
            'host': {'id': 'me', 'name': '我', 'avatar': ''},
            'guest': {'id': 'u1', 'name': '夏梓璇', 'avatar': ''},
            'mediaUrl': '',
            'title': '湖边的日落 4K',
            'cover': '',
            'positionMs': 0,
            'playing': false,
            'status': 'active',
            'created': _now - 120,
            'updated': _now - 8,
          },
        });
      }
      if (req.url.path.endsWith('/together/room/r1/leave')) {
        return _ok({'ended': true});
      }
      return _ok({});
    });

    await tester.pumpWidget(_wrap(const TogetherRoomPage(roomId: 'r1')));
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    await _warmAssets(tester);
    await tester.pump();
    expect(find.textContaining('和 夏梓璇 一起看'), findsOneWidget);
    expect(find.text('湖边的日落 4K'), findsOneWidget);
    expect(find.text('这条视频还没有准备好'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(TogetherRoomPage),
      matchesGoldenFile('goldens/social_together_video_390.png'),
    );
    await tester.pump(const Duration(seconds: 12));
  });
}
