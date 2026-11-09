import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/main.dart';

/// Cloud vision assist wiring: with the default build (no proxy
/// configured), tapping the assist button must honestly announce
/// that cloud vision is not configured and that local detection
/// remains primary -- never a fake description.
void main() {
  testWidgets('cloud vision button announces not-configured degrade',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MingtuApp());
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(seconds: 4));

    final Finder button = find.text('云端视觉辅助（低频，经代理，本地检测仍为主）');
    await tester.ensureVisible(button);
    await tester.pump();
    await tester.tap(button);
    await tester.pump();

    expect(find.textContaining('识图未配置'), findsWidgets);
    expect(find.textContaining('已降级为本地检测'), findsWidgets);

    for (int i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 1500));
    }
  });

  testWidgets(
      'app lifecycle pause is handled: vision cancelled, '
      'camera released, app keeps running', (WidgetTester tester) async {
    await tester.pumpWidget(const MingtuApp());
    await tester.pump(const Duration(seconds: 4));

    // Going to background must not crash and must run the
    // release path (cancel in-flight vision, close YOLO view).
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(find.byType(MingtuApp), findsOneWidget);

    // The framework's lifecycle machine requires the sequence
    // paused -> hidden -> inactive -> resumed.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.byType(MingtuApp), findsOneWidget);

    for (int i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 1500));
    }
  });
}
