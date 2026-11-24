// 我的页：头像必须能进入自己的公开主页。
// 这个测试只验证入口与路由，不做像素比对。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:community_app/api/client.dart';
import 'package:community_app/design/components.dart';
import 'package:community_app/pages/mine/mine_page.dart';
import 'package:community_app/pages/user/user_profile.dart';
import 'package:community_app/services/notify_bus.dart';

http.Response _ok(Map<String, dynamic> body) => http.Response(
  jsonEncode({'ok': true, ...body}),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  testWidgets('点头像进入自己的公开主页', (tester) async {
    SharedPreferences.setMockInitialValues({'community_token': 'demo'});
    ApiClient.token = 'demo';
    ApiClient.userId = 'u_demo';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'read' ? 'demo' : null,
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            null,
          ),
    );
    NotifyBus.enabled = false;
    addTearDown(() => NotifyBus.enabled = true);

    final user = {
      'id': 'u_demo',
      'name': '林晚萤',
      'avatar': '',
      'verified': true,
      'verifiedLabel': '创作者',
      'adminLevel': 0,
      'followers': 1200,
      'followings': 128,
      'likes': 8600,
      'favCount': 36,
      'city': '苏州',
      'signature': '把每一晚的灵感，做成会发光的东西。',
      'background': '',
      'level': 6,
    };
    ApiClient.httpClient = MockClient((req) async {
      final p = req.url.path;
      if (p.endsWith('/user/me')) {
        return _ok({'user': user});
      }
      if (p.endsWith('/user/u_demo/profile')) {
        return _ok({'user': user});
      }
      if (p.endsWith('/user/u_demo/posts') ||
          p.endsWith('/user/u_demo/apps') ||
          p.endsWith('/apps/by-user/u_demo')) {
        return _ok({'list': <Map>[], 'page': 1, 'hasMore': false});
      }
      if (p.endsWith('/status')) {
        return _ok({'visible': true, 'status': null});
      }
      if (p.endsWith('/level/me')) {
        return _ok({'level': 6, 'exp': 240, 'nextThreshold': 300});
      }
      if (p.endsWith('/signins')) return _ok({'list': <String>[]});
      if (p.endsWith('/frame/mine')) return _ok({'frameId': ''});
      if (p.endsWith('/member/status')) return _ok({'level': 'free'});
      if (p.endsWith('/apps/mine')) return _ok({'list': <Map>[]});
      if (p.endsWith('/posts') || p.endsWith('/favorites')) {
        return _ok({'list': <Map>[], 'hasMore': false});
      }
      return _ok({});
    });

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true),
        home: const Scaffold(body: MinePage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 700));

    expect(find.byType(MinePage), findsOneWidget);
    expect(find.byType(AppAvatar), findsWidgets);
    // 头像不再需要额外箭头角标，点击头像的入口仍然保留。
    expect(find.byIcon(Icons.arrow_outward_rounded), findsNothing);
    await tester.tap(find.byType(AppAvatar).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    expect(find.byType(UserProfilePage), findsOneWidget);
    expect(find.text('林晚萤'), findsWidgets);

    ApiClient.httpClient = http.Client();
  });
}
