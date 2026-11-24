import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:community_app/api/client.dart';
import 'package:community_app/models/feed_item.dart';
import 'package:community_app/widgets/post_reactions_bar.dart';

http.Response _json(Map<String, dynamic> body, [int status = 200]) =>
    http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

List<Map<String, dynamic>> _five({String? mine, String? type}) => [
  for (final t in ['same', 'laugh', 'hug', 'learned', 'waiting'])
    {'type': t, 'count': t == type ? 1 : 0, 'mine': t == mine},
];

Widget _host(PostReactionsBar bar) => MaterialApp(
  home: Scaffold(
    backgroundColor: Colors.black,
    body: Center(
      child: SizedBox(width: 360, child: bar),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    ApiClient.token = 'test-token';
  });

  tearDown(() {
    ApiClient.token = null;
    ApiClient.httpClient = http.Client();
  });

  testWidgets('点同感后计数 +1，再点一次取消', (tester) async {
    var calls = 0;
    ApiClient.httpClient = MockClient((req) async {
      calls++;
      expect(req.url.path, contains('/post/p1/reaction'));
      if (req.method == 'PUT') {
        expect(jsonDecode(req.body), {'type': 'same'});
        return _json({
          'ok': true,
          'reactions': _five(mine: 'same', type: 'same'),
          'myReaction': 'same',
        });
      }
      expect(req.method, 'DELETE');
      return _json({
        'ok': true,
        'reactions': _five(),
        'myReaction': '',
      });
    });

    await tester.pumpWidget(
      _host(
        PostReactionsBar(
          postId: 'p1',
          initial: const [],
          initialMine: '',
        ),
      ),
    );
    await tester.pump();

    final same = find.byKey(const ValueKey('post-reaction-p1-same'));
    await tester.tap(same);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.descendant(of: same, matching: find.text('1')),
      findsOneWidget,
    );

    await tester.tap(same);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.descendant(of: same, matching: find.text('1')),
      findsNothing,
    );
    expect(calls, 2);
  });

  testWidgets('切换到笑死时同感归零，只保留一个反应', (tester) async {
    ApiClient.httpClient = MockClient((req) async {
      final type = (jsonDecode(req.body) as Map)['type'];
      expect(req.method, 'PUT');
      expect(type, 'laugh');
      return _json({
        'ok': true,
        'reactions': _five(mine: 'laugh', type: 'laugh'),
        'myReaction': 'laugh',
      });
    });

    await tester.pumpWidget(
      _host(
        PostReactionsBar(
          postId: 'p1',
          initial: const [
            PostReaction(type: 'same', count: 2, mine: true),
          ],
          initialMine: 'same',
        ),
      ),
    );
    await tester.pump();

    final same = find.byKey(const ValueKey('post-reaction-p1-same'));
    final laugh = find.byKey(const ValueKey('post-reaction-p1-laugh'));
    await tester.tap(laugh);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.descendant(of: same, matching: find.text('2')),
      findsNothing,
    );
    expect(
      find.descendant(of: laugh, matching: find.text('1')),
      findsOneWidget,
    );
  });

  testWidgets('请求失败时回滚，并提示稍后再试', (tester) async {
    ApiClient.httpClient = MockClient((req) async {
      return _json({'ok': false, 'error': 'boom'}, 500);
    });

    await tester.pumpWidget(
      _host(
        PostReactionsBar(
          postId: 'p1',
          initial: const [],
          initialMine: '',
        ),
      ),
    );
    await tester.pump();

    final same = find.byKey(const ValueKey('post-reaction-p1-same'));
    await tester.tap(same);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.descendant(of: same, matching: find.text('1')),
      findsNothing,
    );
    expect(find.text('反应没送达，稍后再试'), findsOneWidget);
  });


  testWidgets('快速连点 5 次以最后一次意图为准', (tester) async {
    final gates = <Completer<void>>[];
    var call = 0;
    ApiClient.httpClient = MockClient((req) async {
      final index = call++;
      final gate = Completer<void>();
      gates.add(gate);
      await gate.future;
      return _json({
        'ok': true,
        'reactions': [
          for (final t in ['same', 'laugh', 'hug', 'learned', 'waiting'])
            {'type': t, 'count': t == 'same' ? index + 1 : 0, 'mine': t == 'same'},
        ],
        'myReaction': 'same',
      });
    });

    await tester.pumpWidget(
      _host(
        PostReactionsBar(
          postId: 'p1',
          initial: const [],
          initialMine: '',
        ),
      ),
    );
    await tester.pump();
    final same = find.byKey(const ValueKey('post-reaction-p1-same'));
    for (var i = 0; i < 5; i++) {
      await tester.tap(same);
      await tester.pump();
    }
    expect(call, 5);
    // 让最后一次响应先回，旧响应后回；旧响应不得覆盖新状态。
    for (var i = gates.length - 1; i >= 0; i--) {
      gates[i].complete();
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.descendant(of: same, matching: find.text('5')), findsOneWidget);
    expect(find.descendant(of: same, matching: find.text('1')), findsNothing);
  });

  testWidgets('未登录时不发请求，交给登录回调', (tester) async {
    ApiClient.token = null;
    var loginAsked = false;
    var calls = 0;
    ApiClient.httpClient = MockClient((req) async {
      calls++;
      return _json({'ok': true});
    });

    await tester.pumpWidget(
      _host(
        PostReactionsBar(
          postId: 'p1',
          initial: const [],
          initialMine: '',
          ensureLogin: () {
            loginAsked = true;
            return false;
          },
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('post-reaction-p1-same')));
    await tester.pump();
    expect(loginAsked, isTrue);
    expect(calls, 0);
  });
}
