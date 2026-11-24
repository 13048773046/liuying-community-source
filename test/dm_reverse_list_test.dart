/// 私信 reverse 列表回归：进入贴底、上滑自动续载更早消息、
/// 上翻期间来新消息只出胶囊、发送失败保留气泡可重发。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:community_app/api/client.dart';
import 'package:community_app/pages/message/dm_chat_page.dart';
import 'package:community_app/services/notify_bus.dart';

http.Response _ok(Map<String, dynamic> body) => http.Response(
  jsonEncode({'ok': true, ...body}),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

final _now = DateTime.now().millisecondsSinceEpoch / 1000;

void _size(WidgetTester t) {
  t.view.physicalSize = const Size(1170, 2532);
  t.view.devicePixelRatio = 3.0;
  addTearDown(t.view.reset);
}

Widget _app() => const MaterialApp(
  debugShowCheckedModeBanner: false,
  home: DmChatPage(peerId: 'u1', peerName: '夏梓璇'),
);

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 80));
  }
}

List<Map<String, dynamic>> _page({required int from, required int count}) {
  return List.generate(count, (i) {
    final n = from + i;
    return {
      'id': 'm$n',
      'senderId': n.isEven ? 'u1' : 'me',
      'content': '第 $n 条消息，内容足够长以撑开列表高度。',
      'msgType': 'text',
      'created': _now - 300 + n,
      'isRead': 1,
    };
  });
}

void _baseApi() {
  ApiClient.token = 'reverse-token';
  ApiClient.userId = 'me';
}

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => '/tmp',
        );
  });

  tearDown(() {
    ApiClient.httpClient = http.Client();
    ApiClient.token = null;
    ApiClient.userId = null;
  });

  testWidgets('进入即停在最新，不再出现「加载更多」按钮', (t) async {
    _size(t);
    _baseApi();
    var calls = 0;
    ApiClient.httpClient = MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith('/dm/messages')) {
        calls++;
        return _ok({'list': _page(from: 0, count: 30), 'peer': 'u1'});
      }
      if (path.endsWith('/dm/read')) return _ok({'read': true});
      if (path.endsWith('/dm/unread')) return _ok({'unread': 0});
      return _ok({});
    });

    await t.pumpWidget(_app());
    await _settle(t);

    final scrollable = t.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey('dm_message_area')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(scrollable.position.pixels, closeTo(0, 1.5));
    expect(find.byKey(const ValueKey('dm_bubble_m29_out')), findsOneWidget);
    expect(find.text('加载更多'), findsNothing);
    expect(calls, 1, reason: '首屏只加载最新一页，不应自动连翻');
  });

  testWidgets('滑到历史顶部自动续载更早消息', (t) async {
    _size(t);
    _baseApi();
    var olderCalls = 0;
    ApiClient.httpClient = MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith('/dm/messages')) {
        final before =
            double.tryParse(request.url.queryParameters['before'] ?? '') ?? 0;
        if (before == 0) {
          return _ok({'list': _page(from: 0, count: 30), 'peer': 'u1'});
        }
        olderCalls++;
        return _ok({
          'list': [
            {
              'id': 'older1',
              'senderId': 'u1',
              'content': '更早的一条消息',
              'msgType': 'text',
              'created': _now - 999,
              'isRead': 1,
            },
          ],
          'peer': 'u1',
        });
      }
      if (path.endsWith('/dm/read')) return _ok({'read': true});
      if (path.endsWith('/dm/unread')) return _ok({'unread': 0});
      return _ok({});
    });

    await t.pumpWidget(_app());
    await _settle(t);

    // reverse 列表里“往上翻历史”= 手指向下拖。连续拖动直到接近列表另一端。
    for (var i = 0; i < 10; i++) {
      await t.drag(find.byType(ListView), const Offset(0, 500));
      await t.pump(const Duration(milliseconds: 60));
    }
    await _settle(t);

    expect(olderCalls, greaterThan(0), reason: '滑到顶应自动请求更早一页');
    expect(find.text('加载更多'), findsNothing);
  });

  testWidgets('上翻期间来新消息只出胶囊，点击回底', (t) async {
    _size(t);
    _baseApi();
    ApiClient.httpClient = MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith('/dm/messages')) {
        return _ok({'list': _page(from: 0, count: 30), 'peer': 'u1'});
      }
      if (path.endsWith('/dm/read')) return _ok({'read': true});
      if (path.endsWith('/dm/unread')) return _ok({'unread': 0});
      return _ok({});
    });

    await t.pumpWidget(_app());
    await _settle(t);

    await t.drag(find.byType(ListView), const Offset(0, 320));
    await t.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('dm_new_msg_pill')), findsNothing);

    NotifyBus.shared.onDm.add({
      'id': 'new1',
      'from': {'id': 'u1'},
      'content': '新到的消息',
      'msgType': 'text',
      'created': _now,
    });
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));

    expect(find.byKey(const ValueKey('dm_new_msg_pill')), findsOneWidget);
    expect(find.text('1 条新消息'), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('dm_new_msg_pill')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 260));
    expect(find.byKey(const ValueKey('dm_new_msg_pill')), findsNothing);
    expect(find.text('新到的消息'), findsOneWidget);
  });

  testWidgets('发送失败保留气泡，点按可重发', (t) async {
    _size(t);
    _baseApi();
    var fail = true;
    ApiClient.httpClient = MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith('/dm/messages')) {
        return _ok({'list': <dynamic>[], 'peer': 'u1'});
      }
      if (path.endsWith('/dm/send')) {
        if (fail) {
          return http.Response('send failed', 500);
        }
        return _ok({'id': 'sent-r', 'created': _now});
      }
      if (path.endsWith('/dm/read')) return _ok({'read': true});
      if (path.endsWith('/dm/unread')) return _ok({'unread': 0});
      return _ok({});
    });

    await t.pumpWidget(_app());
    await _settle(t);

    await t.enterText(find.byType(TextField), '重试的消息');
    await t.pump();
    await t.tap(find.byIcon(Icons.send_rounded));
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));

    expect(find.text('发送失败，点此重发'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('dm_bubble__out')),
      findsOneWidget,
      reason: '失败气泡不能消失',
    );

    fail = false;
    await t.tap(find.text('发送失败，点此重发'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));

    expect(
      find.byKey(const ValueKey('dm_bubble_sent-r_out')),
      findsOneWidget,
      reason: '重发成功后同一气泡应换成服务端 id',
    );
    expect(find.text('发送失败，点此重发'), findsNothing);
  });
}
