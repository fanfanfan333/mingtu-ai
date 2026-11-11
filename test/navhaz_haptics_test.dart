/// NAVHAZ M1 fix round, item C: the native vibratePattern
/// contract. MainActivity now answers a Boolean -- false
/// when the pattern was NOT executed (invalid arguments,
/// missing VIBRATE permission, platform exception). The
/// Dart side must not swallow that false: DeviceHaptics
/// records it in HapticsFailureLog (count + listener),
/// which the app wires to its log. These tests drive the
/// real DeviceHaptics against a mock `mingtu/device`
/// channel.
library;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/adapters/haptics_mobile.dart';
import 'package:mingtu_ai/core/haptics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void mockChannel(Object? Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(
        const MethodChannel('mingtu/device'), (MethodCall call) async {
      return handler(call);
    });
    // HapticFeedback's fallback path lands on the platform
    // channel; answer it quietly.
    messenger.setMockMethodCallHandler(
        SystemChannels.platform, (MethodCall call) async => null);
  }

  tearDown(() {
    messenger.setMockMethodCallHandler(
        const MethodChannel('mingtu/device'), null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    HapticsFailureLog.reset();
  });

  test('native false is recorded and observable, never swallowed', () async {
    mockChannel((MethodCall call) => false);
    int heard = 0;
    HapticsFailureLog.listener = () => heard++;
    final DeviceHaptics haptics = DeviceHaptics();
    await haptics.vibrateUrgent();
    expect(HapticsFailureLog.count, 1,
        reason: 'the false from the channel is on record');
    expect(heard, 1, reason: 'the listener (the app log) fired');
  });

  test('native true records nothing', () async {
    mockChannel((MethodCall call) => true);
    final DeviceHaptics haptics = DeviceHaptics();
    await haptics.vibrateWarning();
    expect(HapticsFailureLog.count, 0);
  });

  test('a missing channel degrades silently (no false recorded)', () async {
    mockChannel((MethodCall call) => throw MissingPluginException());
    final DeviceHaptics haptics = DeviceHaptics();
    await haptics.vibratePattern(
        const <int>[0, 50], const <int>[0, 200]);
    // Degradation to the framework buzz is the pre-existing
    // contract for "no such channel"; only an explicit
    // native false counts as a reported failure.
    expect(HapticsFailureLog.count, 0);
  });
}
