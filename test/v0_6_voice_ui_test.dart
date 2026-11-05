import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/main.dart';

/// Widget test for v0.6 real-integration wiring, in an environment
/// with NO phone engine (flutter_test): the app must report the
/// voice engines as unavailable instead of crashing, and the Amap
/// button must report NOT_CONFIGURED (no key in this run) instead of
/// inventing a route.
void main() {
  testWidgets('no phone engine: voice reports unavailable, amap needs a key',
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

    final Finder amapButton = find.text('高德真实路线（需 Key 与现场坐标）');
    await tester.ensureVisible(amapButton);
    await tester.pump();
    await tester.tap(amapButton);
    await tester.pump();
    expect(find.textContaining('高德真实路线：NOT_CONFIGURED'), findsOneWidget);
    expect(find.textContaining('未提供高德 Web 服务 Key'), findsOneWidget);
  });
}
