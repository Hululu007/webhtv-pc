import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';

void main() {
  testWidgets('点击分享资源先展示分集，保留作品信息，不自动播放', (tester) async {
    final temp = Directory.systemTemp.createTempSync('webhtv-folder-episodes');
    final calls = <Uri>[];
    var emptyDetail = false;
    Completer<http.Response>? delayedDetail;
    final client = MockClient((request) async {
      calls.add(request.url);
      final query = request.url.queryParameters;
      final Object body;
      if (query.containsKey('play')) {
        body = {'code': -1, 'msg': '选集之前不应调用播放'};
      } else if (query.containsKey('ids')) {
        if (query['ids'] == 'https://115.com/s/slow') {
          return delayedDetail!.future;
        }
        if (emptyDetail) {
          return http.Response(
            '{"list":[]}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        body = {
          'list': [
            {
              'vod_id': 'atvp_resume:opaque-handle',
              'vod_name': '分享资源标题',
              'vod_tag': 'file',
              'vod_play_from': '丫仙女',
              'vod_play_url':
                  r'S01E01(5.89 GB)$1@7864@0@0#S01E02(5.6 GB)$1@7865@0@1',
            },
          ],
        };
      } else if (query.containsKey('t')) {
        body = {
          'list': [
            {
              'vod_id': 'https://115.com/s/example',
              'vod_name': '115分享资源',
              'vod_tag': 'file',
            },
            {
              'vod_id': 'https://115.com/s/slow',
              'vod_name': '较慢的资源',
              'vod_tag': 'file',
            },
          ],
        };
      } else {
        body = {'list': []};
      }
      return http.Response(
        jsonEncode(body),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    final state = AppState(
      paths: AppPaths.resolve(
        overrides: {'roaming': temp.path, 'local': temp.path},
      ),
      log: LogService(),
      httpClient: client,
    );
    addTearDown(() async {
      state.dispose();
      await temp.delete(recursive: true);
    });
    await tester.runAsync(() async {
      await state.bootstrap();
      await state.importConfig(
        jsonEncode({
          'sites': [
            {
              'key': 'bridge',
              'name': '桥接站点',
              'type': 4,
              'api': 'http://127.0.0.1:19978/vod/api?key=bridge',
            },
          ],
        }),
      );
    });
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: DetailPage(
          state: state,
          vod: Vod(
            vodId: 'atvp_detail:series',
            vodName: '原始作品名',
            vodTag: 'folder',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -2500));
    await tester.pumpAndSettle();
    await tester.tap(find.text('115分享资源'));
    await tester.pumpAndSettle();

    expect(
      calls.where((uri) => uri.queryParameters.containsKey('play')),
      isEmpty,
    );
    expect(
      calls.any(
        (uri) => uri.queryParameters['ids'] == 'https://115.com/s/example',
      ),
      isTrue,
    );
    expect(find.textContaining('S01E01'), findsWidgets);
    expect(find.textContaining('S01E02'), findsWidgets);
    expect(find.textContaining('丫仙女'), findsWidgets);
    expect(state.selectedVod?.vodName, '原始作品名');
    expect(state.selectedVod?.vodId, 'atvp_detail:series');
    expect(
      state.playLinesOf(state.selectedVod!).single.episodes[1].url,
      '1@7865@0@1',
    );

    // 点第二集才进入播放请求，传原始分集目标与网关给的线路名。
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -1000));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.textContaining('S01E02').first);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('S01E02').first);
    await tester.pumpAndSettle();
    final play = calls.singleWhere(
      (uri) => uri.queryParameters.containsKey('play'),
    );
    expect(play.queryParameters['play'], '1@7865@0@1');
    expect(play.queryParameters['flag'], '丫仙女');

    // 空分集不能悄悄回退为分享链直播放；重新点击可重试。
    emptyDetail = true;
    await tester.ensureVisible(find.text('115分享资源'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('115分享资源'));
    await tester.pumpAndSettle();
    expect(find.textContaining('没有返回可播放的分集'), findsWidgets);
    expect(find.textContaining('S01E02'), findsNothing);
    emptyDetail = false;
    await tester.tap(find.text('115分享资源'));
    await tester.pumpAndSettle();
    expect(find.textContaining('S01E02'), findsWidgets);

    // 快速换资源：晚到的旧响应不得替换已经展示的新分集。
    delayedDetail = Completer<http.Response>();
    await tester.tap(find.text('较慢的资源'));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.tap(find.text('115分享资源'));
    await tester.pumpAndSettle();
    delayedDetail.complete(
      http.Response(
        jsonEncode({
          'list': [
            {
              'vod_id': 'atvp_resume:slow',
              'vod_name': '旧响应',
              'vod_play_from': '旧线路',
              'vod_play_url': r'旧分集$old-target',
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('S01E02'), findsWidgets);
    expect(find.textContaining('旧分集'), findsNothing);
    expect(state.playLinesOf(state.selectedVod!).single.flag, '丫仙女');
  });
}
