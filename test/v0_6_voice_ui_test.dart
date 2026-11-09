import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/main.dart';

/// Widget test for v0.6 real-integration wiring, in an environment
/// with NO phone engine (flutter_test): the app must report the
/// voice engines as unavailable instead of crashing, and the Amap
/// button must honestly report why real navigation cannot start
/// instead of inventing a route. Navigation P0 update: there is no
/// in-app key any more (the key lives in the server proxy) and the
/// destination registry is empty, so the expected report is now
/// "目的地未配置" -- the first check in the starter's order.
void main() {
  testWidgets('no phone engine: voice reports unavailable, real nav needs a verified destination',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MingtuApp());
    // Let _initRealIntegrations run: its platform calls fail in the
    // test harness and are caught by the adapters (each engine gets
    // a 3 s startup timeout, so pump past it).
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(seconds: 4));

    expect(find.textContaining('系统语音合成不可用'), findsOneWidget);
    expect(find.textContaining('系统语音识别不可用'), findsOneWidget);

    // The real-ASR button is disabled without an engine; the demo
    // text input still works as the fallback.
    expect(find.text('开始语音识别（真机，单次最长 10 秒）'), findsOneWidget);

    final Finder amapButton = find.text('高德真实路线（真实导航：需已核验目的地与路线代理）');
    await tester.ensureVisible(amapButton);
    await tester.pump();
    await tester.tap(amapButton);
    await tester.pump();
    expect(find.textContaining('真实导航未启动'), findsWidgets);
    expect(find.textContaining('目的地未配置'), findsWidgets);

    // Drain the simulated speech-completion timer started by the
    // spoken failure announcement before teardown.
    for (int i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 1500));
    }
  });
}
