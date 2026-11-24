/// 自己的公开主页动作区：不出现关注/私信自己，改为编辑资料；
/// 他人主页仍保留关注/私信。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:community_app/api/client.dart';
import 'package:community_app/pages/mine/edit_profile_page.dart';
import 'package:community_app/pages/user/user_profile.dart';

Map<String, dynamic> _ok(Map<String, dynamic> data) => <String, dynamic>{
  'ok': true,
  ...data,
};

http.Response _resp(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Map<String, dynamic> _profile(String id) => {
  'id': id,
  'name': '林晚萤',
  'avatar': '',
  'background': '',
  'signature': '把每一晚的灵感，做成会发光的东西。',
  'level': 6,
  'exp': 1200,
  'followers': 1024,
  'followings': 39,
  'following': false,
  'gender': '女',
  'age': 24,
  'city': '苏州',
  'created': DateTime.now().millisecondsSinceEpoch ~/ 1000 - 201 * 86400,
  'verified': true,
  'title': '夜间听众',
  'adminLevel': 0,
  'frameId': '',
};

void _mockApi({required String viewer}) {
  ApiClient.userId = viewer;
  ApiClient.httpClient = MockClient((req) async {
    final p = req.url.path;
    if (p.endsWith('/user/u1/profile'))
      return _resp(_ok({'user': _profile('u1')}));
    if (p.endsWith('/user/me')) {
      return _resp(
        _ok({
          'user': {
            ..._profile(viewer),
            'email': 'test@example.com',
            'phoneMask': '138****0000',
            'phoneVerified': true,
          },
        }),
      );
    }
    if (p.endsWith('/status')) {
      return _resp(
        _ok({
          'visible': true,
          'status': {'mood': 'leaf', 'text': '在阳台晒太阳', 'updated': 0},
        }),
      );
    }
    if (p.endsWith('/posts') ||
        p.endsWith('/apps') ||
        p.endsWith('/favorites') ||
        p.endsWith('/frame/mine') ||
        p.endsWith('/member/status')) {
      return _resp(_ok({'list': <Map>[], 'hasMore': false}));
    }
    return _resp(_ok({'list': <Map>[], 'hasMore': false}));
  });
}

Future<void> _pumpProfile(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const UserProfilePage(uid: 'u1'),
    ),
  );
  await tester.pump();
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
  await tester.pump();
}

void main() {
  testWidgets('自己的主页：无关注/私信，点编辑资料进入编辑页', (tester) async {
    _mockApi(viewer: 'u1');
    await _pumpProfile(tester);

    expect(find.text('编辑资料'), findsOneWidget);
    expect(find.text('私信'), findsNothing);

    await tester.tap(find.text('编辑资料'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(EditProfilePage), findsOneWidget);
    expect(tester.takeException(), isNull);

    ApiClient.httpClient = http.Client();
  });

  testWidgets('他人主页：保留关注与私信', (tester) async {
    _mockApi(viewer: 'viewer');
    await _pumpProfile(tester);

    expect(find.text('编辑资料'), findsNothing);
    expect(find.text('私信'), findsOneWidget);
    expect(find.text('关注'), findsWidgets);
    expect(tester.takeException(), isNull);

    ApiClient.httpClient = http.Client();
  });
}
