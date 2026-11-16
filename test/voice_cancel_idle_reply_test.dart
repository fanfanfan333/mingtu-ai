/// D5（盲人可用性）：idle 态撤回意图的播报必须可执行。
///
/// 「我不去图书馆了」现在被判成 VoiceCommand.cancel（D4），而 idle 的
/// 合法出边只有 listening / emergency，`canTransitionTo(cancelled)` 为
/// false，于是用户随口反悔会听到「当前状态不能取消，请先重置演示」——
/// 真实盲人手里没有"演示"可重置，这句话无法执行。
///
/// 这里用录制型 fake TTS 抓真实播报时间线：既断言新的可执行文案出现，
/// 也断言「重置演示」不再出现（后者才是防复发的锚点）。
library;
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/main.dart';

void main() {
  final List<String> timeline = <String>[];
  final List<Completer<dynamic>> pendingSpeaks = <Completer<dynamic>>[];

  void installMocks() {
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter_tts'),
      (MethodCall call) async {
        switch (call.method) {
          case 'getLanguages':
            return <String>['zh-CN', 'en-US'];
          case 'setLanguage':
            return 1;
          case 'speak':
            timeline.add('speak:${call.arguments}');
            final Completer<dynamic> c = Completer<dynamic>();
            pendingSpeaks.add(c);
            return c.future;
          case 'stop':
            timeline.add('stop');
            return 1;
          default:
            return 1;
        }
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugin.csdcorp.com/speech_to_text'),
      (MethodCall call) async {
        if (call.method == 'initialize') return false;
        return null;
      },
    );
    messenger.setMockMethodCallHandler(SystemChannels.platform,
        (MethodCall call) async {
      return null;
    });
  }

  void clearMocks() {
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('flutter_tts'), null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('plugin.csdcorp.com/speech_to_text'), null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  }

  Future<void> pumpFrames(WidgetTester tester, [int n = 3]) async {
    for (int i = 0; i < n; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// 完成所有在途播报，直到 App 安静下来（每次完成都可能提起下一条）。
  Future<void> drainSpeaks(WidgetTester tester) async {
    for (int i = 0; i < 40; i++) {
      final List<Completer<dynamic>> pending =
          pendingSpeaks.where((Completer<dynamic> c) => !c.isCompleted).toList();
      if (pending.isEmpty) {
        await pumpFrames(tester, 2);
        if (pendingSpeaks.every((Completer<dynamic> c) => c.isCompleted)) {
          return;
        }
        continue;
      }
      for (final Completer<dynamic> c in pending) {
        c.complete(1);
      }
      await pumpFrames(tester, 2);
    }
    fail('speaks did not drain');
  }

  setUp(() {
    timeline.clear();
    pendingSpeaks.clear();
    installMocks();
  });
  tearDown(clearMocks);

  testWidgets('idle 态说「我不去图书馆了」听到可执行的撤回确认，而不是「重置演示」',
      (tester) async {
    await tester.pumpWidget(const MingtuApp());
    await pumpFrames(tester);
    final MingtuHomeDebugHandle h = mingtuHomeDebugHandle!;
    // 启动问候等开场播报全部排空，保证后面抓到的是这一次撤回的回复。
    await drainSpeaks(tester);
    expect(timeline, isNotEmpty,
        reason: '启动播报应当已经在时间线上，否则这个用例没有观察窗口');
    final int before = timeline.length;

    h.voiceCommand('我不去图书馆了');
    await pumpFrames(tester, 5);
    await drainSpeaks(tester);

    final List<String> after = timeline.sublist(before);
    final String joined = after.join('\n');
    expect(joined, contains('好的，不去了'),
        reason: 'idle 态撤回意图必须回一句可执行的确认，实际时间线：$after');
    expect(joined, isNot(contains('重置演示')),
        reason: '真实盲人手里没有“演示”可重置，这句提示无法执行，实际时间线：$after');
    expect(joined, isNot(contains('当前状态不能取消')),
        reason: 'idle 太常见了，不能回一句"不能取消"的糊弄话，实际时间线：$after');
  });
}
